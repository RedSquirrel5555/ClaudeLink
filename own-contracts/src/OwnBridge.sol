// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMailbox} from "@hyperlane/interfaces/IMailbox.sol";
import {IMessageRecipient} from "@hyperlane/interfaces/IMessageRecipient.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

/**
 * @title OwnBridge
 * @notice Bidirectional bridge for OWN Protocol. Deployed on Base (USDC) and PulseChain (eUSDC).
 *         Lock tokens on source chain, Hyperlane message triggers release from LP on dest chain.
 *
 * @dev Architecture:
 *      - Service selects LP off-chain using proportional rotation algorithm.
 *      - LP address is encoded in the Hyperlane message via bridge().
 *      - handle() on dest chain verifies LP is registered + has capacity, then pulls from LP.
 *      - markSettled() on source chain distributes locked funds to LP + protocol.
 *      - Users can always self-refund after REFUND_DELAY if settlement fails.
 *
 * LP Selection (off-chain, proportional rotation):
 *      - Service tracks cumulative fills per LP and allowances on dest chain.
 *      - Next fill goes to LP most underweight relative to their allowance share.
 *      - Over time, each LP's fill share converges to their capital share.
 *      - Contract only validates: is the selected LP registered? Do they have enough?
 *
 * Fee structure:
 *      - 0.3% total deducted from bridge amount
 *      - 0.2% -> protocol-owned LP (compounds)
 *      - 0.1% -> filling LP (implicit spread: LP gives netAmount, receives amount - 0.2%)
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

    // ============ Immutables ============

    /// @notice Hyperlane Mailbox on this chain
    IMailbox public immutable mailbox;

    /// @notice Token this bridge handles (USDC on Base, eUSDC on PulseChain)
    IERC20 public immutable token;

    /// @notice Hyperlane domain ID of the remote chain
    uint32 public immutable remoteDomain;

    // ============ State ============

    /// @notice Service operator address (calls markSettled, manages LPs)
    address public operator;

    /// @notice Pending operator for two-step transfer
    address public pendingOperator;

    /// @notice Protocol-owned LP address (receives 0.2% fee, compounds)
    address public protocolLP;

    /// @notice OwnBridge contract address on the remote chain (bytes32 for Hyperlane)
    bytes32 public remoteContract;

    /// @notice Incrementing nonce for deposits
    uint256 public nonce;

    /// @notice Whether the contract is paused
    bool public paused;

    // ============ LP State ============

    /// @notice Ordered list of active LP addresses for filling
    address[] public activeLPs;

    /// @notice Tracks whether an address is a registered LP
    mapping(address => bool) public isLP;

    // ============ Deposit State ============

    struct Deposit {
        address user;           // depositor
        uint256 amount;         // gross amount locked (before fee split)
        uint256 netAmount;      // amount sent to dest (after 0.3% fee)
        address destRecipient;  // recipient on dest chain
        address selectedLP;     // LP selected to fill on dest chain
        uint64 timestamp;       // block.timestamp at deposit
        bool settled;           // markSettled() called
        bool refunded;          // refund() called
    }

    mapping(uint256 => Deposit) public deposits;

    // ============ Release Tracking (dest chain) ============

    /// @notice Records which LP filled each release (for future trustless settlement)
    struct Release {
        address fillingLP;
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
        address selectedLP,
        bytes32 messageId
    );

    event Released(
        address indexed recipient,
        address indexed fillingLP,
        uint256 amount,
        uint256 remoteNonce
    );

    event Settled(
        uint256 indexed nonce,
        address indexed fillingLP,
        uint256 lpPayment,
        uint256 protocolFee
    );

    event Refunded(
        address indexed user,
        uint256 amount,
        uint256 indexed nonce
    );

    event LPAdded(address indexed lp);
    event LPRemoved(address indexed lp);
    event OperatorTransferStarted(address indexed current, address indexed pending);
    event OperatorTransferred(address indexed previous, address indexed current);
    event ProtocolLPUpdated(address indexed previous, address indexed current);
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
    error LPNotRegistered();
    error InsufficientLPBalance();
    error LPAlreadyActive();
    error LPNotActive();
    error ContractPaused();
    error NotPendingOperator();
    error RemoteContractNotSet();

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
     * @param _protocolLP Protocol-owned LP address
     */
    constructor(
        address _mailbox,
        address _token,
        uint32 _remoteDomain,
        address _operator,
        address _protocolLP
    ) {
        if (_mailbox == address(0)) revert ZeroAddress();
        if (_token == address(0)) revert ZeroAddress();
        if (_operator == address(0)) revert ZeroAddress();
        if (_protocolLP == address(0)) revert ZeroAddress();

        mailbox = IMailbox(_mailbox);
        token = IERC20(_token);
        remoteDomain = _remoteDomain;
        operator = _operator;
        protocolLP = _protocolLP;
    }

    // ============ User Functions ============

    /**
     * @notice Lock tokens for bridging to dest chain. Deducts 0.3% fee.
     *         Dispatches Hyperlane message to release tokens from selected LP on dest.
     * @param amount Gross amount to bridge (fee deducted from this)
     * @param destRecipient Recipient address on dest chain.
     *        - Bridge mode / eUSDC on-ramp: user's own address
     *        - Token on-ramp: service swap executor address
     * @param selectedLP LP address pre-selected by the service to fill on dest chain.
     *        Encoded in the Hyperlane message. handle() validates this on dest chain.
     * @return depositNonce The nonce of this deposit
     */
    function bridge(
        uint256 amount,
        address destRecipient,
        address selectedLP
    ) external payable whenNotPaused returns (uint256 depositNonce) {
        if (amount == 0) revert ZeroAmount();
        if (destRecipient == address(0)) revert ZeroAddress();
        if (selectedLP == address(0)) revert ZeroAddress();
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
            selectedLP: selectedLP,
            timestamp: uint64(block.timestamp),
            settled: false,
            refunded: false
        });

        // Dispatch Hyperlane message to dest chain
        // Payload includes selectedLP so handle() knows who to pull from
        bytes memory payload = abi.encode(destRecipient, netAmount, depositNonce, selectedLP);
        bytes32 messageId = mailbox.dispatch{value: msg.value}(
            remoteDomain,
            remoteContract,
            payload
        );

        emit Bridged(msg.sender, destRecipient, amount, netAmount, depositNonce, selectedLP, messageId);
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
     *         Validates the pre-selected LP and releases tokens from their allowance.
     * @dev The LP was selected off-chain by the service using proportional rotation,
     *      then encoded in the Hyperlane message at bridge() time on source chain.
     *      This function validates: LP is registered, has sufficient allowance + balance.
     */
    function handle(
        uint32 _origin,
        bytes32 _sender,
        bytes calldata _payload
    ) external payable override {
        if (msg.sender != address(mailbox)) revert NotMailbox();
        if (_origin != remoteDomain) revert WrongOriginDomain();
        if (_sender != remoteContract) revert NotRemoteContract();

        (address recipient, uint256 amount, uint256 remoteNonce, address selectedLP) =
            abi.decode(_payload, (address, uint256, uint256, address));

        // Validate the pre-selected LP
        if (!isLP[selectedLP]) revert LPNotRegistered();
        if (token.allowance(selectedLP, address(this)) < amount) revert InsufficientLPBalance();
        if (token.balanceOf(selectedLP) < amount) revert InsufficientLPBalance();

        // Pull tokens from LP's wallet (allowance model — funds stay in LP wallet until needed)
        token.safeTransferFrom(selectedLP, recipient, amount);

        // Record release for future trustless settlement
        releases[releaseCount] = Release({
            fillingLP: selectedLP,
            recipient: recipient,
            amount: amount,
            remoteNonce: remoteNonce,
            released: true
        });
        releaseCount++;

        emit Released(recipient, selectedLP, amount, remoteNonce);
    }

    // ============ Operator Functions ============

    /**
     * @notice Settle a deposit: pay the filling LP and protocol fee.
     *         Called by operator after confirming handle() succeeded on dest chain.
     * @dev Launch: operator provides fillingLP (trusted). Should match deposit.selectedLP.
     *      Future: verify fillingLP against dest chain Released event or return message.
     * @param _nonce Deposit nonce on this (source) chain
     * @param fillingLP LP address that released tokens on dest chain
     */
    function markSettled(uint256 _nonce, address fillingLP) external onlyOperator {
        Deposit storage d = deposits[_nonce];
        if (d.settled) revert DepositAlreadySettled();
        if (d.refunded) revert DepositAlreadyRefunded();
        if (fillingLP == address(0)) revert ZeroAddress();

        d.settled = true;

        // Protocol fee: 0.2% of gross amount
        uint256 protocolFee = (d.amount * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;

        // LP payment: gross amount minus protocol fee
        // LP profit = lpPayment - netAmount = 0.1% of gross (implicit spread)
        uint256 lpPayment = d.amount - protocolFee;

        token.safeTransfer(fillingLP, lpPayment);
        token.safeTransfer(protocolLP, protocolFee);

        emit Settled(_nonce, fillingLP, lpPayment, protocolFee);
    }

    // ============ LP Management ============

    /**
     * @notice Register a new LP. LP must separately approve this contract for token.
     * @param lp Address to register as LP
     */
    function addLP(address lp) external onlyOperator {
        if (lp == address(0)) revert ZeroAddress();
        if (isLP[lp]) revert LPAlreadyActive();

        isLP[lp] = true;
        activeLPs.push(lp);

        emit LPAdded(lp);
    }

    /**
     * @notice Remove an LP from the active list. Does not revoke their token allowance.
     * @param lp Address to remove
     */
    function removeLP(address lp) external onlyOperator {
        if (!isLP[lp]) revert LPNotActive();

        isLP[lp] = false;

        // Remove from array (swap with last element)
        uint256 len = activeLPs.length;
        for (uint256 i = 0; i < len; i++) {
            if (activeLPs[i] == lp) {
                activeLPs[i] = activeLPs[len - 1];
                activeLPs.pop();
                break;
            }
        }

        emit LPRemoved(lp);
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
     * @notice Update protocol-owned LP address
     */
    function setProtocolLP(address _protocolLP) external onlyOperator {
        if (_protocolLP == address(0)) revert ZeroAddress();
        address previous = protocolLP;
        protocolLP = _protocolLP;
        emit ProtocolLPUpdated(previous, _protocolLP);
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
     * @notice Emergency pause — stops new bridges. Refunds still work.
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
     * @notice Get number of active LPs
     */
    function activeLPCount() external view returns (uint256) {
        return activeLPs.length;
    }

    /**
     * @notice Get all active LP addresses
     */
    function getActiveLPs() external view returns (address[] memory) {
        return activeLPs;
    }

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
    function quoteDispatch(
        uint256 amount,
        address destRecipient,
        address selectedLP
    ) external view returns (uint256) {
        if (remoteContract == bytes32(0)) revert RemoteContractNotSet();
        uint256 totalFee = (amount * TOTAL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 netAmount = amount - totalFee;
        bytes memory payload = abi.encode(destRecipient, netAmount, nonce, selectedLP);
        return mailbox.quoteDispatch(remoteDomain, remoteContract, payload);
    }

    /**
     * @notice Check if a specific LP can fill a given amount
     */
    function canFill(address lp, uint256 amount) external view returns (bool) {
        return isLP[lp]
            && token.allowance(lp, address(this)) >= amount
            && token.balanceOf(lp) >= amount;
    }

    /**
     * @notice Get total fillable capacity across all active LPs
     */
    function totalCapacity() external view returns (uint256 total) {
        uint256 len = activeLPs.length;
        for (uint256 i = 0; i < len; i++) {
            address lp = activeLPs[i];
            uint256 allowance = token.allowance(lp, address(this));
            uint256 balance = token.balanceOf(lp);
            total += allowance < balance ? allowance : balance;
        }
    }

    /**
     * @notice Get capacity for each active LP (for service-side LP selection)
     * @return lps Array of LP addresses
     * @return capacities Array of fillable amounts (min of allowance, balance)
     */
    function getLPCapacities() external view returns (
        address[] memory lps,
        uint256[] memory capacities
    ) {
        uint256 len = activeLPs.length;
        lps = new address[](len);
        capacities = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            address lp = activeLPs[i];
            uint256 allowance = token.allowance(lp, address(this));
            uint256 balance = token.balanceOf(lp);
            lps[i] = lp;
            capacities[i] = allowance < balance ? allowance : balance;
        }
    }
}
