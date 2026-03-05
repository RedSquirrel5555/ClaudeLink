// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMailbox} from "@hyperlane/interfaces/IMailbox.sol";
import {IMessageRecipient} from "@hyperlane/interfaces/IMessageRecipient.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

/**
 * @title OwnBridge
 * @notice Bidirectional bridge for OWN Protocol. Deployed on Base (USDC) and PulseChain (eUSDC).
 *         Lock tokens on source chain, Hyperlane message triggers release from LP pool on dest chain.
 *
 * @dev Architecture:
 *      - LPs deposit tokens into the pool. Pool fills all bridges — no LP selection needed.
 *      - LP earnings are pro-rata via share accounting (ERC-4626 style).
 *      - bridge() locks tokens on source, dispatches Hyperlane message.
 *      - handle() on dest releases tokens from pool.
 *      - markSettled() on source pays LP pool (increases share price) + protocol fee.
 *      - Users can always self-refund after REFUND_DELAY if settlement fails.
 *
 * LP Pool (share-based accounting):
 *      - LPs deposit tokens, receive shares proportional to pool value.
 *      - Settlements increase pool assets without minting shares → share price rises.
 *      - LP withdraws shares at current price → principal + accumulated fees.
 *      - Perfectly proportional. No selection algorithm. No race conditions.
 *
 * Fee structure:
 *      - 0.3% total deducted from bridge amount on source chain
 *      - 0.2% -> protocol fee address (external)
 *      - 0.1% -> LP pool (increases share price for all depositors)
 *
 * Accounting note:
 *      The contract holds two types of funds that must be tracked separately:
 *      1. User deposits (pending settlement/refund) — tracked by deposit records
 *      2. LP pool (available for fills) — tracked by poolAssets
 *      token.balanceOf(this) = pending user deposits + poolAssets
 */
