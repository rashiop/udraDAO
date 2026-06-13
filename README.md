# udra DAO — Core Lane

Participation-based governance DAO where voting power is earned through on-chain actions. Deployed on Sepolia.

## Overview

udra DAO gives voting power to participants, not token holders. Users earn `UdraPowerToken` (UPT) by checking in once per epoch or by funding the treasury. The earned token is non-transferable and auto-self-delegated on mint, so every participant's votes are live immediately. Governance runs on the OZ Governor stack with a 1-hour timelock guarding the treasury.

### Key Properties

- **Participation-earned votes** — UPT is minted only by `UdraEarner`; no transfers, no purchases
- **Two earning actions** — `checkIn()` (10 UPT/epoch, once per user per epoch) and `fundTreasury()` (100 UPT per 0.01 ETH sent)
- **Per-epoch caps** — check-in: 5 000 UPT global; funding: 1 000 UPT/user, 10 000 UPT global
- **Bitmap tracking** — per-user check-in claims stored in a `uint256` bitmap; 256 epochs per slot, O(1) reads and writes
- **Auto-self-delegate** — first mint sets `delegates(to) = to` so votes are active without an extra transaction
- **Non-transferable token** — `_update` override reverts any `from != address(0) && to != address(0)` call
- **Timelock-owned treasury** — `UdraCoreTarget` is owned by the timelock; only approved proposals can release ETH or update `grantLimit`
- **ReentrancyGuard on all payout paths** — `releaseEth`, `fundTreasury`, and `checkIn` are all guarded
- **Pause controls** — owner can pause `UdraEarner`; all earning blocked while paused

---

## Architecture

### Technologies

| Category | Technology |
|----------|------------|
| Language | Solidity ^0.8.33 |
| Framework | Foundry |
| Libraries | OpenZeppelin Contracts ^5.x |
| Testnet | Sepolia |
| Voting UI | Snapshot (snapshot.org) |

### OpenZeppelin Dependencies

- `ERC20Votes` + `EIP712` — checkpoint-based voting power with delegation
- `AccessControlDefaultAdminRules` — `EARNER_ROLE` gates minting; configurable admin transfer delay (default 3 days)
- `Ownable2Step` — two-step ownership transfer on `UdraEarner` and `UdraCoreTarget`
- `Pausable` — emergency stop for `UdraEarner`
- `ReentrancyGuard` / `ReentrancyGuardTransient` — payout path protection
- `TimelockController` — execution delay + role-based governance authority
- `Governor` + extensions — full proposal lifecycle with snapshot voting

### Project Structure

```
src/
├── UdraPowerToken.sol               # ERC20Votes governance token
├── UdraEarner.sol                   # Participation gatekeeper — checkIn + fundTreasury
├── UdraCoreTarget.sol               # Governed treasury — releaseEth + setGrantLimit
└── governance_standard/
    ├── TimelockController.sol       # OZ TimelockController wrapper
    └── UdraCoreGovernor.sol         # OZ Governor stack

script/
├── ProtocolConfig.sol               # Canonical protocol constants (shared by tests + script)
└── DeployUdraCore.s.sol             # Full deploy + wiring in one run

test/
├── BaseTest.t.sol                   # Shared setUp, actors, and helpers
├── UdraPowerToken.t.sol             # Token — mint, delegation, checkpoints, transfers
├── UdraEarner.t.sol                 # Earner — checkIn, fundTreasury, views, pause, caps
├── UdraCoreTarget.t.sol             # Target — releaseEth, setGrantLimit, ownership
├── UdraCoreGovernor.t.sol           # Governor — full lifecycle, voting, state, quorum
├── Reentrancy.t.sol                 # Reentrancy guard proofs on releaseEth
├── fuzz/
│   ├── EarnerFuzz.t.sol             # Fuzz — reward math, epoch boundaries, bitmap
│   └── TargetFuzz.t.sol             # Fuzz — grantLimit ceiling semantics, balance accounting
└── invariant/
    ├── EarnerInvariant.t.sol        # Handler + cap invariants (check-in + fund)
    └── TokenInvariant.t.sol         # Handler + supply and balance invariants
```

