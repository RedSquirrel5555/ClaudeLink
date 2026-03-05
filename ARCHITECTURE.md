# OWN Protocol -- Architecture & Design

## Product Definition

**OWN Protocol: Fiat on/off ramp and bridge for PulseChain**

```
On-ramp (Pulse):  Fiat -> Peer (zkP2P) -> USDC on Base -> OWN (Hyperlane) -> eUSDC on PulseChain -> SquirrelSwap -> Any Token
On-ramp (Base):   Fiat -> Peer (zkP2P) -> USDC on Base (direct, no OWN, no swap)
Off-ramp (Pulse): Any Token -> SquirrelSwap -> eUSDC on PulseChain -> OWN (Hyperlane) -> USDC on Base -> Peer (zkP2P) -> Fiat
Off-ramp (Base):  USDC on Base -> Peer (zkP2P) -> Fiat (direct, no OWN, no swap)
Bridge:           USDC on Base <-> eUSDC on PulseChain (direct, no Peer, no swap)
```

Five modes, one bridge contract:
- **On-ramp (PulseChain):** User has fiat -> User has PulseChain tokens (full pipeline: Peer + OWN + SquirrelSwap)
- **On-ramp (Base):** User has fiat -> User has USDC on Base (Peer only, no OWN fee)
- **Off-ramp (PulseChain):** User has PulseChain tokens -> User has fiat (full pipeline: SquirrelSwap + OWN + Peer)
- **Off-ramp (Base):** User has USDC on Base -> User has fiat (Peer only, no OWN fee)
- **Bridge:** User moves USDC/eUSDC between Base and PulseChain (OWN only, fastest and cheapest)

On-ramp and off-ramp to PulseChain are the primary product. Direct Base on/off-ramp uses Peer only -- no OWN contracts, no OWN fee, useful for LPs and users who already have or want USDC on Base. Bridge is the OwnBridge contract without Peer or SquirrelSwap -- generates fees with less complexity, lays the foundation for adding more chains.

### Three Products, One Pipeline

```
+------------+     +------------+     +----------------+
|   Peer     |     |    OWN     |     |  SquirrelSwap  |
|  (zkP2P)   |     |  (bridge)  |     |  (aggregator)  |
|            |     |            |     |                |
| Fiat <->   | --> | Base <->   | --> | eUSDC <->      |
| USDC       |     | Pulse      |     | Any Token      |
|            |     |            |     |                |
| External   |     | YOU BUILD  |     | YOU OWN        |
+------------+     +------------+     +----------------+
```

You own two out of three pieces. Peer is the only external dependency with a public SDK.

### Why PulseChain-First

| | PulseChain-first | Chain agnostic |
|---|---|---|
| Competition | Minimal | Brutal (Across, Stargate, deBridge) |
| Fee power | High (limited alternatives) | Low (race to bottom) |
| Liquidity needs | Manageable (one corridor) | Massive (every pair) |
| Moat | Access + fiat integration | None (mechanism is commodity) |

Cross-chain solving is table stakes. OWN's edge: **PulseChain is underserved**. Most intent protocols don't touch it. Nobody else offers fiat -> any PulseChain token in one flow. That's the moat.

The multi-chain architecture is preserved -- contracts work on any EVM chain. But go-to-market focuses on the PulseChain corridor.

---

## System Architecture

### Three Layers

```
+---------------------------------------------------+
|  Layer 1: Frontend                                 |
|  "Buy PLS with your bank account" -- one button    |
+---------------------------------------------------+
|  Layer 2: Orchestrator Service                     |
|  Coordinates Peer <-> OWN bridge <-> SquirrelSwap  |
|  LP management, gas accounting, fee compounding    |
+---------------------------------------------------+
|  Layer 3: On-Chain                                 |
|  Base: OwnBridge.sol + Hyperlane Mailbox           |
|  PulseChain: OwnBridge.sol + Hyperlane Mailbox     |
|  Peer: existing contracts on Base (external)       |
+---------------------------------------------------+
```

### Why Hyperlane, Not HTLCs

The original design used HTLC vaults (SwapVault + VaultFactory, 7-step settlement pipeline, secrets, timelocks, user must claim on dest chain). Hyperlane replaces all of that with cross-chain message passing:

```
HTLC (original):                    Hyperlane (current):
  6 on-chain txs                      2 on-chain txs
  User must claim on dest chain       Fully automatic
  7-step settlement pipeline          Lock -> message -> release
  Secret management                   No secrets
  Timelocks (1hr + 2hr)               Refund timeout only
  SwapVault + VaultFactory            One OwnBridge contract per chain
  Trust: trustless (cryptographic)    Trust: Hyperlane validator set
```

Key insight: **OWN doesn't use Hyperlane to move tokens.** It uses Hyperlane's mailbox to send a message that triggers release of eUSDC that LPs already hold. No hypUSDC minted. No new wrapped tokens. LP holds real eUSDC (Ethereum-bridged USDC) with existing liquidity on PulseChain.

Hyperlane is live on PulseChain mainnet.

### Fallback

If Hyperlane becomes unreliable, the HTLC design is documented and can be rebuilt in ~2 weeks. The LP model is identical in both architectures.

---

## Smart Contracts

One contract per chain. Dramatically simpler than the HTLC design.

### OwnBridge.sol (deployed on Base and PulseChain)

Bidirectional bridge contract with LP pool. Handles locking, Hyperlane dispatch, message receipt, pool-based fills, and refunds.

**LP pool model:** LPs deposit into a shared pool. Fills draw from the pool. Settlements feed LP payments back — increasing share price for all depositors. No LP selection needed. Perfectly proportional. ERC-4626-style share accounting.

```solidity
contract OwnBridge is IMessageRecipient {
    IMailbox public immutable mailbox;
    IERC20 public immutable token;     // USDC on Base, eUSDC on PulseChain
    uint32 public immutable remoteDomain;

    address public operator;
    address public protocolFeeRecipient;
    bytes32 public remoteContract;

    // LP Pool (share-based accounting)
    uint256 public poolAssets;           // total tokens in pool
    uint256 public totalShares;          // total shares outstanding
    mapping(address => uint256) public lpShares;

    uint256 public nonce;
    mapping(uint256 => Deposit) public deposits;

    struct Deposit {
        address user;
        uint256 amount;
        uint256 netAmount;
        address destRecipient;
        uint64 timestamp;
        bool settled;
        bool refunded;
    }

    // --- LP deposits into pool, receives proportional shares ---
    function depositLP(uint256 amount) external {
        uint256 shares = totalShares == 0 ? amount : amount * totalShares / poolAssets;
        token.transferFrom(msg.sender, address(this), amount);
        lpShares[msg.sender] += shares;
        totalShares += shares;
        poolAssets += amount;
    }

    // --- LP withdraws shares at current price (principal + earned fees) ---
    function withdrawLP(uint256 shares) external {
        uint256 amount = shares * poolAssets / totalShares;
        lpShares[msg.sender] -= shares;
        totalShares -= shares;
        poolAssets -= amount;
        token.transfer(msg.sender, amount);
    }

    // --- User locks tokens for bridging ---
    function bridge(uint256 amount, address destRecipient) external payable {
        uint256 totalFee = amount * 30 / 10000;  // 0.3%
        uint256 netAmount = amount - totalFee;
        token.transferFrom(msg.sender, address(this), amount);
        deposits[nonce] = Deposit(msg.sender, amount, netAmount, destRecipient,
                                   uint64(block.timestamp), false, false);
        mailbox.dispatch{value: msg.value}(remoteDomain, remoteContract,
            abi.encode(destRecipient, netAmount, nonce));
        nonce++;
    }

    // --- Receive message, release from pool ---
    function handle(uint32 _origin, bytes32 _sender, bytes calldata _payload) external payable {
        require(msg.sender == address(mailbox));
        require(_origin == remoteDomain && _sender == remoteContract);
        (address recipient, uint256 amount, uint256 remoteNonce) =
            abi.decode(_payload, (address, uint256, uint256));
        require(poolAssets >= amount);
        poolAssets -= amount;
        token.transfer(recipient, amount);
    }

    // --- Settlement: LP payment → pool (share price rises), protocol fee → external ---
    function markSettled(uint256 _nonce) external onlyOperator {
        Deposit storage d = deposits[_nonce];
        require(!d.settled && !d.refunded);
        d.settled = true;
        uint256 protocolFee = d.amount * 20 / 10000;   // 0.2%
        uint256 lpPayment = d.amount - protocolFee;
        poolAssets += lpPayment;                         // share price increases
        token.transfer(protocolFeeRecipient, protocolFee);
    }

    // --- Refund if settlement fails ---
    function refund(uint256 _nonce) external {
        Deposit storage d = deposits[_nonce];
        require(d.user == msg.sender && !d.settled && !d.refunded);
        require(block.timestamp >= d.timestamp + 2 hours);
        d.refunded = true;
        token.transfer(msg.sender, d.amount);
    }

    // --- Views ---
    function sharePrice() external view returns (uint256) { ... }   // tokens per share
    function lpValue(address lp) external view returns (uint256) { ... }
    function canFill(uint256 amount) external view returns (bool) { ... }
}
```

