
# udra DAO

---

## Decimals convention

`UdraPowerToken` uses **18 decimals** (ERC20 default).  
All reward constants and caps must be scaled by `1e18`.

| Constant | Raw value | Solidity literal |
|---|---|---|
| CHECKIN_REWARD | 10 token | `10 ether` |
| FUND_REWARD_PER_UNIT | 100 token | `100 ether` |
| FUND_UNIT | 0.01 ETH | `0.01 ether` |
| CHECKIN_GLOBAL_CAP | 5000 token/epoch | `5000 ether` |
| FUND_USER_CAP | 1000 token/epoch | `1000 ether` |
| FUND_GLOBAL_CAP | 10000 token/epoch | `10_000 ether` |

Governor `proposalThreshold` must be set to `200e18`.

---

## Access control decisions

| Contract | Pattern | Why |
|---|---|---|
| `UdraPowerToken` | `AccessControlDefaultAdminRules` | `EARNER_ROLE` gates minting; 3-day admin transfer delay protects role management |
| `UdraEarner` | `Ownable2Step` + `Pausable` | pause is owner only |
| `UdraCoreTarget` | `Ownable2Step` (transferred to timelock) | timelock is the sole owner after deploy |
| `TimelockController` | OZ `TimelockController` roles | proposer = Governor, executor = open, admin = deployer (then renounce) |
| `UdraCoreGovernor` | OZ Governor stack | no custom access control needed |

---

## Core lane

* `votingDelay = 7200` 1 day
* `votingPeriod = 50_400` 1 week
* `proposalThreshold = 200` 200e18
* `quorum = 4%` 4
* `timelockDelay = 1 hour`

---

# Phase 1 — Core lane

Order:

1. `UdraPowerToken`
2. `UdraEarner`
3. `UdraCoreTarget`
4. `TimelockController`
5. `UdraCoreGovernor`
6. tests for full lifecycle

---

## 1. `UdraPowerToken` [DONE]

**Type:** `ERC20Votes`

## Responsibility

* store governance voting token
* allow delegation
* maintain vote checkpoints
* only Earner contract can mint voting power
* non-transferable (`_update` override blocks transfers between non-zero addresses)
* auto-self-delegates on first mint

## Storage / constants

* token name and symbol
* ERC20Votes checkpoint storage
* `EARNER_ROLE` via AccessControl

## Key functions

* `mint(address to, uint256 amount)` → `EARNER_ROLE` only
* `setEarner(address)` / `revokeEarner(address)` → `DEFAULT_ADMIN_ROLE`
* override `_update` for vote checkpoint integration and transfer block

## Key events

* Standard OZ events + `EarnerGranted(earner)` / `EarnerRevoked(earner)`

## Important implementation notes

Token inherits:

```

ERC20Votes
AccessControlDefaultAdminRules
EIP712

```

`EARNER_ROLE` gates minting. 3-day admin transfer delay on `DEFAULT_ADMIN_ROLE`.

Minting occurs through `UdraEarner`.

Delegation works through standard ERC20Votes functions:

* `delegate`
* `delegateBySig`
* `getVotes`
* `getPastVotes`

## Security / gotchas

* delegation must occur before voting
* minting updates vote checkpoints automatically
* avoid adding unnecessary logic to token

---

## 2. `UdraEarner` [DONE]

**Type:** participation controller / mint gatekeeper

## Responsibility

Users earn voting token through:

* `checkIn()`
* `fundTreasury()`

Contract enforces:

* per-epoch caps
* per-user funding caps
* global reward limits

It also forwards ETH to the treasury wallet.

## Storage

### Core references

```

UdraPowerToken token             (private)
address        treasuryWallet    (public, settable)
uint256        START_TIME        (immutable)
uint256        EPOCH_LENGTH       (immutable)

```

Epoch calculation:

```

epoch = (block.timestamp - START_TIME) / EPOCH_LENGTH

```

### Rewards

```

CHECKIN_REWARD        (immutable)
FUND_REWARD_PER_UNIT  (immutable)
FUND_UNIT             (immutable)

```

Reward formula:

```

units  = msg.value / FUND_UNIT
reward = units * FUND_REWARD_PER_UNIT

```

Reject funding if `msg.value < FUND_UNIT`.

**Refund:** excess ETH beyond `units * FUND_UNIT` is returned to the sender. Treasury only receives the exact `units * FUND_UNIT` amount.