---

## Contracts

### UdraPowerToken.sol

#### Constructor Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `initialOwner` | `address` | Receives `DEFAULT_ADMIN_ROLE`; may call `setEarner` / `revokeEarner` |
| `tokenName` | `string` | ERC20 token name |
| `tokenSymbol` | `string` | ERC20 token symbol |
| `adminTransferDelay` | `uint48` | Delay before `DEFAULT_ADMIN_ROLE` transfer completes (default 3 days = 259 200 s) |

#### Roles

| Role | Permission |
|------|------------|
| `DEFAULT_ADMIN_ROLE` | `setEarner()`, `revokeEarner()`, manage all roles |
| `EARNER_ROLE` | `mint()` |

#### Key Functions

| Function | Access | Description |
|----------|--------|-------------|
| `mint(to, amount)` | `EARNER_ROLE` | Mints UPT; auto-self-delegates recipient on first mint |
| `setEarner(earner)` | `DEFAULT_ADMIN_ROLE` | Grants `EARNER_ROLE` to earner contract |
| `revokeEarner(earner)` | `DEFAULT_ADMIN_ROLE` | Revokes `EARNER_ROLE` |
| `delegate(delegatee)` | Holder | Delegates voting power; standard OZ ERC20Votes |
| `delegateBySig(...)` | Anyone | EIP-712 off-chain delegation signature |
| `getVotes(account)` | View | Current voting weight |
| `getPastVotes(account, timepoint)` | View | Snapshot voting weight at past block |

#### Events

| Event | Emitted By |
|-------|------------|
| `EarnerGranted(earner)` | `setEarner` |
| `EarnerRevoked(earner)` | `revokeEarner` |
| `Transfer(from, to, value)` | OZ ERC20 (mint path only) |
| `DelegateChanged(delegator, fromDelegate, toDelegate)` | OZ ERC20Votes |
| `DelegateVotesChanged(delegate, previousVotes, newVotes)` | OZ ERC20Votes |

#### Custom Errors

```solidity
error TransfersDisabled();   // _update called with from != 0 && to != 0
error NoZeroAddress();       // zero address passed where not allowed
error InvalidTokenName();    // empty token name
error InvalidTokenSymbol();  // empty token symbol
```

---

### UdraEarner.sol

#### Constructor Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `token` | `UdraPowerToken` | Token to mint into |
| `initialOwner` | `address` | Ownable2Step owner; may pause/unpause and transfer ownership |
| `CHECKIN_REWARD` | `uint256` | UPT minted per check-in (10 ether) |
| `FUND_REWARD_PER_UNIT` | `uint256` | UPT minted per funding unit (100 ether) |
| `FUND_UNIT` | `uint256` | Minimum ETH unit for funding (0.01 ether) |
| `CHECKIN_GLOBAL_CAP` | `uint256` | Max check-in UPT minted per epoch (5 000 ether) |
| `FUND_USER_CAP` | `uint256` | Max fund UPT per user per epoch (1 000 ether) |
| `FUND_GLOBAL_CAP` | `uint256` | Max fund UPT minted per epoch (10 000 ether) |
| `EPOCH_LENGTH` | `uint256` | Epoch duration in seconds (1 days) |
| `treasuryWallet` | `address` | ETH forwarded here on every `fundTreasury` call |

#### Immutables

| Name | Value | Description |
|------|-------|-------------|
| `CHECKIN_REWARD` | 10 ether | UPT per check-in |
| `CHECKIN_GLOBAL_CAP` | 5 000 ether | Max check-in UPT per epoch |
| `FUND_REWARD_PER_UNIT` | 100 ether | UPT per 0.01 ETH funded |
| `FUND_UNIT` | 0.01 ether | Minimum funding increment |
| `FUND_USER_CAP` | 1 000 ether | Max fund UPT per user per epoch |
| `FUND_GLOBAL_CAP` | 10 000 ether | Max fund UPT per epoch |
| `EPOCH_LENGTH` | 1 days | Epoch duration |
| `START_TIME` | deploy timestamp | Epoch zero anchor |
| `TREASURY_WALLET` | `UdraCoreTarget` address | ETH forwarding target |