**Note:** The pseudocode above is simplified. The full implementation is in `own-contracts/src/OwnBridge.sol` with SafeERC20, custom errors, pause/unpause, two-step operator transfer, release tracking, share inflation protection, and comprehensive NatSpec. 64 tests passing including 4 fuzz suites.

### What This Eliminates

```
Removed (HTLC era):
  - SwapVault.sol
  - VaultFactory.sol
  - HTLC secrets / secret manager
  - 7-step settlement pipeline
  - User claiming on dest chain
  - Denomination system (partial fills via fixed sizes)
  - Matcher engine
  - Timelock coordination (1hr + 2hr)

Added (Hyperlane + Pool era):
  + OwnBridge.sol on Base (lock USDC + dispatch message)
  + OwnBridge.sol on PulseChain (receive message + release from LP pool)
  + LP pool with share-based accounting (ERC-4626 style)
  + depositLP() / withdrawLP() — LPs deposit into pool, withdraw at share price
  + bridge(amount, destRecipient) — simple, no LP selection needed
  + handle() releases from pool — no LP validation, no race conditions
  + markSettled() feeds LP payment back to pool (share price rises automatically)
  + 3 on-chain txs per bridge: bridge() + handle() + markSettled()
  + Fully automatic settlement, no user action on dest chain
  + Refund timeout (2hr escape hatch if settlement fails)
  + Perfectly proportional LP earnings by design — no selection algorithm needed

Changed from original design:
  × LP allowance model → LP pool model (funds custodied in contract)
  × Individual LP selection → pool fills everything proportionally
  = Protocol fee still sent externally (0.2%)
  = LP earnings still 0.1% spread (now via share price appreciation)
```

### Deployments

```
Base:       OwnBridge.sol (connects to Hyperlane Mailbox on Base)
PulseChain: OwnBridge.sol (connects to Hyperlane Mailbox on PulseChain)
```

Two contract deployments total.

---

## The Pipeline

### On-Ramp: Fiat -> PulseChain Token

```
1.  User clicks "Buy $500 of PLS"
2.  Peer extension opens -> user sends fiat via Venmo/Zelle
3.  Peer settles -> USDC arrives on Base (~2-5 mins)
4.  OwnBridge.bridge(500 USDC, serviceSwapExecutor) on Base
    -> 500 USDC locked in contract, Hyperlane message dispatched
    -> destRecipient = service swap executor (NOT user) when token != eUSDC
5.  ~30-60 seconds later, OwnBridge.handle() fires on PulseChain
    -> 498.50 eUSDC released from LP pool to service swap executor
6.  Service swaps 498.50 eUSDC -> PLS via SquirrelSwap on PulseChain
    -> Service pays PulseChain gas (~fractions of a cent)
    -> Sends PLS output to user's wallet
7.  Service confirms release, calls markSettled(nonce, lpAddress) on Base
    -> LP receives 499.00 USDC (locked amount minus 0.2% protocol fee)
    -> Protocol LP receives 1.00 USDC (0.2% fee, compounds)
    -> LP's implicit profit: 499.00 received - 498.50 given = 0.50 (0.1%)
8.  User has PLS in wallet

Total user actions: connect wallet, click "Buy PLS", send fiat payment
Everything from step 3 onward is automatic. User never needs PLS for gas.
```

When the user wants eUSDC directly (no swap needed), `destRecipient` is the user's own address and step 6 is skipped.

### On-Ramp: Fiat -> USDC on Base (Direct)

For users who just want USDC on Base. No bridge, no swap -- Peer + small platform fee.

```
1.  User selects "Buy" and picks "To Base"
2.  Peer extension opens -> user sends fiat via Venmo/Zelle
3.  Peer settles -> USDC arrives in service wallet on Base (~2-5 mins)
4.  Service deducts 0.1% platform fee, sends remainder to user
5.  User has USDC on Base

Total user actions: click "Buy", choose amount, send fiat payment
No OwnBridge contract. 0.1% platform fee (service-level, not on-chain).
~2-5 min (Peer settlement only).
```

Mirror of the "From Base" off-ramp. Useful for users who want USDC on Base for DeFi, or as a stepping stone before using the bridge separately. Also useful for LPs who want to top up their Base-side USDC for fills.

### Off-Ramp: PulseChain Token -> Fiat

```
1.  User clicks "Cash out $500 of PLS"
2.  User approves PLS to service swap executor on PulseChain
3.  Service swaps PLS -> eUSDC via SquirrelSwap on PulseChain
    -> Service pays PulseChain gas (~fractions of a cent)
4.  Service calls OwnBridge.bridge(eUSDC amount, userBaseAddress) on PulseChain
    -> eUSDC locked in contract, Hyperlane message dispatched
5.  OwnBridge.handle() fires on Base
    -> USDC released from LP pool to user on Base
6.  Service calls markSettled(nonce) on PulseChain
    -> LP receives eUSDC, Protocol LP receives 0.2% fee
    -> LP rebalanced: gave USDC on Base, received eUSDC on PulseChain
7.  Peer offramp: user sells USDC for fiat
8.  User has cash

Total user actions: connect wallet, approve token, click "Cash Out", complete Peer
Service handles swap + bridge + settlement. User never needs PLS for gas.
```

When the user is cashing out eUSDC directly (no swap needed), steps 2-3 are skipped -- eUSDC goes straight to `bridge()`.

### Off-Ramp: USDC on Base -> Fiat (Direct)

For users or LPs who already have USDC on Base. No bridge, no swap -- Peer + small platform fee.

```
1.  User selects "Cash Out" and picks "From Base"
2.  User sends USDC to service wallet on Base
3.  Service deducts 0.1% platform fee, forwards remainder to Peer
4.  Peer offramp: sells USDC for fiat via Venmo/Zelle/etc.
5.  User has cash

Total user actions: click "Cash Out", choose amount, complete Peer
No OwnBridge contract. 0.1% platform fee (service-level, not on-chain).
~2-5 min (Peer settlement only).
```

This matters for LPs. An LP filling on-ramps accumulates USDC on Base. When they want to withdraw profits or rebalance to fiat, they shouldn't have to bridge back to PulseChain first. They go straight to Peer from Base.