### Caps

```

CHECKIN_GLOBAL_CAP   (immutable)
FUND_GLOBAL_CAP      (immutable)
FUND_USER_CAP        (immutable)

```

Meaning:

* max check-in token per epoch
* max funding token per epoch
* max funding token per user per epoch

### State

Check-in claims tracked using bitmap compression:

```

mapping(address => mapping(uint256 => uint256)) _claimedCheckIn

```

Structure:

```

user -> epochIndex -> bitmap

```

Bitmap logic:

```

epochIndex = epoch >> 8 // divided by 256
bit        = epoch & 255 // modulo by 256
mask       = 1 << bit

```

Funding accounting:

```

mapping(address => mapping(uint256 => uint256)) _userFundingRewards
mapping(uint256 => uint256) _fundUsedPerEpoch
mapping(uint256 => uint256) _checkInUsedPerEpoch

```

Pause state uses OZ `Pausable`.

---

## Key functions

* `currentEpoch() public view returns (uint256)`
* `checkIn() external`
* `fundTreasury() external payable`
* `claimedCheckIn(address user)` view
* `remainingUserCap(address user)` view
* `remainingGlobalCap()` view
* `pause()` / `unpause()`

---

## Key events

```

PointsEarned(address indexed user, ActionType indexed actionType, uint256 indexed epoch, uint256 amount)
TreasuryFunded(address indexed user, uint256 amountEth, uint256 amountToken)
CheckinClaimed(address indexed user, uint256 indexed epoch, uint256 amountToken)

```

---

## Function logic

### `checkIn()`

* require not paused
* compute epoch
* require user has not claimed this epoch
* require global cap not exceeded
* mark bitmap claim
* update epoch usage
* mint voting token
* emit events

---

### `fundTreasury()`

* require not paused
* require `msg.value >= FUND_UNIT`
* compute `units = msg.value / FUND_UNIT`
* compute `reward = units * FUND_REWARD_PER_UNIT`
* enforce user cap
* enforce global cap
* update accounting
* emit events
* mint voting token
* forward `units * FUND_UNIT` ETH to treasury wallet
* refund `msg.value - (units * FUND_UNIT)` to sender if excess

---

## Security notes

* CEI pattern used for funding flow
* `ReentrancyGuardTransient` protects ETH transfer
* no unbounded loops
* funding below `FUND_UNIT` rejected
* pause blocks both earning methods
* cap view functions use saturating subtraction — return 0 instead of reverting if caps are administratively lowered below current usage

---

## Global cap overrun fix (H-1, H-2 from security review)

Both `checkIn()` and `fundTreasury()` had a subtle cap overrun: the cap check passed if remaining cap > 0, but the full reward was always minted even if remaining cap < reward. Last caller in an epoch could push minted tokens over the global cap.

### Fix for `checkIn()`

`_userCheckInCap()` already returns `min(CHECKIN_REWARD, globalCapLeft)`. Use that return value as the actual reward:

```solidity
uint256 reward = _userCheckInCap(msg.sender); // returns capped amount
if (reward == 0) revert NoCapLeft();
```

Mint `reward` (the capped value), not the hardcoded `CHECKIN_REWARD`.

### Fix for `fundTreasury()`

After computing `fundReward`, add an explicit global cap check:

```solidity
if (_fundUsedPerEpoch[epoch] + fundReward > FUND_GLOBAL_CAP) revert NoCapLeft();
```

This ensures the global cap is never exceeded even on the last funding call of an epoch.

## Recommendation

Bitmap tracking is used for check-ins to reduce storage growth across many epochs.

---

## 3. `UdraCoreTarget` [DONE]

**Type:** governed treasury + governed parameter target

## Responsibility

* hold ETH
* allow timelock-only ETH release
* allow timelock-only parameter update
* be the concrete target of governance execution

## Storage

* `uint256 public grantLimit`
* owner / access control for timelock authority

Note:
* Do not keep `uint256 public themeId` to stay serious

## Key functions

* `releaseEth(address payable to, uint256 amount) external onlyOwner nonReentrant`
* `setGrantLimit(uint256 newLimit) external onlyOwner`
* `receive() external payable`

## Key events

* `GrantReleased(address indexed to, uint256 amount)`
* `GrantLimitUpdated(uint256 oldLimit, uint256 newLimit)`