#### Public Functions

| Function | Access | Description |
|----------|--------|-------------|
| `checkIn()` | Anyone, whenNotPaused | Claims 10 UPT for current epoch; reverts if already claimed or cap exhausted |
| `fundTreasury()` | Anyone, payable, whenNotPaused, nonReentrant | Forwards ETH to treasury; mints reward proportional to amount sent |
| `currentEpoch()` | View | `(block.timestamp − START_TIME) / EPOCH_LENGTH` |
| `claimedCheckIn(user)` | View | `true` if user claimed check-in in current epoch |
| `remainingUserCap(user)` | View | `(checkinCap, fundCap)` remaining for user in current epoch |
| `remainingGlobalCap()` | View | `(checkinCap, fundCap)` remaining globally in current epoch |
| `pause()` / `unpause()` | `onlyOwner` | Pauses or resumes all earning |
| `receive()` | Payable, whenNotPaused, nonReentrant | Delegates to `_fundTreasury()` — same as `fundTreasury()` |
| `fallback()` | — | Unconditionally reverts |

#### Events

| Event | Emitted By |
|-------|------------|
| `CheckinClaimed(user, epoch, amountToken)` | `checkIn` |
| `TreasuryFunded(user, amountEth, amountToken)` | `fundTreasury` |
| `PointsEarned(user, actionType, epoch, amount)` | both earning actions |

#### Custom Errors

```solidity
error BelowMinimumUnit(); // msg.value < FUND_UNIT
error FailToFund();       // ETH forwarding to treasury wallet failed
error NoCapLeft();        // global or user cap exhausted; also fires on duplicate check-in
error NoZeroAddress();
error NoZeroAmount();
```

---

### UdraCoreTarget.sol

#### Constructor Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `initialGrantLimit` | `uint256` | Initial ceiling per release; `0` = uncapped |
| `initialOwner` | `address` | Ownable2Step owner (transferred to timelock after deploy) |

#### Public Functions

| Function | Access | Description |
|----------|--------|-------------|
| `releaseEth(to, amount)` | `onlyOwner`, `nonReentrant` | Releases ETH to recipient; respects `grantLimit` ceiling |
| `setGrantLimit(newLimit)` | `onlyOwner` | Sets per-release ceiling; `0` = uncapped |
| `receive()` | Payable | Accepts ETH deposits |

#### grantLimit Semantics

| Value | Behaviour |
|-------|-----------|
| `0` (default) | Uncapped — any amount up to balance passes |
| `> 0` | Ceiling — releases above this value revert with `ExceedsGrantLimit` |

#### Events

| Event | Emitted By |
|-------|------------|
| `GrantReleased(to, amount)` | `releaseEth` |
| `GrantLimitUpdated(oldLimit, newLimit)` | `setGrantLimit` |

#### Custom Errors

```solidity
error InsufficientBalance();  // amount > address(this).balance
error ExceedsGrantLimit();    // grantLimit != 0 && amount > grantLimit
error NoZeroAddress();        // to == address(0)
error NoZeroAmount();         // amount == 0
error ReleaseFailed();        // low-level ETH transfer failed
```

---

### UdraCoreGovernor.sol

OZ Governor stack — no custom logic, only required override boilerplate.

#### Constructor Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `token` | `IVotes` | `UdraPowerToken` address |
| `timelock` | `TimelockController` | Timelock that executes approved proposals |

#### Governance Parameters

| Parameter | Value | Reasoning |
|-----------|-------|-----------|
| `votingDelay` | 7 200 blocks (~1 day) | Gives token holders time to delegate before snapshot is taken |
| `votingPeriod` | 50 400 blocks (~1 week) | Long enough for async participation on testnet |
| `proposalThreshold` | 200e18 UPT | Requires 20 check-ins; filters spam proposals |
| `quorum` | 4% of total supply | Low quorum appropriate for early-stage DAO with small supply |

