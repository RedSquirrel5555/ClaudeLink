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
    address public protocolLP = makeAddr("protocolLP");
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
            protocolLP
        );

        destBridge = new OwnBridge(
            address(destMailbox),
            address(eusdc),
            BASE_DOMAIN,
            operator,
            protocolLP
        );

        // Wire remote contracts
        vm.startPrank(operator);
        sourceBridge.setRemoteContract(_toBytes32(address(destBridge)));
        destBridge.setRemoteContract(_toBytes32(address(sourceBridge)));

        // Register LP1 on dest chain
        destBridge.addLP(lp1);
        vm.stopPrank();

        // Fund LP1 with eUSDC and approve dest bridge
        eusdc.mint(lp1, 100_000e6);
        vm.prank(lp1);
        eusdc.approve(address(destBridge), type(uint256).max);

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
        uint256 remoteNonce,
        address selectedLP
    ) internal {
        bytes memory payload = abi.encode(recipient, netAmount, remoteNonce, selectedLP);
        vm.prank(address(destMailbox));
        destBridge.handle(
            BASE_DOMAIN,
            _toBytes32(address(sourceBridge)),
            payload
        );
    }

    // ============ Bridge Tests ============

    function test_bridge_basic() public {
        uint256 amount = 1000e6;

        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user, lp1);
        vm.stopPrank();

        // Check deposit recorded with selectedLP
        (
            address dUser,
            uint256 dAmount,
            uint256 dNetAmount,
            address dRecipient,
            address dSelectedLP,
            uint64 dTimestamp,
            bool dSettled,
            bool dRefunded
        ) = sourceBridge.deposits(depositNonce);

        assertEq(dUser, user);
        assertEq(dAmount, 1000e6);
        assertEq(dNetAmount, 997e6);
        assertEq(dRecipient, user);
        assertEq(dSelectedLP, lp1);
        assertFalse(dSettled);
        assertFalse(dRefunded);

        // Tokens moved to bridge
        assertEq(usdc.balanceOf(address(sourceBridge)), 1000e6);
        assertEq(usdc.balanceOf(user), 49_000e6);

        // Hyperlane message dispatched
        assertEq(sourceMailbox.dispatchedCount(), 1);
    }

    function test_bridge_encodes_lp_in_message() public {
        uint256 amount = 1000e6;

        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        sourceBridge.bridge(amount, user, lp1);
        vm.stopPrank();

        // Verify the dispatched message payload contains the selected LP
        (, , bytes memory body, ) = sourceMailbox.dispatched(0);
        (address recipient, uint256 netAmount, uint256 nonce_, address selectedLP) =
            abi.decode(body, (address, uint256, uint256, address));

        assertEq(recipient, user);
        assertEq(netAmount, 997e6);
        assertEq(nonce_, 0);
        assertEq(selectedLP, lp1);
    }

    function test_bridge_fee_calculation() public {
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
        uint256 depositNonce = sourceBridge.bridge(amount, swapExecutor, lp1);
        vm.stopPrank();

        (, , , address dRecipient, , , , ) = sourceBridge.deposits(depositNonce);
        assertEq(dRecipient, swapExecutor);
    }

    function test_bridge_reverts_zero_amount() public {
        vm.prank(user);
        vm.expectRevert(OwnBridge.ZeroAmount.selector);
        sourceBridge.bridge(0, user, lp1);
    }

    function test_bridge_reverts_zero_recipient() public {
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), 1000e6);
        vm.expectRevert(OwnBridge.ZeroAddress.selector);
        sourceBridge.bridge(1000e6, address(0), lp1);
        vm.stopPrank();
    }

    function test_bridge_reverts_zero_lp() public {
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), 1000e6);
        vm.expectRevert(OwnBridge.ZeroAddress.selector);
        sourceBridge.bridge(1000e6, user, address(0));
        vm.stopPrank();
    }

    function test_bridge_reverts_when_paused() public {
        vm.prank(operator);
        sourceBridge.pause();

        vm.startPrank(user);
        usdc.approve(address(sourceBridge), 1000e6);
        vm.expectRevert(OwnBridge.ContractPaused.selector);
        sourceBridge.bridge(1000e6, user, lp1);
        vm.stopPrank();
    }

    function test_bridge_reverts_no_remote_contract() public {
        OwnBridge freshBridge = new OwnBridge(
            address(sourceMailbox),
            address(usdc),
            PULSE_DOMAIN,
            operator,
            protocolLP
        );

        vm.startPrank(user);
        usdc.approve(address(freshBridge), 1000e6);
        vm.expectRevert(OwnBridge.RemoteContractNotSet.selector);
        freshBridge.bridge(1000e6, user, lp1);
        vm.stopPrank();
    }

    function test_bridge_with_hyperlane_fee() public {
        sourceMailbox.setDispatchFee(0.001 ether);
        uint256 amount = 1000e6;

        vm.deal(user, 1 ether);
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        sourceBridge.bridge{value: 0.001 ether}(amount, user, lp1);
        vm.stopPrank();

        assertEq(sourceMailbox.dispatchedCount(), 1);
    }

    // ============ Handle (Dest Chain Release) Tests ============

    function test_handle_releases_from_selected_lp() public {
        uint256 netAmount = 997e6;
        _deliverMessage(user, netAmount, 0, lp1);

        // User received tokens
        assertEq(eusdc.balanceOf(user), netAmount);
        // LP balance decreased
        assertEq(eusdc.balanceOf(lp1), 100_000e6 - netAmount);

        // Release recorded
        (address fillingLP, address recipient, uint256 amount, uint256 rNonce, bool released) =
            destBridge.releases(0);
        assertEq(fillingLP, lp1);
        assertEq(recipient, user);
        assertEq(amount, netAmount);
        assertEq(rNonce, 0);
        assertTrue(released);
    }

    function test_handle_to_swap_executor() public {
        uint256 netAmount = 498_500000;
        _deliverMessage(swapExecutor, netAmount, 0, lp1);
        assertEq(eusdc.balanceOf(swapExecutor), netAmount);
    }

    function test_handle_reverts_unregistered_lp() public {
        // lp2 is NOT registered on dest bridge
        address unregistered = makeAddr("unregistered");
        eusdc.mint(unregistered, 10_000e6);
        vm.prank(unregistered);
        eusdc.approve(address(destBridge), type(uint256).max);

        bytes memory payload = abi.encode(user, 997e6, uint256(0), unregistered);
        vm.prank(address(destMailbox));
        vm.expectRevert(OwnBridge.LPNotRegistered.selector);
        destBridge.handle(BASE_DOMAIN, _toBytes32(address(sourceBridge)), payload);
    }

    function test_handle_reverts_insufficient_lp_allowance() public {
        // LP1 has tokens but revokes allowance
        vm.prank(lp1);
        eusdc.approve(address(destBridge), 0);

        bytes memory payload = abi.encode(user, 997e6, uint256(0), lp1);
        vm.prank(address(destMailbox));
        vm.expectRevert(OwnBridge.InsufficientLPBalance.selector);
        destBridge.handle(BASE_DOMAIN, _toBytes32(address(sourceBridge)), payload);
    }

    function test_handle_reverts_insufficient_lp_balance() public {
        // Try to release more than LP has
        bytes memory payload = abi.encode(user, 200_000e6, uint256(0), lp1);
        vm.prank(address(destMailbox));
        vm.expectRevert(OwnBridge.InsufficientLPBalance.selector);
        destBridge.handle(BASE_DOMAIN, _toBytes32(address(sourceBridge)), payload);
    }

    function test_handle_reverts_wrong_caller() public {
        bytes memory payload = abi.encode(user, 997e6, uint256(0), lp1);
        vm.prank(user);
        vm.expectRevert(OwnBridge.NotMailbox.selector);
        destBridge.handle(BASE_DOMAIN, _toBytes32(address(sourceBridge)), payload);
    }

    function test_handle_reverts_wrong_origin() public {
        bytes memory payload = abi.encode(user, 997e6, uint256(0), lp1);
        vm.prank(address(destMailbox));
        vm.expectRevert(OwnBridge.WrongOriginDomain.selector);
        destBridge.handle(999, _toBytes32(address(sourceBridge)), payload);
    }

    function test_handle_reverts_wrong_sender() public {
        bytes memory payload = abi.encode(user, 997e6, uint256(0), lp1);
        vm.prank(address(destMailbox));
        vm.expectRevert(OwnBridge.NotRemoteContract.selector);
        destBridge.handle(BASE_DOMAIN, _toBytes32(address(0xdead)), payload);
    }

    // ============ Multi-LP Tests ============

    function test_handle_uses_selected_lp_not_first() public {
        // Register LP2 on dest chain
        eusdc.mint(lp2, 50_000e6);
        vm.prank(lp2);
        eusdc.approve(address(destBridge), type(uint256).max);
        vm.prank(operator);
        destBridge.addLP(lp2);

        // Select LP2 specifically (even though LP1 is first in the array)
        uint256 netAmount = 10_000e6;
        _deliverMessage(user, netAmount, 0, lp2);

        // LP2 filled, not LP1
        assertEq(eusdc.balanceOf(user), netAmount);
        assertEq(eusdc.balanceOf(lp2), 50_000e6 - netAmount);
        assertEq(eusdc.balanceOf(lp1), 100_000e6); // untouched

        (address fillingLP, , , , ) = destBridge.releases(0);
        assertEq(fillingLP, lp2);
    }

    function test_handle_multiple_lps_proportional_fills() public {
        // Register LP2 and LP3 on dest chain
        eusdc.mint(lp2, 50_000e6);
        eusdc.mint(lp3, 25_000e6);
        vm.prank(lp2);
        eusdc.approve(address(destBridge), type(uint256).max);
        vm.prank(lp3);
        eusdc.approve(address(destBridge), type(uint256).max);
        vm.startPrank(operator);
        destBridge.addLP(lp2);
        destBridge.addLP(lp3);
        vm.stopPrank();

        // Service selects LPs proportionally:
        // LP1: 100k (57%), LP2: 50k (29%), LP3: 25k (14%)
        // 7 fills: LP1 gets 4, LP2 gets 2, LP3 gets 1

        uint256 fillAmount = 1000e6;
        _deliverMessage(user, fillAmount, 0, lp1);
        _deliverMessage(user, fillAmount, 1, lp1);
        _deliverMessage(user, fillAmount, 2, lp2);
        _deliverMessage(user, fillAmount, 3, lp1);
        _deliverMessage(user, fillAmount, 4, lp3);
        _deliverMessage(user, fillAmount, 5, lp2);
        _deliverMessage(user, fillAmount, 6, lp1);

        assertEq(eusdc.balanceOf(lp1), 100_000e6 - 4000e6); // 4 fills
        assertEq(eusdc.balanceOf(lp2), 50_000e6 - 2000e6);  // 2 fills
        assertEq(eusdc.balanceOf(lp3), 25_000e6 - 1000e6);  // 1 fill
        assertEq(destBridge.releaseCount(), 7);
    }

    // ============ Settlement Tests ============

    function test_markSettled_distributes_correctly() public {
        uint256 amount = 1000e6;

        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user, lp1);
        vm.stopPrank();

        vm.prank(operator);
        sourceBridge.markSettled(depositNonce, lp1);

        // Protocol fee: 1000 * 0.2% = 2.00 USDC
        // LP payment: 1000 - 2.00 = 998.00 USDC
        assertEq(usdc.balanceOf(protocolLP), 2e6);
        assertEq(usdc.balanceOf(lp1), 998e6);
        assertEq(usdc.balanceOf(address(sourceBridge)), 0);

        (, , , , , , bool settled, ) = sourceBridge.deposits(depositNonce);
        assertTrue(settled);
    }

    function test_markSettled_lp_profit_is_point_one_percent() public {
        uint256 amount = 1000e6;

        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user, lp1);
        vm.stopPrank();

        vm.prank(operator);
        sourceBridge.markSettled(depositNonce, lp1);

        uint256 lpReceived = usdc.balanceOf(lp1);   // 998e6
        uint256 lpGave = 997e6;                       // netAmount on dest
        uint256 lpProfit = lpReceived - lpGave;

        assertEq(lpProfit, 1e6); // $1.00 profit on $1000 bridge = 0.1%
    }

    function test_markSettled_reverts_not_operator() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user, lp1);
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert(OwnBridge.NotOperator.selector);
        sourceBridge.markSettled(depositNonce, lp1);
    }

    function test_markSettled_reverts_double_settle() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user, lp1);
        vm.stopPrank();

        vm.startPrank(operator);
        sourceBridge.markSettled(depositNonce, lp1);
        vm.expectRevert(OwnBridge.DepositAlreadySettled.selector);
        sourceBridge.markSettled(depositNonce, lp1);
        vm.stopPrank();
    }

    function test_markSettled_reverts_after_refund() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user, lp1);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(user);
        sourceBridge.refund(depositNonce);

        vm.prank(operator);
        vm.expectRevert(OwnBridge.DepositAlreadyRefunded.selector);
        sourceBridge.markSettled(depositNonce, lp1);
    }

    // ============ Refund Tests ============

    function test_refund_after_delay() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user, lp1);

        vm.warp(block.timestamp + 2 hours + 1);
        sourceBridge.refund(depositNonce);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user), 50_000e6); // full amount back
        assertEq(usdc.balanceOf(address(sourceBridge)), 0);

        (, , , , , , , bool refunded) = sourceBridge.deposits(depositNonce);
        assertTrue(refunded);
    }

    function test_refund_reverts_too_early() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user, lp1);

        vm.expectRevert(OwnBridge.RefundTooEarly.selector);
        sourceBridge.refund(depositNonce);
        vm.stopPrank();
    }

    function test_refund_at_exact_boundary() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user, lp1);

        // 1 second before 2 hours — should revert
        vm.warp(block.timestamp + 2 hours - 1);
        vm.expectRevert(OwnBridge.RefundTooEarly.selector);
        sourceBridge.refund(depositNonce);

        // Exactly at 2 hours — should succeed (>= REFUND_DELAY)
        vm.warp(block.timestamp + 1);
        sourceBridge.refund(depositNonce);
        vm.stopPrank();
    }

    function test_refund_reverts_wrong_user() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user, lp1);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(lp1);
        vm.expectRevert(OwnBridge.NotDepositor.selector);
        sourceBridge.refund(depositNonce);
    }

    function test_refund_reverts_after_settlement() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user, lp1);
        vm.stopPrank();

        vm.prank(operator);
        sourceBridge.markSettled(depositNonce, lp1);

        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(user);
        vm.expectRevert(OwnBridge.DepositAlreadySettled.selector);
        sourceBridge.refund(depositNonce);
    }

    function test_refund_reverts_double_refund() public {
        uint256 amount = 1000e6;
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user, lp1);

        vm.warp(block.timestamp + 2 hours + 1);
        sourceBridge.refund(depositNonce);

        vm.expectRevert(OwnBridge.DepositAlreadyRefunded.selector);
        sourceBridge.refund(depositNonce);
        vm.stopPrank();
    }

    // ============ LP Management Tests ============

    function test_addLP() public {
        vm.prank(operator);
        sourceBridge.addLP(lp1);

        assertTrue(sourceBridge.isLP(lp1));
        assertEq(sourceBridge.activeLPCount(), 1);
        assertEq(sourceBridge.activeLPs(0), lp1);
    }

    function test_addLP_reverts_duplicate() public {
        vm.startPrank(operator);
        sourceBridge.addLP(lp1);
        vm.expectRevert(OwnBridge.LPAlreadyActive.selector);
        sourceBridge.addLP(lp1);
        vm.stopPrank();
    }

    function test_removeLP() public {
        vm.startPrank(operator);
        sourceBridge.addLP(lp1);
        sourceBridge.addLP(lp2);
        assertEq(sourceBridge.activeLPCount(), 2);

        sourceBridge.removeLP(lp1);
        vm.stopPrank();

        assertFalse(sourceBridge.isLP(lp1));
        assertEq(sourceBridge.activeLPCount(), 1);
        assertEq(sourceBridge.activeLPs(0), lp2);
    }

    function test_removeLP_reverts_not_active() public {
        vm.prank(operator);
        vm.expectRevert(OwnBridge.LPNotActive.selector);
        sourceBridge.removeLP(lp1);
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
        uint256 depositNonce = sourceBridge.bridge(amount, user, lp1);
        vm.stopPrank();

        // Pause the bridge
        vm.prank(operator);
        sourceBridge.pause();

        // Refund should still work
        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(user);
        sourceBridge.refund(depositNonce);
        assertEq(usdc.balanceOf(user), 50_000e6);
    }

    function test_setProtocolLP() public {
        address newProtocolLP = makeAddr("newProtocolLP");
        vm.prank(operator);
        sourceBridge.setProtocolLP(newProtocolLP);
        assertEq(sourceBridge.protocolLP(), newProtocolLP);
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
        assertTrue(destBridge.canFill(lp1, 50_000e6));
        assertTrue(destBridge.canFill(lp1, 100_000e6));
        assertFalse(destBridge.canFill(lp1, 100_001e6));
        assertFalse(destBridge.canFill(lp2, 1e6)); // lp2 not registered
    }

    function test_totalCapacity() public view {
        assertEq(destBridge.totalCapacity(), 100_000e6); // only lp1
    }

    function test_totalCapacity_multi_lp() public {
        eusdc.mint(lp2, 50_000e6);
        vm.prank(lp2);
        eusdc.approve(address(destBridge), type(uint256).max);
        vm.prank(operator);
        destBridge.addLP(lp2);

        assertEq(destBridge.totalCapacity(), 150_000e6);
    }

    function test_getLPCapacities() public view {
        (address[] memory lps, uint256[] memory caps) = destBridge.getLPCapacities();
        assertEq(lps.length, 1);
        assertEq(lps[0], lp1);
        assertEq(caps[0], 100_000e6);
    }

    function test_getLPCapacities_respects_allowance_limit() public {
        // LP1 has 100k tokens but only approved 5k
        vm.prank(lp1);
        eusdc.approve(address(destBridge), 5_000e6);

        (address[] memory lps, uint256[] memory caps) = destBridge.getLPCapacities();
        assertEq(caps[0], 5_000e6); // min(5k allowance, 100k balance)
    }

    function test_getActiveLPs() public view {
        address[] memory lps = destBridge.getActiveLPs();
        assertEq(lps.length, 1);
        assertEq(lps[0], lp1);
    }

    // ============ End-to-End Flow Tests ============

    function test_full_bridge_flow_base_to_pulse() public {
        uint256 amount = 1000e6;

        // Step 1: User bridges on source with service-selected LP
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user, lp1);
        vm.stopPrank();

        // Step 2: Hyperlane delivers message to dest (LP1 selected)
        _deliverMessage(user, 997e6, depositNonce, lp1);
        assertEq(eusdc.balanceOf(user), 997e6);

        // Step 3: Operator settles on source
        vm.prank(operator);
        sourceBridge.markSettled(depositNonce, lp1);

        // Final state
        assertEq(usdc.balanceOf(lp1), 998e6);        // LP payment
        assertEq(usdc.balanceOf(protocolLP), 2e6);    // Protocol fee
        assertEq(usdc.balanceOf(address(sourceBridge)), 0);
        assertEq(eusdc.balanceOf(lp1), 100_000e6 - 997e6);
    }

    function test_full_onramp_flow_with_swap_executor() public {
        uint256 amount = 500e6;

        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, swapExecutor, lp1);
        vm.stopPrank();

        _deliverMessage(swapExecutor, 498_500000, depositNonce, lp1);
        assertEq(eusdc.balanceOf(swapExecutor), 498_500000);

        vm.prank(operator);
        sourceBridge.markSettled(depositNonce, lp1);

        assertEq(usdc.balanceOf(lp1), 499e6);
        assertEq(usdc.balanceOf(protocolLP), 1e6);
    }

    function test_multiple_bridges_different_lps() public {
        // Register LP2
        eusdc.mint(lp2, 50_000e6);
        vm.prank(lp2);
        eusdc.approve(address(destBridge), type(uint256).max);
        vm.prank(operator);
        destBridge.addLP(lp2);

        // Register LP1 on source for settlement
        vm.prank(operator);
        sourceBridge.addLP(lp1);
        vm.prank(operator);
        sourceBridge.addLP(lp2);

        vm.startPrank(user);
        usdc.approve(address(sourceBridge), type(uint256).max);

        // Bridge 1: service selects LP1
        uint256 n0 = sourceBridge.bridge(1000e6, user, lp1);
        // Bridge 2: service selects LP2
        uint256 n1 = sourceBridge.bridge(2000e6, user, lp2);
        // Bridge 3: service selects LP1 again
        uint256 n2 = sourceBridge.bridge(500e6, user, lp1);
        vm.stopPrank();

        // Deliver each with the correct LP
        _deliverMessage(user, 997e6, n0, lp1);
        _deliverMessage(user, 1994e6, n1, lp2);
        _deliverMessage(user, 498_500000, n2, lp1);

        // LP1 gave 997 + 498.5 = 1495.5 eUSDC
        assertEq(eusdc.balanceOf(lp1), 100_000e6 - 997e6 - 498_500000);
        // LP2 gave 1994 eUSDC
        assertEq(eusdc.balanceOf(lp2), 50_000e6 - 1994e6);

        // Settle all
        vm.startPrank(operator);
        sourceBridge.markSettled(n0, lp1);
        sourceBridge.markSettled(n1, lp2);
        sourceBridge.markSettled(n2, lp1);
        vm.stopPrank();

        // LP1 received: 998 + 499 = 1497 USDC
        assertEq(usdc.balanceOf(lp1), 998e6 + 499e6);
        // LP2 received: 1996 USDC
        assertEq(usdc.balanceOf(lp2), 1996e6);
        // Protocol: 2 + 4 + 1 = 7 USDC
        assertEq(usdc.balanceOf(protocolLP), 2e6 + 4e6 + 1e6);
        // Bridge empty
        assertEq(usdc.balanceOf(address(sourceBridge)), 0);
    }

    // ============ Edge Case Tests ============

    function test_bridge_minimum_amount() public {
        uint256 amount = 1e6;
        (uint256 net, uint256 fee) = sourceBridge.quote(amount);
        assertEq(fee, 3000);   // 0.003 USDC
        assertEq(net, 997000);
    }

    function test_bridge_tiny_amount() public {
        uint256 amount = 10000; // 0.01 USDC
        (uint256 net, uint256 fee) = sourceBridge.quote(amount);
        assertEq(fee, 30);
        assertEq(net, 9970);
    }

    function test_nonce_increments() public {
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), type(uint256).max);

        uint256 n0 = sourceBridge.bridge(100e6, user, lp1);
        uint256 n1 = sourceBridge.bridge(100e6, user, lp1);
        uint256 n2 = sourceBridge.bridge(100e6, user, lp1);
        vm.stopPrank();

        assertEq(n0, 0);
        assertEq(n1, 1);
        assertEq(n2, 2);
        assertEq(sourceBridge.nonce(), 3);
    }

    // ============ Fuzz Tests ============

    function testFuzz_bridge_fee_invariant(uint256 amount) public view {
        amount = bound(amount, 1, 1e18);

        (uint256 net, uint256 fee) = sourceBridge.quote(amount);
        assertEq(net + fee, amount);
        assertLe(fee, (amount * 30) / 10000);
        assertGe(net, amount - (amount * 30) / 10000);
    }

    function testFuzz_settlement_distribution(uint256 amount) public {
        amount = bound(amount, 100, 1e15);

        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(sourceBridge), amount);
        uint256 depositNonce = sourceBridge.bridge(amount, user, lp1);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(sourceBridge)), amount);

        vm.prank(operator);
        sourceBridge.markSettled(depositNonce, lp1);

        // No dust left
        assertEq(usdc.balanceOf(address(sourceBridge)), 0);

        uint256 protocolFee = (amount * 20) / 10000;
        uint256 lpPayment = amount - protocolFee;
        assertEq(usdc.balanceOf(protocolLP), protocolFee);
        assertEq(usdc.balanceOf(lp1), lpPayment);
    }
}