> **Note:** `Received` event was dropped; ETH inflow is tracked by the `receive()` function without an event.

## grantLimit semantics (PRD OQ-1, resolved)

`grantLimit` is a **ceiling** (max per single release), not a floor.

* `grantLimit = 0` → **uncapped** (default at deploy; any governance-approved amount passes)
* `grantLimit = 1 ether` → releases above 1 ETH are rejected

Implementation:
```solidity
// 0 = uncapped; nonzero = max per single release
if (grantLimit != 0 && amount > grantLimit) revert ExceedsGrantLimit();
```

Governance path: deploy with `grantLimit = 0`, then pass a proposal calling `setGrantLimit(x)` to install a ceiling.

Error name is `ExceedsGrantLimit` (not `InsufficientLimit` — old name was ambiguous).

## Important checks

`releaseEth`:

* non-zero recipient → `revert NoZeroAddress()`
* amount > 0 → `revert NoZeroAmount()`
* `amount > address(this).balance` → `revert InsufficientBalance()` (strict `>` so full-balance drain is allowed)
* `grantLimit != 0 && amount > grantLimit` → `revert ExceedsGrantLimit()`

> **Bug history:** original code used `amount <= grantLimit` (inverted) and `balance <= amount` (off-by-one). Both fixed. Wrong error `NoZeroAmount` for address check also fixed to `NoZeroAddress`.

`setGrantLimit`:

* no explicit upper bound — governance is the safety rail

## Security notes

* timelock must own this contract
* payout path uses CEI: checks → effects (emit) → interaction (`.call`)
* `nonReentrant` guards the payout path
* keep this contract boring

---

## 4. `TimelockController` [DONE]

**Type:** `TimelockController`

## Responsibility

* queue approved proposals
* execute after delay
* own the core target

## Constructor args

```solidity
TimelockController(
    minDelay:   1 hours,          // 3600 seconds
    proposers:  [address(coreGovernor)],
    executors:  [address(0)],     // open executor (anyone can execute after delay)
    admin:      deployer          // renounce after setup
)
```

> **Note:** The `TimeLock` wrapper contract previously hardcoded `msg.sender` instead of passing the `admin` param. This is fixed — `admin` is now forwarded correctly. Alternatively, deploy OZ `TimelockController` directly in the script to avoid the wrapper entirely.

## Post-deploy role setup

After deploying all core contracts:

1. `timelock.grantRole(PROPOSER_ROLE, address(governor))` — governor is sole proposer
2. `timelock.grantRole(EXECUTOR_ROLE, address(0))` — open executor (anyone can execute after delay)
3. `target.transferOwnership(timelock)` + `timelock.acceptTargetOwnership(target)` — completes Ownable2Step; timelock is now owner
4. `timelock.renounceRole(PROPOSER_ROLE, deployer)` — removes temporary proposer; only governor can queue
5. `timelock.renounceRole(CANCELLER_ROLE, deployer)` — OZ v5 auto-grants CANCELLER_ROLE to all proposers in constructor; must be explicitly renounced
6. `timelock.renounceRole(DEFAULT_ADMIN_ROLE, deployer)` — remove deployer admin access; fully autonomous

> Renouncing all three roles makes the timelock fully autonomous. No single deployer key can cancel or bypass governance.

## CANCELLER_ROLE (PRD OQ-3, resolved — decision reversed)

**Decision: do NOT retain CANCELLER_ROLE on the deployer key. Renounce it immediately post-deploy.**

Rationale:
* Deployer retaining CANCELLER_ROLE is a centralization risk — single EOA can cancel any queued governance action
* OZ v5 auto-grants CANCELLER_ROLE to every address in the `proposers` constructor array; it is NOT enough to simply not call `grantRole` — the role must be explicitly renounced
* Accepting that there is no emergency cancel is the safer tradeoff for a decentralised DAO
* If emergency cancel is required, it should come from a governance proposal or a pre-deployed multisig with explicit community trust

```solidity
// No explicit grantRole — but must still renounce the auto-granted role:
timelock.renounceRole(CANCELLER_ROLE, deployer);
```

## Open executor note

`executors = [address(0)]` means anyone can trigger execution after the delay. This is intentional for permissionless execution but means front-running is possible. For testnet this is acceptable. Document for mainnet consideration.