#### Inheritance Stack

```
UdraCoreGovernor
├── Governor                       — proposal lifecycle, state machine
├── GovernorSettings               — adjustable delay/period/threshold
├── GovernorCountingSimple         — For / Against / Abstain vote counting
├── GovernorVotes                  — reads votes from UdraPowerToken (IVotes)
├── GovernorVotesQuorumFraction    — quorum as % of past total supply
└── GovernorTimelockControl        — queues/executes through TimelockController
```

---

### TimelockController (governance_standard/TimelockController.sol)

Thin wrapper around OZ `TimelockController`. Adds `acceptTargetOwnership` to complete the two-step ownership transfer to the timelock without requiring a separate governance proposal.

#### Deployment Configuration

| Parameter | Value | Reasoning |
|-----------|-------|-----------|
| `minDelay` | 3 600 s (1 hour) | Delay between queue and execution; allows review of queued proposals |
| `proposers` | `[governor]` | Only the Governor can queue proposals |
| `executors` | `[address(0)]` | Anyone may trigger execution after delay (permissionless) |
| `admin` | `deployer` | Renounced after setup; `CANCELLER_ROLE` retained as a safety backstop |

#### Added Functions

| Function | Access | Description |
|----------|--------|-------------|
| `acceptTargetOwnership(target)` | Anyone | Calls `Ownable2Step(target).acceptOwnership()`; completes the pending transfer to this timelock |

#### Custom Errors

```solidity
error NoZeroAddress();  // target == address(0)
```

#### Events

```solidity
event AcceptTargetOwnership(address indexed target);
```

> **Note:** `acceptTargetOwnership` has no role restriction — it can be called by anyone. This is safe because `Ownable2Step.acceptOwnership()` itself enforces that only the pending owner (this timelock) can complete the transfer. A third-party caller only triggers acceptance that was already authorised by the previous owner's `transferOwnership` call.

---

## Governance Flows

### Earning Voting Power

```
User                     UdraEarner               UdraPowerToken
 │                           │                          │
 ├── checkIn() ─────────────►│                          │
 │   (once per epoch)        │── mint(user, 10 UPT) ───►│
 │                           │                          │── auto-delegate (first mint)
 │◄── CheckinClaimed ────────┤                          │
 │◄── PointsEarned ──────────┤                          │
```

### Snapshot Integration (DAO-9)

UdraPowerToken is fully `IVotes`-compatible. Snapshot reads `getPastVotes(voter, snapshotBlock)` at the block recorded when the Snapshot proposal is created.

**Space configuration:**

```json
{
  "network": "11155111",
  "strategies": [
    {
      "name": "erc20-votes",
      "network": "11155111",
      "params": {
        "address": "0x054D551B18dAA1E53Dd6b7e629A9B50C764453A8",
        "symbol": "UPT",
        "decimals": 18
      }
    }
  ]
}
```

**Delegation requirement:** `delegate()` or `delegateBySig()` must be called before the snapshot block of each proposal. Auto-self-delegation fires on first mint, so participants who check in or fund the treasury are automatically delegated. If a participant mints after proposal creation, that balance will not count for that proposal.

**Flow:**

```
Earn UPT via checkIn / fundTreasury
         │
         ▼ (voting power is live — auto-delegated)
Create Snapshot proposal (off-chain, gasless vote)
         │
         ▼
Community votes on Snapshot (no gas required)
         │
         ▼ (Snapshot proposal passes)
Submit matching on-chain Governor proposal
         │
         ▼
Governor voting period → queue → timelock → execute
```

Snapshot voting is the off-chain governance signal. Real state changes only happen after the on-chain Governor + Timelock flow completes.

**Delegation compatibility:** `delegate(delegatee)` and `delegateBySig(...)` both work. Non-transferability does not affect delegation. Delegating to another address is technically possible but semantically unusual for a participation-based token where every participant should self-delegate.

---

### Proposal Lifecycle