Also useful for any user who received USDC on Base via the bridge (e.g. used off-ramp from PulseChain, but didn't finish the Peer step, or got USDC from elsewhere).

### Bridge: Base <-> PulseChain (Direct)

Same OwnBridge contract, no Peer, no SquirrelSwap. Just the bridge step. `destRecipient` is the user's own address (no swap executor needed).

```
Base -> PulseChain:
1.  User clicks "Bridge $1000 to PulseChain"
2.  OwnBridge.bridge(1000 USDC, userPulseAddress) on Base
    -> 1000 USDC locked in contract, Hyperlane message dispatched
3.  ~30-60 seconds later, OwnBridge.handle() fires on PulseChain
    -> 997.00 eUSDC released from LP pool directly to user
4.  Service calls markSettled(nonce) on Base
    -> LP receives 998.00 USDC, Protocol LP receives 2.00 USDC
    -> LP profit: 998.00 - 997.00 = 1.00 (0.1%)
5.  User has eUSDC on PulseChain

PulseChain -> Base:
    Same flow in reverse. User locks eUSDC, receives USDC on Base.

Total user actions: connect wallet, approve, click "Bridge"
2 on-chain txs (bridge + handle), 1 service tx (markSettled)
~1 minute total. No fiat, no swap.
```

### Why Offer Bridge Separately

- **Revenue with less complexity.** Same 0.3% OWN fee, no Peer dependency, no swap routing.
- **Serves existing crypto users.** Not everyone needs fiat. Some just want to move between Base and PulseChain.
- **Builds volume.** More bridge volume = more LP fees = more LP retention = more capacity for on-ramp/off-ramp.
- **Foundation for multi-chain.** Adding Arbitrum, BSC, or other chains starts with bridge corridors. On/off-ramp follows.
- **Proves the infrastructure.** Bridge is the simplest test of the OwnBridge + Hyperlane stack.

### LP Rebalancing (Automatic)

```
On-ramp:   LP gives 498.50 eUSDC on Pulse, receives 499.00 USDC on Base
Off-ramp:  LP gives 498.50 USDC on Base,  receives 499.00 eUSDC on Pulse
           Each direction naturally rebalances the other.
           LP profits 0.50 (0.1%) on every fill in either direction.
```

### Critical Design Decision

**Don't pre-match before Peer settles** (on-ramp only). If you dispatch a Hyperlane message before the user's fiat settles, LP capital gets consumed for a payment that might fail.

```
Wrong:  Dispatch message -> Start Peer -> Hope fiat settles
Right:  Start Peer -> Wait for settlement -> Then bridge
```

### Swap Execution: Service Pays Gas

Users on-ramping from fiat to a PulseChain token (e.g. PLS) have no PLS for gas to execute the swap. The service handles this.

```
The problem:
  User buys PLS with $500 fiat.
  Bridge delivers 498.50 eUSDC to PulseChain.
  User needs to swap eUSDC -> PLS... but has no PLS to pay gas.

The solution:
  Service swap executor receives eUSDC on behalf of user.
  Service swaps via SquirrelSwap, pays gas from its own PLS balance.
  Service sends final token (PLS) to user's wallet.
  PulseChain gas is fractions of a cent -- negligible operational cost.
```

**How destRecipient works:**

```
On-ramp (token != eUSDC):
  bridge(amount, serviceSwapExecutor)  -> eUSDC goes to service
  service swaps eUSDC -> token         -> service pays gas
  service sends token to user          -> user gets final token

On-ramp (token == eUSDC) or Bridge:
  bridge(amount, userAddress)          -> eUSDC goes directly to user
  no swap needed                       -> no gas issue

Off-ramp:
  user approves token to service       -> one-time approval
  service swaps token -> eUSDC         -> service pays gas
  service calls bridge(eUSDC, userBaseAddress)  -> normal bridge flow
```

**Gas costs (PulseChain):**

```
Swap execution:    ~$0.001-$0.01
Token transfer:    ~$0.0005
Total per ramp:    ~$0.002-$0.015

At 0.3% fee on a $500 transaction = $1.50 revenue.
Gas cost = $0.01. Margin: ~99%.
Even at $50 transactions (fee = $0.15), gas is negligible.
```

**Trust implication:** The user trusts the service to receive eUSDC and forward the swapped token. This is the same trust model as the rest of the pipeline -- the service already calls `markSettled()` to pay LPs. If the service disappears mid-swap, the eUSDC sits in the swap executor wallet (recoverable by operator, not lost on-chain). The bridge refund timeout still protects the source-chain deposit.

---

## LP Pool Model

The pool replaces the original allowance-based LP selection. Instead of individual LPs being selected to fill specific bridges, all LPs deposit into a shared pool. Fills draw from the pool. Settlement payments flow back to the pool, increasing share price for all depositors.

### Why Pool Over Allowances

The allowance model ("LP funds stay in wallet") created real engineering problems:

```
Allowance problems solved by pool:
  ❌ LP selection fairness → pool fills proportionally by design
  ❌ Race conditions (LP revokes/spends mid-fill) → funds committed in contract
  ❌ Stale allowance state → pool balance is authoritative
  ❌ Front-running by LPs → not possible with deposited funds
  ❌ LP composability illusion → most LPs weren't using funds elsewhere anyway
```

### How It Works

```
Pool: $150,000 total
  LP A deposited: $100,000 → 100,000 shares (66.7%)
  LP B deposited: $50,000  → 50,000 shares  (33.3%)

$1,000 bridge fills from pool:
  Pool reduces by $1,000 → $149,000
  Shares unchanged

$998 LP payment arrives via markSettled():
  Pool increases by $998 → $149,998
  Shares unchanged → share price rises

LP A's value: 100,000 * 149,998 / 150,000 = $99,998.67
LP B's value: 50,000 * 149,998 / 150,000 = $49,999.33

Net effect per LP (after fill + settlement cycle):
  LP A: earned $0.667 (66.7% of $1 pool profit)
  LP B: earned $0.333 (33.3% of $1 pool profit)
  Perfectly proportional. No selection algorithm needed.
```

### Late Joiners Don't Get Past Earnings

Share price reflects accumulated earnings. LP C joining after fees have been earned pays the current share price — they get fewer shares per dollar, so they don't dilute existing LPs' earned fees.

### Protocol as LP

The protocol can be a depositor in its own pool. Protocol's shares earn the same proportional yield as any other LP. No special priority logic needed — the pool handles it.

---

## Peer (formerly zkP2P) Integration

### On-Ramp: Peer Extension SDK

```typescript
import { peerExtensionSdk } from '@zkp2p/sdk';

peerExtensionSdk.onramp({
  referrer: 'OWN Protocol',
  referrerLogo: 'https://own.xyz/logo.svg',
  callbackUrl: 'https://own.xyz/onramp/complete',
  amountUsdc: '500000000',           // exact USDC output (6 decimals)
  recipientAddress: USER_BASE_ADDRESS, // user's address on Base
});
```

- **Requires Chrome extension** -- desktop only, mobile users locked out
- Supports: Venmo, PayPal, Revolut, CashApp, Wise, Zelle, Monzo, Chime, Mercado Pago
- Settlement: 2-5 minutes after fiat payment
- `onProofComplete(callback)` -- subscribe to settlement events

### Off-Ramp: OfframpClient SDK

```typescript
import { OfframpClient } from '@zkp2p/sdk';

const client = new OfframpClient({ walletClient, chainId: base.id });
await client.createDeposit({
  token: USDC_ADDRESS,
  amount: 10000000000n,
  processorNames: ['venmo', 'revolut'],
});
```

Off-ramp is partially manual for V1. User gets USDC on Base, then uses Peer directly to sell for fiat. Full automation requires OWN/LPs to act as Peer LPs (compliance implications).

### Practical Concerns

- **Extension requirement** is a UX hurdle -- no mobile support
- **PulseChain not in Peer's supported chains** -- confirms OWN bridge is the missing piece
- **Off-ramp compliance** -- accepting fiat has regulatory implications
- **Timing** -- fiat (2-5 mins) + bridge (~1 min) + swap (~seconds) = total ~3-7 mins

---

## LP Model

### How It Works

LPs deposit tokens into the OwnBridge pool on each chain. Fills draw from the pool. Settlement payments flow back, increasing share price for all depositors.

```
1. LP deposits eUSDC into OwnBridge pool on PulseChain
2. LP deposits USDC into OwnBridge pool on Base
3. User bridges $500 Base -> PulseChain
4. handle() releases 498.50 eUSDC from pool on PulseChain -> user
5. markSettled() adds 499.00 USDC to pool on Base (share price rises)
6. All pool depositors earn proportionally
7. LP's share of pool profit: $0.50 * (their share %)
```

LP does nothing after initial deposit. Earnings are automatic via share price appreciation. Withdraw anytime at current share price (principal + accumulated fees).

For the PulseChain corridor, pools need:
- **eUSDC pool on PulseChain** (for on-ramp fills)
- **USDC pool on Base** (for off-ramp fills)

Bidirectional flow naturally rebalances pools. On-ramp depletes PulseChain pool but replenishes Base pool via settlement. Off-ramp does the reverse.

### LP Pitch

- Deposit and earn — standard vault model every DeFi user knows
- 0.1% fee on every bridge, shared proportionally, no impermanent loss
- Withdraw anytime at current share price
- No active management — fully automatic via share price appreciation
- Natural rebalancing from bidirectional flow
- Captive flow — every fiat on-ramp user generates yield for the pool

### What Attracts Early LPs

It's not the yield. Early volume is tiny.

1. **Personal network.** PulseChain community. People who believe in what you're building. "Help me build the first real fiat on-ramp for PulseChain."

2. **They need the service themselves.** Someone who regularly moves money between fiat and PulseChain. Providing liquidity makes the thing they need actually work.

3. **Protocol-owned LP signals commitment.** You compounding 0.15% into protocol LP tells LPs you're reinvesting, not extracting.

### What Won't Work Early

- Advertising APR numbers (no volume to back them)
- Competing on yield with established DeFi
- Token incentives (you don't have a token, and shouldn't)

### Bootstrapping Sequence

```
Phase 0: You are the LP ($200-500)
  - Prove the pipeline works end to end
  - Record demo videos
  - Use it yourself

Phase 1: Personal network (2-3 LPs, $1-5k each)
  - PulseChain community members
  - Pitch: "be part of building PulseChain infrastructure"

Phase 2: Organic growth
  - Every happy on-ramp user is a potential LP
  - "You just on-ramped $500 eUSDC. Want to earn fees on it?"
  - LP dashboard showing real earnings from real volume

Phase 3: Protocol LP compounds, reduces dependency
  - Each transaction grows protocol's own LP position
  - Eventually self-sufficient for small transactions
  - External LPs handle overflow
```

### Volume Projections (LP Returns)

```
At $1,000/day volume:   LP earns $1/day on $5k = 7.3% APR
At $5,000/day volume:   LP earns $5/day on $5k = 36.5% APR
At $10,000/day volume:  LP earns $10/day on $5k = 73% APR
```

### Protocol-Owned LP Growth

```
Month 1:   $10k volume  -> $15 protocol LP
Month 6:   $200k cumul  -> $300 protocol LP (can self-fill $300 txs)
Year 1:    $1M cumul    -> $1,500 protocol LP
Year 2:    $5M cumul    -> $7,500 protocol LP (self-sufficient for most retail)
```

Slow burn. Long-term moat, not launch strategy.

---

## Fee Structure

### OWN Fee (On-Chain, All Modes)

```
User bridges $500 (applies to all three modes):
  bridge() deducts 0.3% total fee    -> netAmount = 498.50 (sent in Hyperlane message)
  handle() releases 498.50 to user   -> pool gives 498.50
  markSettled() distributes locked funds:
    -> LP pool receives:    499.00 (amount - 0.2% protocol fee, share price rises)
    -> Protocol gets:         1.00 (0.2% protocol fee, sent externally)

LP fee is implicit:
  LP gave 498.50 on dest chain, received 499.00 on source chain
  Profit = 0.50 = 0.1% of original amount
  No explicit LP fee calculation or routing needed
```

### Peer Spread (Off-Chain, On-Ramp/Off-Ramp Only)

Peer (zkP2P) charges **no protocol fee**. The cost is entirely the spread set by Peer's P2P liquidity providers (makers). OWN does not control this rate.

```
How Peer pricing works:
  Makers deposit USDC on Base and set their exchange rate.
  Takers (our users) pay the maker's spread as the cost of conversion.
  No platform fee from Peer itself.

Typical maker spreads (real-world data):
  Competitive orderbook:   0.3-0.6%
  Normal conditions:       0.5-1.0%    <- most common range
  Low liquidity / large:   1.0-2.0%

By payment rail:
  Venmo / Cash App:  ~0.5-0.8%  (free rail, low spread)
  Wise:              ~0.5-1.0%  (+ ~0.3-0.6% FX if currency conversion)
  Revolut:           ~0.5-0.8%  (free domestic)
  Zelle:             ~0.5-0.8%  (free rail)
  PayPal:            ~0.8-1.2%  (higher spread due to chargeback risk)

Base gas (negligible):
  Signal intent:     ~$0.002-$0.01
  Settlement:        ~$0.002-$0.01
  Total gas/ramp:    ~$0.01-$0.05  (irrelevant vs spread)
```

**Realistic example:** $2,000 via Venmo -> Peer -> ~$1,986 USDC on Base (0.7% spread, $0.03 gas). Effective cost: **~0.7%**.

For comparison: Coinbase/MoonPay charge 3-5% on typical fiat ramps. OWN's full pipeline (Peer + bridge + swap) at ~1.8% total is still 2-3x cheaper, and OWN is the only one-click fiat-to-PulseChain-token service.

### SquirrelSwap Fee (0.8%, Discountable)

SquirrelSwap charges **0.8%** as an aggregator fee on swaps. This applies to OWN pipeline transactions that involve a swap (on-ramp and off-ramp to PulseChain).

```
On-ramp to PulseChain:   Peer -> bridge -> SquirrelSwap swap (0.8%)
Off-ramp from PulseChain: SquirrelSwap swap (0.8%) -> bridge -> Peer

Full pipeline cost:
  OWN 0.3% + Peer ~0.7% + SquirrelSwap 0.8% = ~1.8%

Still 2-3x cheaper than Coinbase/MoonPay (3-5%), and OWN is the only
one-click fiat-to-PulseChain-token service that exists.
```

**Squirrel NFT and NUTS discounts apply.** Holding a Squirrel NFT or staking NUTS reduces the SquirrelSwap fee, same as any other swap on the platform. This rewards loyal SquirrelSwap users who also use OWN.

Bridge mode does not use SquirrelSwap (no swap involved). Direct Base on/off-ramp does not use SquirrelSwap either.

### Platform Fee (Service-Level, Direct Base Only)

For direct Base on/off-ramp (no bridge involved), OWN charges a **0.1% platform fee** at the service level. This is not an on-chain contract fee -- the service takes 0.1% when routing through Peer.

```
On-ramp to Base:   Peer delivers USDC to service -> service deducts 0.1% -> sends to user
Off-ramp from Base: User sends USDC to service -> service deducts 0.1% -> forwards to Peer

Revenue: 100% to protocol (no LP involved, no fill)
```

This covers the cost of providing the interface, Peer SDK integration, and transaction monitoring. Without it, the direct Base flows generate zero revenue despite using OWN's infrastructure.

### Total Cost by Mode

```
Mode               OWN Fee    Platform    Peer Spread    Swap Fee*   Total User Cost    Steps
-----------------  --------   --------   ------------   ---------   ----------------   -----
Bridge             0.3%       -          -              -           0.3%               1 (bridge only)
On-ramp (Pulse)    0.3%       -          ~0.5-1%        0.8%        ~1.6-2.1%          3 (Peer + bridge + swap)
On-ramp (Base)     -          0.1%       ~0.5-1%        -           ~0.6-1.1%          1 (Peer + platform fee)
Off-ramp (Pulse)   0.3%       -          ~0.5-1%        0.8%        ~1.6-2.1%          3 (swap + bridge + Peer)
Off-ramp (Base)    -          0.1%       ~0.5-1%        -           ~0.6-1.1%          1 (Peer + platform fee)

* Swap Fee reducible via Squirrel NFT / NUTS staking discounts.
Every mode generates revenue for the protocol. No free rides.
```

Direct Base modes are still the cheapest paths (~0.8% typical). On-ramp to Base is useful for LPs topping up USDC for fills, or users who want USDC on Base for DeFi. Off-ramp from Base is the natural withdrawal path for LPs who accumulated USDC from fills.

### On-Chain Fee Logic

`markSettled()` does one transfer and one pool update:

```
1. poolAssets += (amount - 0.2%)               -> LP pool earns (share price rises)
2. token.transfer(protocolFeeRecipient, 0.2%)  -> protocol fee sent externally
```

The 0.1% LP fee is never explicitly calculated — it's the natural spread between what the pool gave out (netAmount after 0.3%) and what flows back (amount minus 0.2%). All pool depositors benefit proportionally via share price appreciation. The Peer spread is entirely external and never touches OWN contracts.

### Protocol Fee (0.2%) Usage

```
All 0.2% goes directly to protocol-owned LP position (compounds).

Once protocol LP reaches self-sufficiency target:
  0.10% -> protocol-owned LP
  0.10% -> operations/treasury
```

### The Flywheel

```
Users on-ramp -> fees generated -> protocol LP grows ->
more fill capacity -> less LP dependency ->
can lower fees -> more users -> more fees -> ...
```

Protocol LP rebalancing: fees accumulate on source chain. Protocol uses its own bridge to move fees between chains. Dogfooding.

### Future Fee Tiers (with CoW cycles)

```
Fill Type          User Pays    Protocol Gets    Filler Gets
-----------------------------------------------------------------
LP fill            0.3%         0.2%             0.1% (native LP)
CoW cycle          0.15%        0.15%            0%   (no filler needed)
```

CoW cycles emerge naturally from on-ramp/off-ramp flow. Users get a discount when demand matches. Incentivizes bidirectional volume.

---

## $1,000 Breakdown: Every Mode, Every Dollar

All examples use $1,000 input, 0.7% Peer spread (typical Venmo), 0.3% OWN bridge fee, 0.8% SquirrelSwap fee (before NFT/NUTS discounts), 0.1% platform fee (direct Base only).

### 1. On-Ramp to PulseChain: $1,000 fiat -> PLS

```
Step                What happens                        Amount          Goes to
────                ────────────                        ──────          ───────
Fiat payment        User sends $1,000 via Venmo         $1,000.00       Peer maker
Peer settlement     Maker spread ~0.7%                  -$7.00          Peer maker keeps
USDC on Base        Peer delivers to service             $993.00 USDC   Service (on Base)
bridge()            Lock USDC, deduct 0.3% fee           $993.00 locked  OwnBridge contract
  └─ fee split      0.3% = $2.98 kept in contract       $2.98           (distributed at settlement)
  └─ netAmount      993.00 - 2.98                        $990.02         Encoded in Hyperlane message
handle()            LP releases eUSDC on PulseChain      $990.02 eUSDC  Swap executor
Swap                eUSDC -> PLS via SquirrelSwap        ~$982.10 PLS   User's wallet
  └─ swap fee       SquirrelSwap 0.8%                    $7.92           SquirrelSwap protocol
  └─ gas            Service pays PulseChain gas          ~$0.01          Validators
markSettled()       Distribute locked USDC on Base:
  └─ LP payment     993.00 - (993 × 0.2%)               $991.01 USDC   Filling LP
  └─ protocol fee   993.00 × 0.2%                       $1.99 USDC     Protocol-owned LP

USER RECEIVES:   ~$982 worth of PLS
USER PAID:       $1,000 fiat
TOTAL COST:      ~$17.90 (~1.8%)

WHERE THE $17.90 WENT:
  Peer maker:      $7.00     (market-driven spread, external)
  SquirrelSwap:    $7.92     (0.8% swap fee — reducible with NFT/NUTS)
  Protocol LP:     $1.99     (compounds, grows protocol capacity)
  Filling LP:      $0.99     (implicit 0.1% profit)
  Gas:             ~$0.01    (service absorbs)

LP POSITION CHANGE:
  Gave:   990.02 eUSDC on PulseChain
  Got:    991.01 USDC on Base
  Profit: $0.99 (0.1%)
  Net:    shifted from PulseChain toward Base
```

### 2. On-Ramp to Base: $1,000 fiat -> USDC on Base

```
Step                What happens                        Amount          Goes to
────                ────────────                        ──────          ───────
Fiat payment        User sends $1,000 via Venmo         $1,000.00       Peer maker
Peer settlement     Maker spread ~0.7%                  -$7.00          Peer maker keeps
USDC on Base        Peer delivers to service             $993.00 USDC   Service wallet (on Base)
Platform fee        Service deducts 0.1%                 -$0.99          Protocol
USDC to user        Service sends remainder              $992.01 USDC   User's wallet (on Base)

No OwnBridge contract. No bridge. No swap. Service-level platform fee only.

USER RECEIVES:   $992.01 USDC on Base
USER PAID:       $1,000 fiat
TOTAL COST:      $7.99 (~0.8%)

WHERE THE $7.99 WENT:
  Peer maker:      $7.00     (market-driven spread, external)
  Protocol:        $0.99     (0.1% platform fee, service-level)
  Filling LP:      $0        (no LP involved)
  Gas:             ~$0.01    (Peer's Base gas, negligible)

LP POSITION CHANGE:  none
```

### 3. Off-Ramp from PulseChain: $1,000 of PLS -> fiat

```
Step                What happens                        Amount          Goes to
────                ────────────                        ──────          ───────
Swap                PLS -> eUSDC via SquirrelSwap        $992.00 eUSDC  Service (swap executor)
  └─ swap fee       SquirrelSwap 0.8%                    $8.00           SquirrelSwap protocol
  └─ gas            Service pays PulseChain gas          ~$0.01          Validators
bridge()            Lock eUSDC, deduct 0.3% fee          $992.00 locked  OwnBridge contract
  └─ fee split      0.3% = $2.98 kept in contract       $2.98           (distributed at settlement)
  └─ netAmount      992.00 - 2.98                        $989.02         Encoded in Hyperlane message
handle()            LP releases USDC on Base             $989.02 USDC   User's wallet (on Base)
markSettled()       Distribute locked eUSDC on Pulse:
  └─ LP payment     992.00 - (992 × 0.2%)               $990.02 eUSDC  Filling LP
  └─ protocol fee   992.00 × 0.2%                       $1.98 eUSDC    Protocol-owned LP
Peer off-ramp       User sells $989.02 USDC for fiat    $989.02 USDC   Peer maker
  └─ spread         Maker spread ~0.7%                   -$6.92          Peer maker keeps
Fiat received       Cash in user's account               ~$982.10        User's bank

USER RECEIVES:   ~$982.10 fiat
USER STARTED:    ~$1,000 worth of PLS
TOTAL COST:      ~$17.90 (~1.8%)

WHERE THE $17.90 WENT:
  SquirrelSwap:    $8.00     (0.8% swap fee — reducible with NFT/NUTS)
  Peer maker:      $6.92     (market-driven spread, external)
  Protocol LP:     $1.98     (compounds on PulseChain side)
  Filling LP:      $1.00     (implicit 0.1% profit)
  Gas:             ~$0.01    (service absorbs)

LP POSITION CHANGE:
  Gave:   989.02 USDC on Base
  Got:    990.02 eUSDC on PulseChain
  Profit: $1.00 (0.1%)
  Net:    shifted from Base toward PulseChain (opposite of on-ramp)
```

### 4. Off-Ramp from Base: $1,000 USDC -> fiat

```
Step                What happens                        Amount          Goes to
────                ────────────                        ──────          ───────
USDC to service     User sends $1,000 USDC to service  $1,000 USDC    Service wallet (on Base)
Platform fee        Service deducts 0.1%                 -$1.00          Protocol
Forward to Peer     Service sends remainder to Peer      $999.00 USDC   Peer maker
  └─ spread         Maker spread ~0.7%                   -$6.99          Peer maker keeps
Fiat received       Cash in user's account               $992.01         User's bank

No OwnBridge contract. No bridge. No swap. Service-level platform fee only.

USER RECEIVES:   $992.01 fiat
USER STARTED:    $1,000 USDC on Base
TOTAL COST:      $7.99 (~0.8%)

WHERE THE $7.99 WENT:
  Peer maker:      $6.99     (market-driven spread, external)
  Protocol:        $1.00     (0.1% platform fee, service-level)
  Filling LP:      $0        (no LP involved)
  Gas:             ~$0.01    (Peer's Base gas, negligible)

LP POSITION CHANGE:  none
```

### 5. Bridge: Base -> PulseChain ($1,000 USDC -> eUSDC)

```
Step                What happens                        Amount          Goes to
────                ────────────                        ──────          ───────
bridge()            Lock USDC, deduct 0.3% fee           $1,000 locked   OwnBridge contract
  └─ fee split      0.3% = $3.00 kept in contract       $3.00           (distributed at settlement)
  └─ netAmount      1,000 - 3.00                         $997.00         Encoded in Hyperlane message
handle()            LP releases eUSDC on PulseChain      $997.00 eUSDC  User's wallet (on Pulse)
markSettled()       Distribute locked USDC on Base:
  └─ LP payment     1,000 - (1,000 × 0.2%)              $998.00 USDC   Filling LP
  └─ protocol fee   1,000 × 0.2%                        $2.00 USDC     Protocol-owned LP

No Peer. No swap.

USER RECEIVES:   997.00 eUSDC on PulseChain
USER STARTED:    1,000.00 USDC on Base
TOTAL COST:      $3.00 (0.3%)

WHERE THE $3 WENT:
  Protocol LP:     $2.00     (compounds, grows protocol capacity)
  Filling LP:      $1.00     (implicit 0.1% profit)
  Gas:             ~$0.01    (Hyperlane message fee)

LP POSITION CHANGE:
  Gave:   997.00 eUSDC on PulseChain
  Got:    998.00 USDC on Base
  Profit: $1.00 (0.1%)
  Net:    shifted from PulseChain toward Base
```

### 6. Bridge: PulseChain -> Base ($1,000 eUSDC -> USDC)

```
Step                What happens                        Amount          Goes to
────                ────────────                        ──────          ───────
bridge()            Lock eUSDC, deduct 0.3% fee          $1,000 locked   OwnBridge contract
  └─ fee split      0.3% = $3.00 kept in contract       $3.00           (distributed at settlement)
  └─ netAmount      1,000 - 3.00                         $997.00         Encoded in Hyperlane message
handle()            LP releases USDC on Base             $997.00 USDC   User's wallet (on Base)
markSettled()       Distribute locked eUSDC on Pulse:
  └─ LP payment     1,000 - (1,000 × 0.2%)              $998.00 eUSDC  Filling LP
  └─ protocol fee   1,000 × 0.2%                        $2.00 eUSDC    Protocol-owned LP

USER RECEIVES:   997.00 USDC on Base
USER STARTED:    1,000.00 eUSDC on PulseChain
TOTAL COST:      $3.00 (0.3%)

WHERE THE $3 WENT:
  Protocol LP:     $2.00     (compounds on PulseChain side)
  Filling LP:      $1.00     (implicit 0.1% profit)

LP POSITION CHANGE:
  Gave:   997.00 USDC on Base
  Got:    998.00 eUSDC on PulseChain
  Profit: $1.00 (0.1%)
  Net:    shifted from Base toward PulseChain (opposite of mode 5)
```

### Summary: $1,000 Across All Modes

```
Mode                   User gets      Total cost      Peer     Swap*    Protocol   LP profit
─────────────────────  ────────────   ─────────────   ──────   ──────   ────────   ─────────
On-ramp (PulseChain)   ~$982 PLS      ~$18 (1.8%)     $7.00    $7.92    $1.99      $0.99
On-ramp (Base)         $992.01 USDC   $7.99 (0.8%)    $7.00    -        $0.99      $0
Off-ramp (PulseChain)  ~$982 fiat     ~$18 (1.8%)     $6.92    $8.00    $1.98      $1.00
Off-ramp (Base)        $992.01 fiat   $7.99 (0.8%)    $6.99    -        $1.00      $0
Bridge (Base->Pulse)   997 eUSDC      $3 (0.3%)       $0       -        $2.00      $1.00
Bridge (Pulse->Base)   997 USDC       $3 (0.3%)       $0       -        $2.00      $1.00

* Swap fee reducible with Squirrel NFT / NUTS staking discounts.
```

Key observations:
- **Every mode generates protocol revenue** -- no free rides, even direct Base flows earn 0.1%
- **OWN + SquirrelSwap earns ~$10 per $1,000** on PulseChain ramps ($2 protocol + $8 swap)
- **LP earns $1 per $1,000 bridged** and naturally rebalances (on-ramp shifts toward Base, off-ramp shifts toward PulseChain)
- **1.8% total is still 2-3x cheaper** than Coinbase/MoonPay (3-5%), and OWN is the only one-click fiat-to-PulseChain-token service
- **NFT/NUTS holders get better rates** -- rewards existing SquirrelSwap community
- **Direct Base modes are cheapest** (~0.8%) -- attractive entry point that funnels users into the ecosystem

---

## Security Model

### Trust Assumptions

```
Users trust:
  - OwnBridge contracts (auditable, on-chain)
  - Hyperlane validator set (message delivery)
  - Peer for fiat <-> USDC leg
  - Service swap executor (holds eUSDC briefly during on-ramp swap,
    holds user's approved token briefly during off-ramp swap)

LPs trust:
  - OwnBridge contracts (pool custodies deposited funds, releases only on valid Hyperlane message)
  - Hyperlane validators (won't forge messages)
  - Service operator (calls markSettled to feed LP payment back to pool — if operator
    disappears, pool is depleted by fills but never replenished. LP can withdraw remaining.)

Service operator can:
  - Call markSettled() to distribute locked funds to pool + protocol
  - Receive eUSDC via handle() and swap to user's desired token (on-ramp)
  - Swap user's approved token to eUSDC and bridge (off-ramp)
  - Cannot call markSettled() on already-settled or refunded deposits
  - Cannot drain pool beyond valid Hyperlane messages (handle() only fires on valid messages)
  - Cannot prevent user refunds after 2hr timeout (user calls directly)
  - Cannot prevent LP withdrawals (withdrawLP() has no pause guard)

Swap executor risk:
  - eUSDC sits in swap executor wallet briefly (~seconds) between handle() and swap
  - If service fails mid-swap: eUSDC recoverable from executor wallet (operator key)
  - Source-chain deposit still protected by 2hr refund timeout
  - Same trust model as markSettled() -- user already trusts the service to settle
```

### Settlement Safety

Three-step settlement with refund escape hatch:

```
Happy path (bridge / eUSDC on-ramp):
  bridge() -> message -> handle() -> user has tokens -> markSettled()

Happy path (token on-ramp):
  bridge() -> message -> handle() -> swap executor -> SquirrelSwap -> user has tokens -> markSettled()

Happy path (token off-ramp):
  user approves -> swap executor -> SquirrelSwap -> bridge() -> message -> handle() -> user has USDC -> markSettled()

Failure path:
  bridge() -> message fails or handle() reverts
  -> markSettled() never called (deposit stays unsettled)
  -> User calls refund() after 2 hours -> gets tokens back

Double-spend prevention:
  markSettled() sets deposit.settled = true
  refund() requires !settled && !refunded
  Once settled, user cannot refund. Once refunded, operator cannot settle.
```

Nobody loses funds. Worst case is a 2-hour wait for refund.

### LP Protection

- LP funds are in the pool — only released on valid Hyperlane messages
- Messages are verified: correct origin chain, correct sender contract
- LP can withdraw from pool at any time (no pause guard on withdrawals)
- Pool balance is authoritative — no stale allowance state, no race conditions

### Hyperlane Trust

Hyperlane uses configurable security: ISMs (Interchain Security Modules). OWN can configure:
- Default multisig ISM (Hyperlane's validator set)
- Custom ISM with additional verification
- Future: add your own validator to the set

---

## Service Architecture

### Components

```
src/
  api/
    routes.ts              -- REST API
    auth.ts                -- Signature-based authentication

  orchestrator/
    pipeline.ts            -- Master pipeline: Peer -> bridge -> swap (or bridge-only)
    peer/
      client.ts            -- Peer SDK integration
      monitor.ts           -- Watch for Peer settlement events
    bridge/
      dispatcher.ts        -- Call OwnBridge.bridge() after Peer settles
      monitor.ts           -- Watch Bridged + Released events on both chains
    swap/
      executor.ts          -- Execute swaps via SquirrelSwap on behalf of users
      gas.ts               -- Service gas wallet management (PLS for PulseChain gas)

  lp/
    monitor.ts             -- Pool balance monitoring across chains
    rebalancer.ts          -- Track pool balance across chains, alert if low

  chain/
    clients.ts             -- Viem clients for Base + PulseChain
    contracts.ts           -- OwnBridge ABI + SquirrelSwap router ABI

  db/
    database.ts            -- SQLite
    models.ts              -- Schema definitions

  config/
    chains.ts              -- Base + PulseChain configs
    constants.ts           -- Fee rates, timeouts
```

The swap executor is a service-controlled wallet on PulseChain that:
- Receives eUSDC from `handle()` on on-ramp (when user wants a non-eUSDC token)
- Swaps via SquirrelSwap and sends output token to user
- Receives user's token approval and swaps to eUSDC on off-ramp (before bridging)
- Pays PulseChain gas from a small PLS balance (topped up periodically, costs pennies)

Removed from HTLC design: settler.ts (7-step pipeline), secretManager.ts, gasManager.ts, matcher.ts, fee collector/compounder. All replaced by the simpler Hyperlane dispatch + monitor + swap flow. Fees are handled entirely on-chain by markSettled() — no off-chain fee routing needed.

### Database Schema

```sql
-- Bridge transactions
CREATE TABLE bridges (
  id TEXT PRIMARY KEY,
  user_address TEXT,
  direction TEXT,         -- 'base_to_pulse' | 'pulse_to_base'
  amount TEXT,
  net_amount TEXT,
  protocol_fee TEXT,
  lp_payment TEXT,
  nonce INTEGER,
  dest_recipient TEXT,
  filling_lp TEXT,        -- LP address that filled on dest chain
  status TEXT,            -- 'bridged' | 'released' | 'settled' | 'refunded' | 'failed'
  bridge_tx TEXT,         -- bridge() tx hash on source
  release_tx TEXT,        -- handle() tx hash on dest
  settle_tx TEXT,         -- markSettled() tx hash on source
  created_at INTEGER,
  released_at INTEGER,
  settled_at INTEGER
);

-- Full pipeline intents (covers all five modes)
CREATE TABLE intents (
  id TEXT PRIMARY KEY,
  user_address TEXT,
  type TEXT,              -- 'onramp' | 'offramp' | 'bridge'
  dest TEXT,              -- 'pulse' | 'base' (for onramp: where tokens go)
  source TEXT,            -- 'pulse' | 'base' (for offramp: where tokens come from)
  fiat_amount TEXT,       -- NULL for bridge-only
  token_symbol TEXT,      -- what user wants (PLS, HEX, eUSDC, etc.) or NULL for bridge/direct-base
  direction TEXT,         -- 'base_to_pulse' | 'pulse_to_base' (set for bridge type)
  status TEXT,            -- 'pending_fiat' | 'fiat_complete' | 'bridging' |
                          -- 'swapping' | 'complete' | 'failed' | 'refunded'
  peer_order_id TEXT,     -- NULL for bridge-only
  bridge_id TEXT,         -- FK to bridges table, NULL for direct-base on/off-ramp
  swap_tx TEXT,           -- SquirrelSwap tx hash, NULL for bridge/direct-base
  created_at INTEGER,
  updated_at INTEGER
);

-- LP registry
CREATE TABLE pool_state (
  chain TEXT,
  pool_assets TEXT,
  total_shares TEXT,
  share_price TEXT,
  last_updated INTEGER,
);
  PRIMARY KEY (address, chain, token)
);

-- Protocol-owned LP balance (tracked on-chain, mirrored here for queries)
CREATE TABLE protocol_lp (
  chain TEXT,
  token TEXT,
  balance TEXT,           -- updated from Settled events
  PRIMARY KEY (chain, token)
);
```

### API Design

**Public endpoints:**

```
GET  /health
GET  /stats
GET  /quote?amount=500&type=onramp&token=PLS   -- full pipeline quote (includes Peer spread estimate)
GET  /quote?amount=1000&type=bridge&direction=base_to_pulse  -- bridge-only quote (OWN fee only)
```

**User endpoints (signature auth):**

```
POST   /onramp                -- initiate on-ramp (amount, token, fiat method, dest: pulse | base)
POST   /offramp               -- initiate off-ramp (amount, token, source: pulse | base)
POST   /bridge                -- initiate bridge (amount, direction: base_to_pulse | pulse_to_base)
GET    /intent/:id            -- pipeline status + progress
DELETE /intent/:id            -- cancel (if not yet bridged)
GET    /history               -- past transactions (all types: onramp, offramp, bridge)
```

**LP endpoints (signature auth):**

```
POST /lp/register             -- register as LP (chain, token)
POST /lp/deactivate           -- pause fills
GET  /lp/status               -- position, fill history, earnings
GET  /lp/earnings             -- fee earnings breakdown
```

---

## Frontend

### Three modes, one interface

Mode toggle: **[ Buy | Cash Out | Bridge ]**

**On-Ramp (Buy to PulseChain):**
```
+--------------------------------+
|  OWN                           |
|  [ Buy | Cash Out | Bridge ]   |
|                                |
|  To: [PulseChain] [Base]       |
|  I want to buy: [PLS    v]    |
|  Amount: [$500        ]        |
|  Pay via: [Venmo v]            |
|                                |
|  You receive:   ~48,500 PLS   |
|  OWN fee:       $1.50 (0.3%)  |
|  Peer spread:   ~$4.00 (est.) |
|  Total fees:    ~$5.50 (1.1%) |
|  Time:          ~3-5 min       |
|                                |
|  [Buy PLS ->]                  |
+--------------------------------+
```

**On-Ramp (Buy to Base -- direct):**
```
+--------------------------------+
|  OWN                           |
|  [ Buy | Cash Out | Bridge ]   |
|                                |
|  To: [PulseChain] [Base]       |
|  Amount: [$500  ] USDC        |
|  Pay via: [Venmo v]            |
|                                |
|  You receive:   ~$496.00 USDC |
|  OWN fee:       -              |
|  Peer spread:   ~$4.00 (est.) |
|  Time:          ~2-5 min       |
|  Pipeline: Peer only           |
|                                |
|  [Buy USDC ->]                 |
+--------------------------------+
```

When "To Base" is selected: no token selector (always USDC), no OWN fee (no bridge involved), just Peer. Mirror of the "From Base" off-ramp. Useful for LPs topping up Base-side USDC for fills.

**Off-Ramp (Cash Out from PulseChain):**
```
+--------------------------------+
|  OWN                           |
|  [ Buy | Cash Out | Bridge ]   |
|                                |
|  From: [PulseChain] [Base]     |
|  Cash out: [PLS     v]        |
|  Amount: [48,500 PLS   ]      |
|  Receive via: [Venmo v]        |
|                                |
|  You receive:   ~$493.50      |
|  OWN fee:       $1.50 (0.3%)  |
|  Peer spread:   ~$4.00 (est.) |
|  Total fees:    ~$5.50 (1.1%) |
|  Time:          ~3-5 min       |
|  Pipeline: Swap -> Bridge -> Peer|
|                                |
|  [Cash Out ->]                 |
+--------------------------------+
```

**Off-Ramp (Cash Out from Base -- direct):**
```
+--------------------------------+
|  OWN                           |
|  [ Buy | Cash Out | Bridge ]   |
|                                |
|  From: [PulseChain] [Base]     |
|  Amount: [$500  ] USDC        |
|  Receive via: [Venmo v]        |
|                                |
|  You receive:   ~$496.00      |
|  OWN fee:       -              |
|  Peer spread:   ~$4.00 (est.) |
|  Time:          ~2-5 min       |
|  Pipeline: Peer only           |
|                                |
|  [Cash Out ->]                 |
+--------------------------------+
```

When "From Base" is selected: no token selector (always USDC), no OWN fee (no bridge involved), just Peer. This is the natural LP withdrawal path.

**Bridge:**
```
+--------------------------------+
|  OWN                           |
|  [ Buy | Cash Out | Bridge ]   |
|                                |
|  [Base -> Pulse] [Pulse -> Base]|
|  Amount: [1000       ] USDC   |
|                                |
|  You receive: 997.00 eUSDC    |
|  OWN fee:     $3.00 (0.3%)    |
|  Time:        ~1 min           |
|                                |
|  [Bridge to PulseChain ->]     |
+--------------------------------+
```

**Progress Trackers:**
```
On-ramp (Pulse):               On-ramp (Base):
  [x] Fiat payment sent         [x] Buying USDC via Peer
  [x] USDC received on Base     [~] Complete
  [x] Bridged to PulseChain
  [~] Swapping to PLS...      ~2-5 min total
  [ ] Complete                 (2 steps, Peer only)

~3-5 min total                 Bridge:
(5 steps, full pipeline)         [x] USDC locked on Base
                                 [~] Bridging to PulseChain...
                                 [ ] eUSDC released

                               ~1 min total
                               (3 steps, no Peer, no swap)
```

### Tabs

```
[ Buy / Cash Out ]  [ History ]  [ LP ]
```

- **Buy / Cash Out** is the main tab with the mode toggle (Buy, Cash Out, Bridge)
- **History** shows all transactions with type badges (BUY, SELL, BRIDGE), separate OWN fee and Peer fee columns
- **LP** dashboard with Base + PulseChain positions, earnings chart, recent fills

No separate bridge page. Bridge lives alongside Buy/Cash Out as a mode toggle. The UI adapts: bridge mode hides the payment method selector and token selector, shows a direction picker instead.

---

## Tech Stack

```
Contracts:    Solidity, Foundry (test + deploy)
Service:      TypeScript, Node.js, Viem
Database:     SQLite
Frontend:     React or Svelte, Viem, WalletConnect
DEX:          SquirrelSwap (existing, live on PulseChain)
Messaging:    Hyperlane Mailbox (existing, live on Base + PulseChain)
Hosting:      Single VPS
Monitoring:   Health checks + alerts on failed bridges
```

---

## Build Phases

```
Phase 1: Contracts
  - OwnBridge.sol + tests (Foundry)
  - Integrate with Hyperlane Mailbox interface
  - Deploy to Base testnet + PulseChain testnet
  - Test bridge() -> handle() -> release flow end to end

Phase 2: Core Service
  - Chain clients (Base + PulseChain)
  - Database + schema
  - Bridge dispatcher (call bridge() after Peer)
  - Event monitors (Bridged, Released, Refunded)
  - LP manager
  - Fee collector + compounder
  - Basic API

Phase 3: Peer Integration
  - Peer SDK wrapper
  - Peer settlement monitor
  - Orchestrator pipeline (fiat -> Peer -> bridge -> swap)
  - End-to-end testnet test

Phase 4: SquirrelSwap Integration
  - Post-bridge auto-swap for on-ramp (eUSDC -> desired token)
  - Pre-bridge auto-swap for off-ramp (token -> eUSDC)
  - Quote aggregation for frontend display

Phase 5: Frontend
  - On-ramp flow (token selector, amount, fiat method)
  - Off-ramp flow
  - Progress tracking
  - Wallet connection
  - LP registration page at /lp

Phase 6: Testnet Launch
  - Full pipeline: fiat -> Peer -> bridge -> swap
  - LP onboarding test
  - Refund flow test (what happens when bridge fails)
  - Error recovery

Phase 7: Mainnet
  - Deploy OwnBridge to Base + PulseChain mainnet
  - Seed $200-500 as protocol LP
  - Recruit 1-2 LPs from PulseChain community
  - Record demo video of full pipeline
  - Soft launch with transaction limits
  - Monitor everything
```

---

## Future Enhancements

### CoW Cycle Detection

On-ramp and off-ramp flows naturally create cycles. Batch intents, find matching pairs, settle directly without LPs. Users get fee discount (0.15% vs 0.3%).

### ERC-7683 Intent Interoperability

Open to external solvers when volume justifies it. Native LPs get priority fill.

### DEX Integration (Phase 2 Product)

"Buy $500 of PLS with your bank account" -- single action. Already architectured with SquirrelSwap in the pipeline.

### Multi-Chain Expansion

Add BSC <-> PulseChain, Arbitrum <-> PulseChain corridors. Same OwnBridge contract, new Hyperlane routes. Expand from position of PulseChain dominance.

---

## Risk Register

### Hyperlane Reliability
- **Risk:** Message delivery fails or delays
- **Mitigation:** 2-hour refund timeout. User never loses funds.
- **Fallback:** Revert to HTLC architecture (~2 weeks to rebuild)

### Peer Integration
- **Risk:** SDK doesn't expose settlement events cleanly; mobile limitation
- **Mitigation:** Start with desktop-only. Monitor Peer's mobile roadmap.
- **Blocker check:** Investigate Peer SDK before writing other code

### PulseChain
- **Risk:** Regulatory ambiguity, community perception
- **Mitigation:** Community is underserved and willing to pay. Concentrated bet but addressable market.

### LP Liquidity
- **Risk:** Can't attract enough LP capital at launch
- **Mitigation:** Start tiny ($200-500 self-seeded). Cap transaction sizes. Grow organically.

### Off-Ramp Compliance
- **Risk:** Accepting fiat payments has regulatory implications
- **Mitigation:** V1 off-ramp is partially manual (user uses Peer directly for USDC -> fiat). Full automation requires legal review.

### Smart Contract Risk
- **Risk:** Bug in OwnBridge allows unauthorized release
- **Mitigation:** Minimal contract surface. Thorough testing (64 tests + fuzz suites). Pool model means contract holds LP funds — exposure is total pool size. Refund timeout limits user lockup duration. LP can withdraw anytime.