contract OwnBridge is IMessageRecipient {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Total fee in basis points (0.3%)
    uint256 public constant TOTAL_FEE_BPS = 30;

    /// @notice Protocol fee in basis points (0.2%)
    uint256 public constant PROTOCOL_FEE_BPS = 20;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Time after which user can self-refund an unsettled deposit
    uint256 public constant REFUND_DELAY = 2 hours;

    /// @notice Minimum initial deposit to prevent share inflation attacks
    uint256 public constant MIN_INITIAL_DEPOSIT = 1e6; // 1.0 USDC/eUSDC

    // ============ Immutables ============

    /// @notice Hyperlane Mailbox on this chain
    IMailbox public immutable mailbox;

    /// @notice Token this bridge handles (USDC on Base, eUSDC on PulseChain)
    IERC20 public immutable token;

    /// @notice Hyperlane domain ID of the remote chain
    uint32 public immutable remoteDomain;

    // ============ State ============

    /// @notice Service operator address (calls markSettled, manages bridge)
    address public operator;

    /// @notice Pending operator for two-step transfer
    address public pendingOperator;

    /// @notice Protocol fee recipient address
    address public protocolFeeRecipient;

    /// @notice OwnBridge contract address on the remote chain (bytes32 for Hyperlane)
    bytes32 public remoteContract;

    /// @notice Incrementing nonce for deposits
    uint256 public nonce;

    /// @notice Whether the contract is paused
    bool public paused;

    // ============ LP Pool State ============

    /// @notice Total assets in the LP pool (available for fills)
    uint256 public poolAssets;

    /// @notice Total shares outstanding
    uint256 public totalShares;

    /// @notice Shares held by each LP
    mapping(address => uint256) public lpShares;

    // ============ Deposit State (source chain) ============

    struct Deposit {
        address user;           // depositor
        uint256 amount;         // gross amount locked (before fee split)
        uint256 netAmount;      // amount released on dest (after 0.3% fee)
        address destRecipient;  // recipient on dest chain
        uint64 timestamp;       // block.timestamp at deposit
        bool settled;           // markSettled() called
        bool refunded;          // refund() called
    }

    mapping(uint256 => Deposit) public deposits;

    // ============ Release Tracking (dest chain) ============

    /// @notice Tracks releases for auditability
    struct Release {
        address recipient;
        uint256 amount;
        uint256 remoteNonce;
        bool released;
    }

    mapping(uint256 => Release) public releases;
    uint256 public releaseCount;

    // ============ Events ============

    event Bridged(
        address indexed user,
        address indexed destRecipient,
        uint256 amount,
        uint256 netAmount,
        uint256 indexed nonce,
        bytes32 messageId
    );

    event Released(
        address indexed recipient,
        uint256 amount,
        uint256 remoteNonce
    );

    event Settled(
        uint256 indexed nonce,
        uint256 lpPayment,
        uint256 protocolFee
    );

    event Refunded(
        address indexed user,
        uint256 amount,
        uint256 indexed nonce
    );

    event LPDeposited(address indexed lp, uint256 amount, uint256 sharesMinted);
    event LPWithdrawn(address indexed lp, uint256 amount, uint256 sharesBurned);
    event OperatorTransferStarted(address indexed current, address indexed pending);
    event OperatorTransferred(address indexed previous, address indexed current);
    event ProtocolFeeRecipientUpdated(address indexed previous, address indexed current);
    event RemoteContractUpdated(bytes32 previous, bytes32 current);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // ============ Errors ============

    error NotOperator();
    error NotMailbox();
    error NotRemoteContract();
    error WrongOriginDomain();
    error ZeroAmount();
    error ZeroAddress();
    error DepositAlreadySettled();
    error DepositAlreadyRefunded();
    error RefundTooEarly();
    error NotDepositor();
    error InsufficientPool();
    error InsufficientShares();
    error ContractPaused();
    error NotPendingOperator();
    error RemoteContractNotSet();
    error InitialDepositTooSmall();

    // ============ Modifiers ============

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    // ============ Constructor ============

    /**
     * @param _mailbox Hyperlane Mailbox address on this chain
     * @param _token ERC20 token (USDC on Base, eUSDC on PulseChain)
     * @param _remoteDomain Hyperlane domain ID of dest chain
     * @param _operator Service operator address
     * @param _protocolFeeRecipient Address that receives 0.2% protocol fee
     */
    constructor(
        address _mailbox,
        address _token,
        uint32 _remoteDomain,
        address _operator,
        address _protocolFeeRecipient
    ) {
        if (_mailbox == address(0)) revert ZeroAddress();
        if (_token == address(0)) revert ZeroAddress();
        if (_operator == address(0)) revert ZeroAddress();
        if (_protocolFeeRecipient == address(0)) revert ZeroAddress();

        mailbox = IMailbox(_mailbox);
        token = IERC20(_token);
        remoteDomain = _remoteDomain;
        operator = _operator;
        protocolFeeRecipient = _protocolFeeRecipient;
    }

    // ============ LP Pool Functions ============

    /**
     * @notice Deposit tokens into the LP pool. Receive shares proportional to pool value.
     * @dev First depositor gets 1:1 shares. Subsequent depositors get shares at current price.
     *      Minimum first deposit of 1 USDC to prevent share inflation attacks.
     * @param amount Token amount to deposit
     * @return shares Number of shares minted
     */
    function depositLP(uint256 amount) external whenNotPaused returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();

        if (totalShares == 0) {
            // First deposit: 1:1 share ratio
            if (amount < MIN_INITIAL_DEPOSIT) revert InitialDepositTooSmall();
            shares = amount;
        } else {
            // Subsequent deposits: shares proportional to current pool value
            // shares = amount * totalShares / poolAssets
            shares = (amount * totalShares) / poolAssets;
        }

        token.safeTransferFrom(msg.sender, address(this), amount);
        lpShares[msg.sender] += shares;
        totalShares += shares;
        poolAssets += amount;

        emit LPDeposited(msg.sender, amount, shares);
    }

    /**
     * @notice Withdraw tokens from the LP pool by burning shares.
     * @dev Amount received = shares * poolAssets / totalShares.
     *      If pool has earned fees, share price > 1 and LP gets back more than deposited.
     * @param shares Number of shares to burn
     * @return amount Token amount withdrawn
     */
    function withdrawLP(uint256 shares) external returns (uint256 amount) {
        if (shares == 0) revert ZeroAmount();
        if (lpShares[msg.sender] < shares) revert InsufficientShares();

        // Calculate token amount for these shares
        amount = (shares * poolAssets) / totalShares;

        lpShares[msg.sender] -= shares;
        totalShares -= shares;
        poolAssets -= amount;

        token.safeTransfer(msg.sender, amount);

        emit LPWithdrawn(msg.sender, amount, shares);
    }

    // ============ User Functions ============

    /**
     * @notice Lock tokens for bridging to dest chain. Deducts 0.3% fee.
     *         Dispatches Hyperlane message to release tokens from LP pool on dest.
     * @param amount Gross amount to bridge (fee deducted from this)
     * @param destRecipient Recipient address on dest chain.
     *        - Bridge mode / eUSDC on-ramp: user's own address
     *        - Token on-ramp: service swap executor address
     * @return depositNonce The nonce of this deposit
     */
    function bridge(
        uint256 amount,
        address destRecipient
    ) external payable whenNotPaused returns (uint256 depositNonce) {
        if (amount == 0) revert ZeroAmount();
        if (destRecipient == address(0)) revert ZeroAddress();
        if (remoteContract == bytes32(0)) revert RemoteContractNotSet();

        // Calculate fees
        uint256 totalFee = (amount * TOTAL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 netAmount = amount - totalFee;

        // Pull tokens from user
        token.safeTransferFrom(msg.sender, address(this), amount);

        // Record deposit
        depositNonce = nonce;
        deposits[depositNonce] = Deposit({
            user: msg.sender,
            amount: amount,
            netAmount: netAmount,
            destRecipient: destRecipient,
            timestamp: uint64(block.timestamp),
            settled: false,
            refunded: false
        });

        // Dispatch Hyperlane message to dest chain
        bytes memory payload = abi.encode(destRecipient, netAmount, depositNonce);
        bytes32 messageId = mailbox.dispatch{value: msg.value}(
            remoteDomain,
            remoteContract,
            payload
        );

        emit Bridged(msg.sender, destRecipient, amount, netAmount, depositNonce, messageId);
        nonce++;
    }

    /**
     * @notice Refund a deposit that was never settled. Available after REFUND_DELAY.
     * @param _nonce Nonce of the deposit to refund
     */
    function refund(uint256 _nonce) external {
        Deposit storage d = deposits[_nonce];
        if (d.user != msg.sender) revert NotDepositor();
        if (d.settled) revert DepositAlreadySettled();
        if (d.refunded) revert DepositAlreadyRefunded();
        if (block.timestamp < d.timestamp + REFUND_DELAY) revert RefundTooEarly();

        d.refunded = true;

        // Return full amount (including fee portion) — user made no fault
        token.safeTransfer(msg.sender, d.amount);

        emit Refunded(msg.sender, d.amount, _nonce);
    }

    // ============ Hyperlane Receiver (Dest Chain) ============

    /**
     * @notice Called by Hyperlane Mailbox when a message arrives from the remote OwnBridge.
     *         Releases tokens from the LP pool to the recipient.
     * @dev No LP selection needed — pool fills everything. Just check pool has capacity.
     */
    function handle(
        uint32 _origin,
        bytes32 _sender,
        bytes calldata _payload
    ) external payable override {
        if (msg.sender != address(mailbox)) revert NotMailbox();
        if (_origin != remoteDomain) revert WrongOriginDomain();
        if (_sender != remoteContract) revert NotRemoteContract();

        (address recipient, uint256 amount, uint256 remoteNonce) =
            abi.decode(_payload, (address, uint256, uint256));

        if (poolAssets < amount) revert InsufficientPool();

        // Release from pool
        poolAssets -= amount;
        token.safeTransfer(recipient, amount);

        // Record release
        releases[releaseCount] = Release({
            recipient: recipient,
            amount: amount,
            remoteNonce: remoteNonce,
            released: true
        });
        releaseCount++;

        emit Released(recipient, amount, remoteNonce);
    }

    // ============ Operator Functions ============

    /**
     * @notice Settle a deposit: feed LP payment back to pool, send protocol fee externally.
     *         Called by operator after confirming handle() succeeded on dest chain.
     * @dev LP payment goes back into poolAssets without minting new shares.
     *      This increases the share price — every LP benefits proportionally.
     *      Protocol fee is sent to protocolFeeRecipient (not pooled).
     * @param _nonce Deposit nonce on this (source) chain
     */
    function markSettled(uint256 _nonce) external onlyOperator {
        Deposit storage d = deposits[_nonce];
        if (d.settled) revert DepositAlreadySettled();
        if (d.refunded) revert DepositAlreadyRefunded();

        d.settled = true;

        // Protocol fee: 0.2% of gross amount → external recipient
        uint256 protocolFee = (d.amount * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;

        // LP payment: gross amount minus protocol fee → back to pool
        // LP pool profit = lpPayment - netAmount = 0.1% of gross
        // This increases poolAssets without minting shares → share price rises
        uint256 lpPayment = d.amount - protocolFee;

        poolAssets += lpPayment;
        token.safeTransfer(protocolFeeRecipient, protocolFee);

        emit Settled(_nonce, lpPayment, protocolFee);
    }

    // ============ Admin Functions ============

    /**
     * @notice Start two-step operator transfer
     */
    function transferOperator(address newOperator) external onlyOperator {
        if (newOperator == address(0)) revert ZeroAddress();
        pendingOperator = newOperator;
        emit OperatorTransferStarted(operator, newOperator);
    }

    /**
     * @notice Accept operator role (two-step transfer)
     */
    function acceptOperator() external {
        if (msg.sender != pendingOperator) revert NotPendingOperator();
        address previous = operator;
        operator = msg.sender;
        pendingOperator = address(0);
        emit OperatorTransferred(previous, msg.sender);
    }

    /**
     * @notice Update protocol fee recipient address
     */
    function setProtocolFeeRecipient(address _recipient) external onlyOperator {
        if (_recipient == address(0)) revert ZeroAddress();
        address previous = protocolFeeRecipient;
        protocolFeeRecipient = _recipient;
        emit ProtocolFeeRecipientUpdated(previous, _recipient);
    }

    /**
     * @notice Set the remote OwnBridge contract address (one-time or update)
     */
    function setRemoteContract(bytes32 _remoteContract) external onlyOperator {
        bytes32 previous = remoteContract;
        remoteContract = _remoteContract;
        emit RemoteContractUpdated(previous, _remoteContract);
    }

    /**
     * @notice Emergency pause — stops new bridges and LP deposits. Withdrawals and refunds still work.
     */
    function pause() external onlyOperator {
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause bridge operations
     */
    function unpause() external onlyOperator {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ============ View Functions ============

    /**
     * @notice Quote the fee and net amount for a given bridge amount
     */
    function quote(uint256 amount) external pure returns (uint256 netAmount, uint256 totalFee) {
        totalFee = (amount * TOTAL_FEE_BPS) / BPS_DENOMINATOR;
        netAmount = amount - totalFee;
    }

    /**
     * @notice Quote the Hyperlane dispatch fee for a bridge call
     */
    function quoteDispatch(uint256 amount, address destRecipient) external view returns (uint256) {
        if (remoteContract == bytes32(0)) revert RemoteContractNotSet();
        uint256 totalFee = (amount * TOTAL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 netAmount = amount - totalFee;
        bytes memory payload = abi.encode(destRecipient, netAmount, nonce);
        return mailbox.quoteDispatch(remoteDomain, remoteContract, payload);
    }

    /**
     * @notice Check if pool can fill a given amount
     */
    function canFill(uint256 amount) external view returns (bool) {
        return poolAssets >= amount;
    }

    /**
     * @notice Current share price (tokens per share, scaled by 1e6 for precision)
     * @dev Returns 1e6 when shares are at 1:1 with tokens.
     *      Returns > 1e6 when pool has earned fees.
     */
    function sharePrice() external view returns (uint256) {
        if (totalShares == 0) return 1e6;
        return (poolAssets * 1e6) / totalShares;
    }

    /**
     * @notice Get the current token value of an LP's shares
     */
    function lpValue(address lp) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (lpShares[lp] * poolAssets) / totalShares;
    }

    /**
     * @notice Preview how many shares would be minted for a deposit amount
     */
    function previewDeposit(uint256 amount) external view returns (uint256) {
        if (totalShares == 0) return amount;
        return (amount * totalShares) / poolAssets;
    }

    /**
     * @notice Preview how many tokens would be returned for burning shares
     */
    function previewWithdraw(uint256 shares) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares * poolAssets) / totalShares;
    }
}