```
Earn 200 UPT (20 check-ins)
         │
         ▼
governor.propose(targets, values, calldatas, description)
         │
         ▼
Wait votingDelay (7200 blocks)
         │
         ▼
governor.castVote(proposalId, For)
         │
         ▼
Wait votingPeriod (50400 blocks) — quorum must be reached
         │
         ▼
governor.queue(...)
         │
         ▼
Wait timelock minDelay (3600 seconds)
         │
         ▼
governor.execute(...)
         │
         ▼
UdraCoreTarget.releaseEth / setGrantLimit  ← real state change
```

### ETH Flow — fundTreasury

```
User
 │── fundTreasury{value: 0.02 ETH}() ──►UdraEarner
 │                                           │── forward 0.02 ETH ──►UdraCoreTarget
 │                                           │── mint(user, 200 UPT)►UdraPowerToken
 │◄── TreasuryFunded event ─────────────────┤
```

---

## Deployment

### Environment Variables

Copy `.env.example` to `.env` and fill in the required values:

```bash
cp .env.example .env
```

**Required:**

| Variable | Description |
|----------|-------------|
| `PRIVATE_KEY` | Deployer private key |
| `SEPOLIA_RPC_URL` | Sepolia JSON-RPC endpoint |
| `ETHERSCAN_API_KEY` | For contract verification |

All protocol parameters (`CHECKIN_REWARD`, `FUND_UNIT`, `TIMELOCK_DELAY`, etc.) are optional — the deploy script falls back to `ProtocolConfig.sol` defaults when not set.

### Deploy Script

```bash
forge script script/DeployUdraCore.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

### Deployment Order (enforced by script)

1. Deploy `UdraPowerToken` (`initialOwner = deployer`)
2. Deploy `UdraCoreTarget` (`grantLimit = 0`, `initialOwner = deployer`)
3. Deploy `TimelockController` (`minDelay=3600`, `proposers=[governor_placeholder]`, `executors=[address(0)]`, `admin=deployer`)
4. Deploy `UdraCoreGovernor` (`token`, `timelock`)
5. Deploy `UdraEarner` (`token`, `deployer`, caps/rewards, `treasuryWallet=target`)
6. `token.setEarner(earner)` — grants `EARNER_ROLE`
7. `timelock.grantRole(PROPOSER_ROLE, governor)` + `timelock.grantRole(CANCELLER_ROLE, deployer)` — governor proposes; deployer keeps emergency cancel
8. `target.transferOwnership(timelock)` + `timelock.acceptTargetOwnership(target)` — completes Ownable2Step; timelock is now owner
9. `timelock.renounceRole(PROPOSER_ROLE, deployer)` — removes temporary proposer; only governor can queue now
10. `timelock.renounceRole(DEFAULT_ADMIN_ROLE, deployer)` — fully autonomous

### Deployed Addresses (Sepolia)

Deployer: `0x405A10A6c4b207946d81a541DAdc76586719390d`

| Contract | Address |
|----------|---------|
| UdraPowerToken | 0x054D551B18dAA1E53Dd6b7e629A9B50C764453A8 |
| UdraEarner | 0xd70f7F72fa82aBc37b0F25C41c980Dd3c10b7b8F |
| UdraCoreTarget | 0xe6Eb48629d63E66A80A15ae4210E0F74bb89bE84 |
| TimelockController | 0x51E524024BFee393046B667F5Ba8E663dbEeADC0 |
| UdraCoreGovernor | 0xcD7B4d7eDfDEe8DD468a57479e2D7aaFDf18B7ce |

### Snapshot Space

| Item | Value |
|------|-------|
| Snapshot space | https://testnet.snapshot.org/#/s-tn:rashiop.eth |
| Snapshot proposal URL | https://testnet.snapshot.org/#/s-tn:rashiop.eth/proposal/0x1006ce316e3e30248b5c14a385d21929a7c77ea088e4eb54f2a55bc552877400 |
| Execution tx hash | [0xc5784e0ec5ea078af640a089e91852344e0a867700ee8e34419d571fea1437d6](https://sepolia.etherscan.io/tx/0xc5784e0ec5ea078af640a089e91852344e0a867700ee8e) |
| Strategy | `erc20-votes` on Sepolia — reads `getPastVotes` from UdraPowerToken |

---

## Testing

### Run Tests

```bash
# All tests
forge test

