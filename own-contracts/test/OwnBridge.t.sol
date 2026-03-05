// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {OwnBridge} from "../src/OwnBridge.sol";
import {IMailbox} from "@hyperlane/interfaces/IMailbox.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

// ============ Mock Contracts ============

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6; // USDC-like
    }
}

contract MockMailbox {
    uint32 public localDomain;
    bytes32 public lastMessageId;
    uint256 public messageCount;
    uint256 public dispatchFee;

    struct DispatchedMessage {
        uint32 destDomain;
        bytes32 recipient;
        bytes body;
        uint256 value;
    }
    DispatchedMessage[] public dispatched;

    constructor(uint32 _localDomain) {
        localDomain = _localDomain;
    }

    function setDispatchFee(uint256 _fee) external {
        dispatchFee = _fee;
    }

    function dispatch(
        uint32 destinationDomain,
        bytes32 recipientAddress,
        bytes calldata messageBody
    ) external payable returns (bytes32 messageId) {
        require(msg.value >= dispatchFee, "Insufficient fee");
        messageId = keccak256(abi.encodePacked(messageCount, destinationDomain, recipientAddress, messageBody));
        lastMessageId = messageId;
        dispatched.push(DispatchedMessage(destinationDomain, recipientAddress, messageBody, msg.value));
        messageCount++;
    }

    function quoteDispatch(
        uint32,
        bytes32,
        bytes calldata
    ) external view returns (uint256) {
        return dispatchFee;
    }

    function dispatchedCount() external view returns (uint256) {
        return dispatched.length;
    }
}

// ============ Test Contract ============