`acceptTargetOwnership` uses `onlyRoleOrOpenRole(EXECUTOR_ROLE)` (not `onlyRole`) so that it respects the open-executor pattern — same semantics as the timelock's own `execute()`.

## Gotchas

* transfer ownership of `UdraCoreTarget` to timelock **after** timelock is deployed
* do NOT grant Governor direct ownership of target — always go through timelock
* renounce ALL three deployer roles: `PROPOSER_ROLE`, `CANCELLER_ROLE`, `DEFAULT_ADMIN_ROLE`
* `CANCELLER_ROLE` is **auto-granted** to deployer by OZ v5 constructor (because deployer is in `proposers`); it will not disappear on its own — explicitly renounce it
* deploy script must use `new address[](1)` not bare `address[] memory` to avoid array OOB panic

---

## 5. `UdraCoreGovernor` [DONE]

**Type:** OZ Governor stack

## Inheritance stack

* `Governor` defines how proposals exist
* `GovernorSettings` adjustable governance parameters
* `GovernorCountingSimple` vote counted as For, Against, Abstain
* `GovernorVotes` connects the token to governance
* `GovernorVotesQuorumFraction`
* `GovernorTimelockControl` delays execution

## Responsibility

* read votes from `UdraPowerToken`
* manage proposal lifecycle
* queue/execute through timelock

## Config

* name: `"UdraCoreGovernor"`
* quorum fraction: `4`
* voting delay: `7_200` (~1 day at 12s/block) — updated from original 300 to give delegates more time before snapshot
* voting period: `50_400` (~1 week at 12s/block) — updated from original 14_400 for broader async participation
* proposal threshold: `200e18` ← must match token decimals (18)

## Constructor args

* `IVotes token`
* `TimelockController timelock`

---

# Phase 2 — Core tests [DONE]

All 145 tests pass. Full suite: unit, fuzz, invariant, reentrancy.

| File | Tests | Status |
|------|-------|--------|
| `UdraPowerToken.t.sol` | 21 | done |
| `UdraEarner.t.sol` | 46 | done |
| `UdraCoreTarget.t.sol` | 20 | done |
| `UdraCoreGovernor.t.sol` | 21 | done |
| `TimelockController.t.sol` | 8 | done |
| `Reentrancy.t.sol` | 3 | done |
| `fuzz/EarnerFuzz.t.sol` | 9 | done |
| `fuzz/TargetFuzz.t.sol` | 6 | done |
| `invariant/EarnerInvariant.t.sol` | 6 | done |
| `invariant/TokenInvariant.t.sol` | 5 | done |

---

## A. Token tests [DONE]

### `UdraPowerToken`

Test:

* only earner can mint
* transfers revert
* delegation works
* checkpoints update after mint + delegate

---

## B. Earner tests [DONE]

### `checkIn()`

Test:

* one claim per epoch
* second claim same epoch reverts
* new epoch allows claim
* cap enforced
* points minted correctly

### `fundTreasury()`

Test:

* treasury receives ETH
* reward math correct
* funding below unit rejected
* user cap enforced
* global cap enforced
* paused state blocks action

### views

Test:

* `currentEpoch()`
* `remainingUserCap()`
* `remainingGlobalCap()`

---

## C. Core target tests [DONE]

Test:

* only owner/timelock can call release
* release updates balance correctly
* zero address reverts
* insufficient balance reverts
* setGrantLimit works only by owner

---

## D. Governor lifecycle tests [DONE]

Full flow:

1. user earns token
2. user delegates to self
3. user proposes
4. move blocks past `votingDelay`
5. cast votes
6. move blocks past `votingPeriod`
7. queue proposal
8. move time past timelock delay
9. execute
10. assert real state change

### Must prove

* voting token came from participation
* quorum reached
* state changed on target

---

## E. Reentrancy attack test [DONE]

Create attacker contract targeting `releaseEth`.

Prove:

* reentrant path fails
* legitimate payout succeeds

---

## F. Fuzz tests [DONE]

Fuzz:

* funding amounts
* epoch transitions
* cap edges
* grant amounts
* proposal eligibility

---

## G. Invariant tests [DONE]

Examples:

* funding per user never exceeds user cap
* total funding per epoch never exceeds global cap
* total check-in per epoch never exceeds global cap
* only timelock-owner can mutate target
* token never allows arbitrary transfer

---