# With full traces
forge test -vvv

# Specific contract
forge test --match-contract UdraCoreGovernorTest

# Fuzz tests only
forge test --match-path "test/fuzz/*"

# Invariant tests (higher run count recommended)
forge test --match-contract "EarnerInvariantTest|TokenInvariantTest" --fuzz-runs 10000
```

### Test Coverage

| File | Tests | Focus |
|------|-------|-------|
| `UdraPowerToken.t.sol` | 21 | Mint access, transfers disabled, delegation, checkpoints, auto-delegate |
| `UdraEarner.t.sol` | 45 | checkIn and fundTreasury — success paths, all revert cases, views, pause, cap enforcement |
| `UdraCoreTarget.t.sol` | 20 | releaseEth, setGrantLimit, grantLimit semantics, Ownable2Step, balance accounting |
| `UdraCoreGovernor.t.sol` | 21 | Settings, propose, state transitions, voting, quorum, cancel, full lifecycle ×3 |
| `TimelockController.t.sol` | 7 | acceptTargetOwnership — success, event, zero address, not-pending-owner, no-transfer; constructor roles; post-accept governance lifecycle |
| `Reentrancy.t.sol` | 3 | Guard fires on re-entrant receive, legitimate release, sequential releases |
| `fuzz/EarnerFuzz.t.sol` | 9 | Reward math, user cap ceiling, epoch boundary, bitmap collision, proposal threshold |
| `fuzz/TargetFuzz.t.sol` | 6 | grantLimit ceiling semantics, balance decrease, full drain, above-balance revert |
| `invariant/EarnerInvariant.t.sol` | 6 | Per-epoch check-in cap, fund user/global cap, total supply = ghost minted |
| `invariant/TokenInvariant.t.sol` | 5 | Supply matches ghost, balances match ghost, sum of balances = totalSupply, votes = balance |

**Total: 144 tests**

### Notable Test Cases

- **`test_FullLifecycle_ReleaseEth`** — earns 200 UPT via 20 check-ins, proposes `releaseEth(carol, 1 ETH)`, votes, queues, waits timelock, executes; asserts `carol.balance` increased and `target.balance` decreased
- **`test_Reentrancy_GuardFires_OnReentrantReceive`** — `ReentrantAttacker` calls back into `releaseEth` from `receive()`; asserts outer call succeeds, inner call is blocked, only 1 ETH released
- **`testFuzz_CheckIn_BitmapNeverCollides`** — fuzzes `(epoch1, epoch2)` with `epoch1 < epoch2`; proves check-in at epoch1 never marks epoch2 as claimed
- **`invariant_TotalSupplyMatchesGhostMinted`** — handler runs 128 000 random calls across checkIn/fund/warpEpoch; asserts `totalSupply == ghost_checkIn + ghost_fund` after every sequence

---

## Security

| Feature | Implementation |
|---------|----------------|
| Reentrancy protection | `ReentrancyGuardTransient` on `UdraEarner`; `ReentrancyGuard` on `UdraCoreTarget.releaseEth` |
| Checks-effects-interactions | Bitmap set and state updated before every mint/transfer |
| No `tx.origin` | All access control uses `msg.sender` only |
| Non-transferable votes | `_update` override reverts any transfer between non-zero addresses |
| Role separation | `EARNER_ROLE` (mint) and `DEFAULT_ADMIN_ROLE` (role management) are independent; configurable admin transfer delay (default 3 days) |
| Timelock authority | Governor queues, timelock owns; no EOA can unilaterally execute proposals |
| Pause controls | `UdraEarner` owner can pause all earning; does not affect governance or treasury directly |
| Custom errors | Gas-efficient, descriptive reverts throughout |
| CEI on all payout paths | `releaseEth` is guarded by `nonReentrant`; fund flow updates state and mints tokens before forwarding ETH, satisfying CEI — `ReentrancyGuardTransient` provides additional protection |