contract OwnBridgeTest is Test {
    // Contracts
    OwnBridge public sourceBridge; // "Base" side
    OwnBridge public destBridge;   // "PulseChain" side
    MockMailbox public sourceMailbox;
    MockMailbox public destMailbox;
    MockToken public usdc;
    MockToken public eusdc;

    // Actors
    address public operator = makeAddr("operator");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");
    address public lp3 = makeAddr("lp3");
    address public user = makeAddr("user");
    address public swapExecutor = makeAddr("swapExecutor");

    // Chain domains
    uint32 public constant BASE_DOMAIN = 8453;
    uint32 public constant PULSE_DOMAIN = 369;

    function setUp() public {
        // Deploy mock infrastructure
        sourceMailbox = new MockMailbox(BASE_DOMAIN);
        destMailbox = new MockMailbox(PULSE_DOMAIN);
        usdc = new MockToken("USD Coin", "USDC");
        eusdc = new MockToken("Ethereum-bridged USDC", "eUSDC");

        // Deploy bridges
        sourceBridge = new OwnBridge(
            address(sourceMailbox),
            address(usdc),
            PULSE_DOMAIN,
            operator,
            protocolFeeRecipient
        );

        destBridge = new OwnBridge(
            address(destMailbox),
            address(eusdc),
            BASE_DOMAIN,
            operator,
            protocolFeeRecipient
        );

        // Wire remote contracts
        vm.startPrank(operator);
        sourceBridge.setRemoteContract(_toBytes32(address(destBridge)));
        destBridge.setRemoteContract(_toBytes32(address(sourceBridge)));
        vm.stopPrank();

        // Fund LP1 and deposit into dest bridge pool
        eusdc.mint(lp1, 100_000e6);
        vm.startPrank(lp1);
        eusdc.approve(address(destBridge), type(uint256).max);
        destBridge.depositLP(100_000e6);
        vm.stopPrank();

        // Fund user with USDC
        usdc.mint(user, 50_000e6);
    }

    // ============ Helper ============

    function _toBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /// @dev Simulate Hyperlane delivery: call handle() on dest bridge as the mailbox
    function _deliverMessage(
        address recipient,
        uint256 netAmount,
        uint256 remoteNonce
    ) internal {
        bytes memory payload = abi.encode(recipient, netAmount, remoteNonce);
        vm.prank(address(destMailbox));
        destBridge.handle(
            BASE_DOMAIN,
            _toBytes32(address(sourceBridge)),
            payload
        );
    }

    // ============ LP Pool Tests ============

    function test_depositLP_first_deposit() public {
        // LP1 already deposited 100k in setUp
        assertEq(destBridge.poolAssets(), 100_000e6);
        assertEq(destBridge.totalShares(), 100_000e6); // 1:1 for first deposit
        assertEq(destBridge.lpShares(lp1), 100_000e6);
        assertEq(eusdc.balanceOf(lp1), 0); // all deposited
    }

    function test_depositLP_second_deposit_at_par() public {
        // LP2 deposits 50k when pool is at par (no fees earned yet)
        eusdc.mint(lp2, 50_000e6);
        vm.startPrank(lp2);
        eusdc.approve(address(destBridge), type(uint256).max);
        uint256 shares = destBridge.depositLP(50_000e6);
        vm.stopPrank();

        assertEq(shares, 50_000e6); // 1:1 since no fees earned
        assertEq(destBridge.poolAssets(), 150_000e6);
        assertEq(destBridge.totalShares(), 150_000e6);
        assertEq(destBridge.lpShares(lp2), 50_000e6);
    }

    function test_depositLP_after_fees_earned() public {
        // Simulate pool earning fees by doing a bridge cycle
        // Pool starts: 100k assets, 100k shares (share price = 1.0)

        // Deliver a bridge fill (pool decreases)
        _deliverMessage(user, 997e6, 0);
        // Pool: 100_000 - 997 = 99_003 assets, 100_000 shares

        // Simulate settlement on source chain feeding LP payment back
        // In a real flow, this happens on the source bridge. For this test,
        // we directly increase poolAssets to simulate the effect on dest chain.
        // The dest pool earned from a previous cycle's settlement.
        // Let's say the pool earned 10 USDC in fees from prior settlements.
        eusdc.mint(address(destBridge), 10e6);

        // Manually update pool assets to reflect earnings
        // In production, markSettled does this on the source chain.
        // On dest chain, pool assets decrease on fills and get replenished by LP deposits.
        // For this test, let's use a direct deposit scenario.

        // Reset: Start fresh with a simpler scenario
        // Pool: 99_003e6 assets, 100_000e6 shares
        // share price = 99_003 / 100_000 = 0.99003 per share (pool temporarily down during fills)
        // LP2 deposits 50k at this price
        eusdc.mint(lp2, 50_000e6);
        vm.startPrank(lp2);
        eusdc.approve(address(destBridge), type(uint256).max);
        uint256 shares = destBridge.depositLP(50_000e6);
        vm.stopPrank();

        // shares = 50_000 * 100_000 / 99_003 = ~50,503 shares
        // LP2 gets slightly more shares because pool is temporarily depleted
        assertGt(shares, 50_000e6);
        assertEq(destBridge.poolAssets(), 99_003e6 + 50_000e6);
    }

    function test_depositLP_reverts_zero() public {
        vm.expectRevert(OwnBridge.ZeroAmount.selector);
        destBridge.depositLP(0);
    }

    function test_depositLP_reverts_initial_too_small() public {
        OwnBridge freshBridge = new OwnBridge(
            address(destMailbox), address(eusdc), BASE_DOMAIN, operator, protocolFeeRecipient
        );

        eusdc.mint(address(this), 1000);
        eusdc.approve(address(freshBridge), 1000);
        vm.expectRevert(OwnBridge.InitialDepositTooSmall.selector);
        freshBridge.depositLP(1000); // < 1e6 MIN_INITIAL_DEPOSIT
    }

    function test_depositLP_reverts_when_paused() public {
        vm.prank(operator);
        destBridge.pause();

        eusdc.mint(lp2, 10_000e6);
        vm.startPrank(lp2);
        eusdc.approve(address(destBridge), type(uint256).max);
        vm.expectRevert(OwnBridge.ContractPaused.selector);
        destBridge.depositLP(10_000e6);
        vm.stopPrank();
    }

    function test_withdrawLP_full() public {
        // LP1 withdraws everything
        uint256 shares = destBridge.lpShares(lp1);
        vm.prank(lp1);
        uint256 amount = destBridge.withdrawLP(shares);

        assertEq(amount, 100_000e6);
        assertEq(destBridge.poolAssets(), 0);
        assertEq(destBridge.totalShares(), 0);
        assertEq(destBridge.lpShares(lp1), 0);
        assertEq(eusdc.balanceOf(lp1), 100_000e6);
    }

    function test_withdrawLP_partial() public {
        uint256 halfShares = destBridge.lpShares(lp1) / 2;
        vm.prank(lp1);
        uint256 amount = destBridge.withdrawLP(halfShares);

        assertEq(amount, 50_000e6);
        assertEq(destBridge.poolAssets(), 50_000e6);
        assertEq(destBridge.lpShares(lp1), 50_000e6);
    }

    function test_withdrawLP_reverts_insufficient() public {
        vm.prank(lp2); // lp2 has no shares
        vm.expectRevert(OwnBridge.InsufficientShares.selector);
        destBridge.withdrawLP(1);
    }

    function test_withdrawLP_reverts_zero() public {
        vm.prank(lp1);
        vm.expectRevert(OwnBridge.ZeroAmount.selector);
        destBridge.withdrawLP(0);
    }

    function test_withdrawLP_works_when_paused() public {
        // Withdrawals should always work — LP exit must not be blocked
        vm.prank(operator);
        destBridge.pause();

        uint256 shares = destBridge.lpShares(lp1);
        vm.prank(lp1);
        uint256 amount = destBridge.withdrawLP(shares);
        assertEq(amount, 100_000e6);
    }

    // ============ Share Price Tests ============

    function test_sharePrice_initial() public view {
        // 1:1 at start
        assertEq(destBridge.sharePrice(), 1e6);
    }

    function test_sharePrice_after_pool_depleted() public {
        // Fill reduces pool
        _deliverMessage(user, 10_000e6, 0);
        // Pool: 90_000 assets, 100_000 shares
        assertEq(destBridge.sharePrice(), 900000); // 0.9 per share
    }

    function test_lpValue() public view {
        assertEq(destBridge.lpValue(lp1), 100_000e6);
        assertEq(destBridge.lpValue(lp2), 0);
    }

    function test_previewDeposit() public view {
        assertEq(destBridge.previewDeposit(10_000e6), 10_000e6); // 1:1 at par
    }

    function test_previewWithdraw() public view {
        assertEq(destBridge.previewWithdraw(10_000e6), 10_000e6); // 1:1 at par
    }

    // ============ Bridge Tests ============

    function test_bridge_basic() public {
        uint256 amount = 1000e6;

        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);
        vm.stopPrank();

        // Check deposit recorded
        (
            address dUser,
            uint256 dAmount,
            uint256 dNetAmount,
            address dRecipient,
            uint64 dTimestamp,
            bool dSettled,
            bool dRefunded
        ) = sourceBridge.deposits(depositNonce);

        assertEq(dUser, user);
        assertEq(dAmount, 1000e6);
        assertEq(dNetAmount, 997e6); // 0.3% fee
        assertEq(dRecipient, user);
        assertFalse(dSettled);
        assertFalse(dRefunded);

        // Tokens moved to bridge
        assertEq(usdc.balanceOf(address(sourceBridge)), 1000e6);
        assertEq(usdc.balanceOf(user), 49_000e6);

        // Hyperlane message dispatched
        assertEq(sourceMailbox.dispatchedCount(), 1);
    }

    function test_bridge_payload_no_lp() public {
        uint256 amount = 1000e6;

        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        sourceBridge.bridge(amount, user);
        vm.stopPrank();

        // Verify payload has no LP — just (recipient, netAmount, nonce)
        (, , bytes memory body, ) = sourceMailbox.dispatched(0);
        (address recipient, uint256 netAmount, uint256 nonce_) =
            abi.decode(body, (address, uint256, uint256));

        assertEq(recipient, user);
        assertEq(netAmount, 997e6);
        assertEq(nonce_, 0);
    }

    function test_bridge_fee_calculation() public view {
        uint256[4] memory amounts = [uint256(500e6), 1000e6, 2500e6, 10000e6];
        uint256[4] memory expectedNet = [uint256(498_500000), 997_000000, 2_492_500000, 9_970_000000];

        for (uint256 i = 0; i < amounts.length; i++) {
            (uint256 net, uint256 fee) = sourceBridge.quote(amounts[i]);
            assertEq(net, expectedNet[i], "Net amount mismatch");
            assertEq(fee, amounts[i] - expectedNet[i], "Fee mismatch");
        }
    }

    function test_bridge_with_swap_executor() public {
        uint256 amount = 500e6;

        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, swapExecutor);
        vm.stopPrank();

        (, , , address dRecipient, , , ) = sourceBridge.deposits(depositNonce);
        assertEq(dRecipient, swapExecutor);
    }

    function test_bridge_reverts_zero_amount() public {
        vm.prank(user);
        vm.expectRevert(OwnBridge.ZeroAmount.selector);
        sourceBridge.bridge(0, user);
    }

    function test_bridge_reverts_zero_recipient() public {
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), 1000e6);
        vm.expectRevert(OwnBridge.ZeroAddress.selector);
        sourceBridge.bridge(1000e6, address(0));
        vm.stopPrank();
    }

    function test_bridge_reverts_when_paused() public {
        vm.prank(operator);
        sourceBridge.pause();

        vm.startPrank(user);
        usdc.approve(address(sourceBridge), 1000e6);
        vm.expectRevert(OwnBridge.ContractPaused.selector);
        sourceBridge.bridge(1000e6, user);
        vm.stopPrank();
    }

    function test_bridge_reverts_no_remote_contract() public {
        OwnBridge freshBridge = new OwnBridge(
            address(sourceMailbox), address(usdc), PULSE_DOMAIN, operator, protocolFeeRecipient
        );

        vm.startPrank(user);
        usdc.approve(address(freshBridge), 1000e6);
        vm.expectRevert(OwnBridge.RemoteContractNotSet.selector);
        freshBridge.bridge(1000e6, user);
        vm.stopPrank();
    }

    function test_bridge_with_hyperlane_fee() public {
        sourceMailbox.setDispatchFee(0.001 ether);
        uint256 amount = 1000e6;

        vm.deal(user, 1 ether);
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        sourceBridge.bridge{value: 0.001 ether}(amount, user);
        vm.stopPrank();

        assertEq(sourceMailbox.dispatchedCount(), 1);
    }

    // ============ Handle (Dest Chain Release) Tests ============

    function test_handle_releases_from_pool() public {
        uint256 netAmount = 997e6;
        _deliverMessage(user, netAmount, 0);

        // User received tokens
        assertEq(eusdc.balanceOf(user), netAmount);
        // Pool decreased
        assertEq(destBridge.poolAssets(), 100_000e6 - netAmount);

        // Release recorded
        (address recipient, uint256 amount, uint256 rNonce, bool released) =
            destBridge.releases(0);
        assertEq(recipient, user);
        assertEq(amount, netAmount);
        assertEq(rNonce, 0);
        assertTrue(released);
    }

    function test_handle_to_swap_executor() public {
        uint256 netAmount = 498_500000;
        _deliverMessage(swapExecutor, netAmount, 0);
        assertEq(eusdc.balanceOf(swapExecutor), netAmount);
    }

    function test_handle_reverts_insufficient_pool() public {
        // Try to release more than pool has
        bytes memory payload = abi.encode(user, 200_000e6, uint256(0));
        vm.prank(address(destMailbox));
        vm.expectRevert(OwnBridge.InsufficientPool.selector);
        destBridge.handle(BASE_DOMAIN, _toBytes32(address(sourceBridge)), payload);
    }

    function test_handle_reverts_wrong_caller() public {
        bytes memory payload = abi.encode(user, 997e6, uint256(0));
        vm.prank(user);
        vm.expectRevert(OwnBridge.NotMailbox.selector);
        destBridge.handle(BASE_DOMAIN, _toBytes32(address(sourceBridge)), payload);
    }

    function test_handle_reverts_wrong_origin() public {
        bytes memory payload = abi.encode(user, 997e6, uint256(0));
        vm.prank(address(destMailbox));
        vm.expectRevert(OwnBridge.WrongOriginDomain.selector);
        destBridge.handle(999, _toBytes32(address(sourceBridge)), payload);
    }

    function test_handle_reverts_wrong_sender() public {
        bytes memory payload = abi.encode(user, 997e6, uint256(0));
        vm.prank(address(destMailbox));
        vm.expectRevert(OwnBridge.NotRemoteContract.selector);
        destBridge.handle(BASE_DOMAIN, _toBytes32(address(0xdead)), payload);
    }

    function test_handle_multiple_fills() public {
        _deliverMessage(user, 1000e6, 0);
        _deliverMessage(user, 2000e6, 1);
        _deliverMessage(user, 500e6, 2);

        assertEq(eusdc.balanceOf(user), 3500e6);
        assertEq(destBridge.poolAssets(), 100_000e6 - 3500e6);
        assertEq(destBridge.releaseCount(), 3);
    }

    // ============ Settlement Tests ============

    function test_markSettled_pool_model() public {
        uint256 amount = 1000e6;

        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);
        vm.stopPrank();

        // Also deposit LP into source bridge pool (for accounting test)
        usdc.mint(lp1, 100_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(sourceBridge), type(uint256).max);
        sourceBridge.depositLP(100_000e6);
        vm.stopPrank();

        uint256 poolBefore = sourceBridge.poolAssets();

        vm.prank(operator);
        sourceBridge.markSettled(depositNonce);

        // Protocol fee: 1000 * 0.2% = 2.00 USDC → protocolFeeRecipient
        assertEq(usdc.balanceOf(protocolFeeRecipient), 2e6);

        // LP payment: 1000 - 2 = 998 USDC → back to pool
        assertEq(sourceBridge.poolAssets(), poolBefore + 998e6);

        // Bridge should have no "orphaned" user funds
        (, , , , , bool settled, ) = sourceBridge.deposits(depositNonce);
        assertTrue(settled);
    }

    function test_markSettled_increases_share_price() public {
        // Setup: LP1 deposited 100k into source bridge pool
        usdc.mint(lp1, 100_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(sourceBridge), type(uint256).max);
        sourceBridge.depositLP(100_000e6);
        vm.stopPrank();

        assertEq(sourceBridge.sharePrice(), 1e6); // 1.0 at start

        // User bridges 10,000 USDC
        uint256 amount = 10_000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);
        vm.stopPrank();

        // Settle — LP payment goes to pool
        vm.prank(operator);
        sourceBridge.markSettled(depositNonce);

        // Pool: 100_000 + 9_980 (LP payment) = 109_980
        // Shares: 100_000 (unchanged)
        // Share price: 109_980 / 100_000 = 1.0998
        assertEq(sourceBridge.poolAssets(), 100_000e6 + 9_980e6);
        assertEq(sourceBridge.totalShares(), 100_000e6);
        assertEq(sourceBridge.sharePrice(), 1_099800); // 1.0998 * 1e6

        // LP1 can now withdraw more than they deposited
        uint256 lpValueNow = sourceBridge.lpValue(lp1);
        assertEq(lpValueNow, 109_980e6);
    }

    function test_markSettled_no_fillingLP_param() public {
        // markSettled in pool model takes just nonce — no fillingLP
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);
        vm.stopPrank();

        // Need pool on source for settlement to work
        usdc.mint(lp1, 10_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(sourceBridge), type(uint256).max);
        sourceBridge.depositLP(10_000e6);
        vm.stopPrank();

        vm.prank(operator);
        sourceBridge.markSettled(depositNonce);

        (, , , , , bool settled, ) = sourceBridge.deposits(depositNonce);
        assertTrue(settled);
    }

    function test_markSettled_reverts_not_operator() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert(OwnBridge.NotOperator.selector);
        sourceBridge.markSettled(depositNonce);
    }

    function test_markSettled_reverts_double_settle() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);
        vm.stopPrank();

        vm.startPrank(operator);
        sourceBridge.markSettled(depositNonce);
        vm.expectRevert(OwnBridge.DepositAlreadySettled.selector);
        sourceBridge.markSettled(depositNonce);
        vm.stopPrank();
    }

    function test_markSettled_reverts_after_refund() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);
        vm.prank(user);
        sourceBridge.refund(depositNonce);

        vm.prank(operator);
        vm.expectRevert(OwnBridge.DepositAlreadyRefunded.selector);
        sourceBridge.markSettled(depositNonce);
    }

    // ============ Pro-Rata LP Earnings Tests ============

    function test_multiple_lps_earn_proportionally() public {
        // Setup source bridge with LP1 (100k) and LP2 (50k)
        usdc.mint(lp1, 100_000e6);
        usdc.mint(lp2, 50_000e6);

        vm.startPrank(lp1);
        usdc.approve(address(sourceBridge), type(uint256).max);
        sourceBridge.depositLP(100_000e6);
        vm.stopPrank();

        vm.startPrank(lp2);
        usdc.approve(address(sourceBridge), type(uint256).max);
        sourceBridge.depositLP(50_000e6);
        vm.stopPrank();

        // LP1: 100k shares (66.7%), LP2: 50k shares (33.3%)
        assertEq(sourceBridge.lpShares(lp1), 100_000e6);
        assertEq(sourceBridge.lpShares(lp2), 50_000e6);

        // User bridges 1000 USDC
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);
        vm.stopPrank();

        // Settle — 998 USDC goes to pool
        vm.prank(operator);
        sourceBridge.markSettled(depositNonce);

        // Pool: 150_000 + 998 = 150_998
        assertEq(sourceBridge.poolAssets(), 150_998e6);

        // LP1 value: 100_000 * 150_998 / 150_000 = 100_665.333...
        // LP2 value: 50_000 * 150_998 / 150_000 = 50_332.666...
        uint256 lp1Value = sourceBridge.lpValue(lp1);
        uint256 lp2Value = sourceBridge.lpValue(lp2);

        // LP1 earned ~2/3 of the 998 profit, LP2 earned ~1/3
        uint256 lp1Profit = lp1Value - 100_000e6;
        uint256 lp2Profit = lp2Value - 50_000e6;

        // LP1 profit should be ~2x LP2 profit (proportional to share)
        // Allow 1 unit of rounding tolerance
        assertApproxEqAbs(lp1Profit, lp2Profit * 2, 1);

        // Total earnings = 998 (LP payment - net amount accounts for the spread)
        assertApproxEqAbs(lp1Profit + lp2Profit, 998e6, 1);
    }

    function test_late_lp_doesnt_get_past_earnings() public {
        // Setup: LP1 deposits 100k, a settlement happens, THEN LP2 joins
        usdc.mint(lp1, 100_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(sourceBridge), type(uint256).max);
        sourceBridge.depositLP(100_000e6);
        vm.stopPrank();

        // Bridge and settle — pool earns 998 USDC
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);
        vm.stopPrank();

        vm.prank(operator);
        sourceBridge.markSettled(depositNonce);

        // Pool: 100_998 assets, 100_000 shares
        // Share price: 1.00998

        // NOW LP2 deposits 50k
        usdc.mint(lp2, 50_000e6);
        vm.startPrank(lp2);
        usdc.approve(address(sourceBridge), type(uint256).max);
        uint256 lp2Shares = sourceBridge.depositLP(50_000e6);
        vm.stopPrank();

        // LP2 gets fewer shares because share price > 1
        // shares = 50_000 * 100_000 / 100_998 = ~49,506
        assertLt(lp2Shares, 50_000e6);

        // LP2's value is exactly 50k (they get what they put in)
        assertApproxEqAbs(sourceBridge.lpValue(lp2), 50_000e6, 1);

        // LP1's value includes the earned fees
        assertApproxEqAbs(sourceBridge.lpValue(lp1), 100_998e6, 1);
    }

    // ============ Refund Tests ============

    function test_refund_after_delay() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);

        vm.warp(block.timestamp + 2 hours);
        sourceBridge.refund(depositNonce);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user), 50_000e6); // full amount back
    }

    function test_refund_reverts_too_early() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);

        vm.expectRevert(OwnBridge.RefundTooEarly.selector);
        sourceBridge.refund(depositNonce);
        vm.stopPrank();
    }

    function test_refund_at_exact_boundary() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);

        // 1 second before 2 hours — should revert
        vm.warp(block.timestamp + 2 hours - 1);
        vm.expectRevert(OwnBridge.RefundTooEarly.selector);
        sourceBridge.refund(depositNonce);

        // Exactly at 2 hours — should succeed
        vm.warp(block.timestamp + 1);
        sourceBridge.refund(depositNonce);
        vm.stopPrank();
    }

    function test_refund_reverts_wrong_user() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);
        vm.prank(lp1);
        vm.expectRevert(OwnBridge.NotDepositor.selector);
        sourceBridge.refund(depositNonce);
    }

    function test_refund_reverts_after_settlement() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);
        vm.stopPrank();

        vm.prank(operator);
        sourceBridge.markSettled(depositNonce);

        vm.warp(block.timestamp + 2 hours);
        vm.prank(user);
        vm.expectRevert(OwnBridge.DepositAlreadySettled.selector);
        sourceBridge.refund(depositNonce);
    }

    function test_refund_reverts_double_refund() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);

        vm.warp(block.timestamp + 2 hours);
        sourceBridge.refund(depositNonce);

        vm.expectRevert(OwnBridge.DepositAlreadyRefunded.selector);
        sourceBridge.refund(depositNonce);
        vm.stopPrank();
    }

    function test_refund_does_not_affect_pool() public {
        // Deposit LP into source bridge
        usdc.mint(lp1, 10_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(sourceBridge), type(uint256).max);
        sourceBridge.depositLP(10_000e6);
        vm.stopPrank();

        uint256 poolBefore = sourceBridge.poolAssets();

        // Bridge and refund
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);
        vm.warp(block.timestamp + 2 hours);
        sourceBridge.refund(depositNonce);
        vm.stopPrank();

        // Pool unchanged — refund comes from user's locked deposit, not pool
        assertEq(sourceBridge.poolAssets(), poolBefore);
    }

    // ============ Admin Tests ============

    function test_operator_transfer_two_step() public {
        address newOp = makeAddr("newOperator");

        vm.prank(operator);
        sourceBridge.transferOperator(newOp);
        assertEq(sourceBridge.pendingOperator(), newOp);
        assertEq(sourceBridge.operator(), operator);

        vm.prank(newOp);
        sourceBridge.acceptOperator();
        assertEq(sourceBridge.operator(), newOp);
        assertEq(sourceBridge.pendingOperator(), address(0));
    }

    function test_acceptOperator_reverts_wrong_caller() public {
        address newOp = makeAddr("newOperator");
        vm.prank(operator);
        sourceBridge.transferOperator(newOp);

        vm.prank(user);
        vm.expectRevert(OwnBridge.NotPendingOperator.selector);
        sourceBridge.acceptOperator();
    }

    function test_pause_unpause() public {
        vm.startPrank(operator);
        sourceBridge.pause();
        assertTrue(sourceBridge.paused());
        sourceBridge.unpause();
        assertFalse(sourceBridge.paused());
        vm.stopPrank();
    }

    function test_pause_does_not_block_refunds() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);
        vm.stopPrank();

        vm.prank(operator);
        sourceBridge.pause();

        vm.warp(block.timestamp + 2 hours);
        vm.prank(user);
        sourceBridge.refund(depositNonce);
        assertEq(usdc.balanceOf(user), 50_000e6);
    }

    function test_setProtocolFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(operator);
        sourceBridge.setProtocolFeeRecipient(newRecipient);
        assertEq(sourceBridge.protocolFeeRecipient(), newRecipient);
    }

    function test_setRemoteContract() public {
        bytes32 newRemote = _toBytes32(makeAddr("newRemote"));
        vm.prank(operator);
        sourceBridge.setRemoteContract(newRemote);
        assertEq(sourceBridge.remoteContract(), newRemote);
    }

    // ============ View Function Tests ============

    function test_quote() public view {
        (uint256 net, uint256 fee) = sourceBridge.quote(1000e6);
        assertEq(net, 997e6);
        assertEq(fee, 3e6);
    }

    function test_canFill() public view {
        assertTrue(destBridge.canFill(50_000e6));
        assertTrue(destBridge.canFill(100_000e6));
        assertFalse(destBridge.canFill(100_001e6));
    }

    // ============ End-to-End Flow Tests ============

    function test_full_bridge_flow() public {
        // Setup: source bridge also needs LP pool for settlement
        usdc.mint(lp1, 100_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(sourceBridge), type(uint256).max);
        sourceBridge.depositLP(100_000e6);
        vm.stopPrank();

        uint256 amount = 1000e6;

        // Step 1: User bridges on source
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);
        vm.stopPrank();

        // Step 2: Hyperlane delivers message to dest → pool fills
        _deliverMessage(user, 997e6, depositNonce);
        assertEq(eusdc.balanceOf(user), 997e6);
        assertEq(destBridge.poolAssets(), 100_000e6 - 997e6);

        // Step 3: Operator settles on source → pool earns, protocol gets fee
        vm.prank(operator);
        sourceBridge.markSettled(depositNonce);

        assertEq(usdc.balanceOf(protocolFeeRecipient), 2e6);          // 0.2% protocol fee
        assertEq(sourceBridge.poolAssets(), 100_000e6 + 998e6);       // pool grew by LP payment
    }

    function test_full_onramp_flow_with_swap_executor() public {
        uint256 amount = 500e6;

        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, swapExecutor);
        vm.stopPrank();

        _deliverMessage(swapExecutor, 498_500000, depositNonce);
        assertEq(eusdc.balanceOf(swapExecutor), 498_500000);
    }

    function test_multiple_bridges() public {
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), type(uint256).max);

        uint256 n0 = sourceBridge.bridge(1000e6, user);
        uint256 n1 = sourceBridge.bridge(2000e6, user);
        uint256 n2 = sourceBridge.bridge(500e6, user);
        vm.stopPrank();

        // Deliver all fills from pool
        _deliverMessage(user, 997e6, n0);
        _deliverMessage(user, 1994e6, n1);
        _deliverMessage(user, 498_500000, n2);

        assertEq(eusdc.balanceOf(user), 997e6 + 1994e6 + 498_500000);
        assertEq(destBridge.poolAssets(), 100_000e6 - 997e6 - 1994e6 - 498_500000);
        assertEq(destBridge.releaseCount(), 3);
    }

    // ============ Edge Case Tests ============

    function test_nonce_increments() public {
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), type(uint256).max);

        uint256 n0 = sourceBridge.bridge(100e6, user);
        uint256 n1 = sourceBridge.bridge(100e6, user);
        uint256 n2 = sourceBridge.bridge(100e6, user);
        vm.stopPrank();

        assertEq(n0, 0);
        assertEq(n1, 1);
        assertEq(n2, 2);
        assertEq(sourceBridge.nonce(), 3);
    }

    function test_pool_rebalances_after_fill_and_settle() public {
        // Dest pool starts at 100k
        // Fill depletes it by 10k
        _deliverMessage(user, 10_000e6, 0);
        assertEq(destBridge.poolAssets(), 90_000e6);

        // LP2 deposits during depleted state
        eusdc.mint(lp2, 10_000e6);
        vm.startPrank(lp2);
        eusdc.approve(address(destBridge), type(uint256).max);
        destBridge.depositLP(10_000e6);
        vm.stopPrank();

        assertEq(destBridge.poolAssets(), 100_000e6);
    }

    // ============ Fuzz Tests ============

    function testFuzz_bridge_fee_invariant(uint256 amount) public view {
        amount = bound(amount, 1, 1e18);

        (uint256 net, uint256 fee) = sourceBridge.quote(amount);
        assertEq(net + fee, amount);
        assertLe(fee, (amount * 30) / 10000);
        assertGe(net, amount - (amount * 30) / 10000);
    }

    function testFuzz_deposit_withdraw_roundtrip(uint256 amount) public {
        amount = bound(amount, 1e6, 1e15); // Min 1 USDC, reasonable max

        OwnBridge freshBridge = new OwnBridge(
            address(destMailbox), address(eusdc), BASE_DOMAIN, operator, protocolFeeRecipient
        );

        eusdc.mint(address(this), amount);
        eusdc.approve(address(freshBridge), amount);

        uint256 shares = freshBridge.depositLP(amount);
        uint256 withdrawn = freshBridge.withdrawLP(shares);

        // Should get back exactly what was deposited (no fees earned = no change)
        assertEq(withdrawn, amount);
    }

    function testFuzz_settlement_distribution(uint256 amount) public {
        amount = bound(amount, 100, 1e15);

        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user);
        vm.stopPrank();

        vm.prank(operator);
        sourceBridge.markSettled(depositNonce);

        uint256 protocolFee = (amount * 20) / 10000;
        assertEq(usdc.balanceOf(protocolFeeRecipient), protocolFee);

        // Source bridge balance should be: user deposit amount - protocol fee
        // (LP payment stays in contract as poolAssets, but there's no pool on source in this test)
        // Actually: settled funds = protocolFee (sent out) + lpPayment (added to poolAssets)
        // poolAssets increased by lpPayment
        assertEq(sourceBridge.poolAssets(), amount - protocolFee);
    }

    function testFuzz_multi_lp_proportional(uint256 deposit1, uint256 deposit2) public {
        deposit1 = bound(deposit1, 1e6, 1e12);
        deposit2 = bound(deposit2, 1e6, 1e12);

        OwnBridge freshBridge = new OwnBridge(
            address(destMailbox), address(eusdc), BASE_DOMAIN, operator, protocolFeeRecipient
        );

        eusdc.mint(lp1, deposit1);
        eusdc.mint(lp2, deposit2);

        vm.startPrank(lp1);
        eusdc.approve(address(freshBridge), deposit1);
        freshBridge.depositLP(deposit1);
        vm.stopPrank();

        vm.startPrank(lp2);
        eusdc.approve(address(freshBridge), deposit2);
        freshBridge.depositLP(deposit2);
        vm.stopPrank();

        // Both withdraw — should get back exactly what they put in (no earnings)
        uint256 lp1Shares = freshBridge.lpShares(lp1);
        uint256 lp2Shares = freshBridge.lpShares(lp2);

        vm.prank(lp1);
        uint256 lp1Got = freshBridge.withdrawLP(lp1Shares);
        vm.prank(lp2);
        uint256 lp2Got = freshBridge.withdrawLP(lp2Shares);

        // Allow 1 unit rounding per LP
        assertApproxEqAbs(lp1Got, deposit1, 1);
        assertApproxEqAbs(lp2Got, deposit2, 1);
    }
}