# Phase 3 — Community lane

---

# Phase 4 — Deployment roadmap [DONE]

## Deployment order: core lane

1. deploy `UdraPowerToken` (initialOwner = deployer)
2. deploy `UdraCoreTarget` (initialGrantLimit = 0, initialOwner = deployer)
3. deploy `TimelockController` (minDelay=3600, proposers=[governor_placeholder], executors=[address(0)], admin=deployer)
4. deploy `UdraCoreGovernor` (token=UdraPowerToken, timelock=TimelockController)
5. deploy `UdraEarner` (token, admin=deployer, caps/rewards as per constants, treasuryWallet=UdraCoreTarget)
6. `token.setEarner(address(earner))` — grants EARNER_ROLE (deployer holds DEFAULT_ADMIN during 3-day window)
7. `timelock.grantRole(PROPOSER_ROLE, governor)` — governor is sole proposer; no deployer canceller
8. `target.transferOwnership(timelock)` + `timelock.acceptTargetOwnership(target)` — completes Ownable2Step; timelock is now owner
9. `timelock.renounceRole(PROPOSER_ROLE, deployer)` — removes temporary proposer
   `timelock.renounceRole(CANCELLER_ROLE, deployer)` — OZ v5 auto-grants this to proposers; must renounce explicitly
   `timelock.renounceRole(DEFAULT_ADMIN_ROLE, deployer)` — deployer relinquishes admin; fully autonomous

> **3-day window note:** `AccessControlDefaultAdminRules` enforces a 3-day delay on admin transfer. During this window, deployer retains DEFAULT_ADMIN and can grant/revoke EARNER_ROLE. Secure the deployer key. Step 6 (`setEarner`) must be called before the 3-day window closes or before renouncing.

> **Array initialization:** deploy script must use `new address[](1)` for proposers/executors arrays. Bare `address[] memory` is zero-length and panics on index assignment.

## Deployed Addresses (Sepolia)

Deployer: `0x405A10A6c4b207946d81a541DAdc76586719390d`

| Contract | Address |
|----------|---------|
| UdraPowerToken | `0x054D551B18dAA1E53Dd6b7e629A9B50C764453A8` |
| UdraEarner | `0xd70f7F72fa82aBc37b0F25C41c980Dd3c10b7b8F` |
| UdraCoreTarget | `0xe6Eb48629d63E66A80A15ae4210E0F74bb89bE84` |
| TimelockController | `0x51E524024BFee393046B667F5Ba8E663dbEeADC0` |
| UdraCoreGovernor | `0xcD7B4d7eDfDEe8DD468a57479e2D7aaFDf18B7ce` |

## Snapshot (off-chain governance signal)

| Item | Value |
|------|-------|
| Space | https://testnet.snapshot.org/#/s-tn:rashiop.eth |
| Proposal | https://testnet.snapshot.org/#/s-tn:rashiop.eth/proposal/0x1006ce316e3e30248b5c14a385d21929a7c77ea088e4eb54f2a55bc552877400 |
| Strategy | `erc20-votes` on Sepolia — reads `getPastVotes` from UdraPowerToken |
| On-chain execution tx | _(to be recorded after execution)_ |

---

## Smoke test on testnet [DONE]

* call `checkIn()` ✓
* self delegate ✓
* confirm votes visible ✓
* fund treasury ✓
* Snapshot proposal created and voted ✓
* on-chain Governor proposal + execute — pending execution tx

Then community lane if time permits.

---

# Coding Order
### Order of implementation

1. storage / constants
2. constructor
3. modifiers / access control
4. core external functions
5. view helpers
6. events / errors refinement
7. tests immediately after each contract

---

## Milestone 1 [DONE]

Core token + earner done

## Milestone 2 [DONE]

Core target + timelock + governor compile and deploy locally

## Milestone 3 [DONE]

Full core governance lifecycle test passes (144 tests total)

## Milestone 4 [DONE]

Reentrancy + fuzz + invariant tests pass

## Milestone 5 [DONE]

Sepolia deploy + Snapshot space created + proposal submitted

> Note: UI is Snapshot (off-chain signal + on-chain Governor execution), not Tally.

## Milestone 6 [NOT STARTED]

Community lane — `UdraBadgeNFT`, `UdraCommunityGovernor`, `UdraCommunityTimelock`, `UdraCommunityTarget`
