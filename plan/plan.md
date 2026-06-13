
# udra DAO — Planning Steps
# 1. udra DAO identity

## udra DAO character

udra DAO should be:

* **participation-first**
* **anti-whale**
* **moderately agile**
* **safety-aware for treasury actions**
* **playful for community decisions**

So the model becomes:

### Core governance lane

Serious decisions:

* treasury release
* protocol parameter updates
* anything with value or system impact

Governed by:

* **non-transferable ERC20Votes**
* earned through participation

### Community governance lane

Low-stakes decisions:
* theme
* color
* cosmetic settings
* fun preferences

Governed by:

* **ERC721Votes badges**

This gives udra DAO a nice philosophy:

> **Work and contribution govern important matters.
> Belonging and culture govern expressive matters.**

---

# 2. Numbers and the logic behind them

## A. Epoch design

### Proposal

* **Epoch length: 1 day**

### Why

* check-in makes intuitive sense daily
* easy to test
* easy to explain
* frequent enough to reward ongoing participation

### UDRA behavior effect

* encourages regular activity
* prevents “one-time participation then disappear forever” dynamics

---

## B. ERC20Votes earning model

This token is for **serious governance**.

## Action 1 — Daily check-in

### Proposal

* reward: **10 UDRA Power**
* per-user cap: **1 claim per epoch**
* global cap: **500 claims worth per epoch** = `5000 power`

### Why

* check-in is cheap and sybil-prone
* reward should be small
* cap prevents spam farming

---

## Action 2 — Treasury funding

### Proposal

* reward rate: **100 UDRA Power per 0.01 ETH**
* per-user cap: **1000 UDRA Power per epoch**
* global cap: **10000 UDRA Power per epoch**

### Why

* funding has economic cost, so reward can be larger
* but we still cap it so one whale does not dominate instantly

### Design logic

Check-in rewards **consistency**
Funding rewards **skin in the game**
Caps prevent either one from becoming broken nonsense

---

## C. ERC20Votes transferability

### Proposal

* **non-transferable** to reflects:
  * participation
  * earned reputation
  * commitment
* mint allowed
* burn optional if needed
* transfers blocked
* delegation allowed

---

## D. Core Governor parameters

This governs money / serious state, so it should be slower and stricter.
Assume Sepolia ~12s blocks.

---

### 1. votingDelay

### Deployed value

* **7 200 blocks** (~1 day)

### Why

* gives token holders time to delegate before snapshot is taken
* original 300-block value was too short for async participation; updated to 7200

---

### 2. votingPeriod

### Deployed value

* **50 400 blocks** (~1 week)

### Why

* enough for users in different time zones
* original 14400-block value (~2 days) was updated to 50400 for broader async participation on testnet

---

### 3. proposalThreshold

### Proposal

* **200 UDRA Power**

### Why

* prevents spam proposals
* still reachable by active participants
* does not hand proposal rights only to whales

Example:

* 20 daily check-ins, or
* meaningful treasury contribution, or
* combined participation

---

### 4. quorum

* **4% of current total supply**

Why?
* balances liveness vs safety
* enough participation required so 2 sleepy goblins can’t pass treasury actions alone
* `GovernorVotesQuorumFraction(4)`

---

## E. Timelock delay
* **1 hour** for core timelock
Why?
* enough observation window
* realistic governance safety
* still manageable on testnet

---

## F. ERC721Votes community model

This is for **fun governance**.

### What the NFT represents

* membership / badge / contributor vibe
* symbolic community voice

### Minting ideas

Choose one or two:

* first check-in badge
* donor badge above threshold
* streak badge
* contributor milestone badge

---

## G. Community Governor parameters

Since this only changes cosmetics, it can be lighter and faster.

### Proposal

* `votingDelay = 60 blocks` (~12 min)
* `votingPeriod = 1200 blocks` (~4 hours)
* `proposalThreshold = 1 NFT vote`
* `quorum = small fixed fraction`, e.g. **10%** if supply is small, or use a low quorum fraction like **5%**

### Why

* low-risk decisions should be easy and fun
* more responsive community participation
* strong contrast with core lane

---

# 3. Architecture

## Core lane

### 1. `UdraPowerToken`

**Type:** `ERC20Votes`, non-transferable

Responsibilities:

* stores serious voting power
* supports delegation / checkpoints
* only Earner can mint

---

### 2. `UdraEarner`

Responsibilities:

* handles check-in
* handles donations
* enforces per-user caps
* enforces per-epoch global caps
* emits `PointsEarned`
* optionally mints community NFT on milestones
* pause/unpause

---

### 3. `UdraCoreGovernor`

Responsibilities:

* reads votes from `UdraPowerToken`
* governs serious proposals
* queues through core timelock

---

### 4. `UdraCoreTimelock`

Responsibilities:

* schedules and executes approved serious actions
* owns serious target contracts

---

### 5. `UdraCoreTarget` (was `UdraTreasuryTarget`)

Combined treasury + serious managed target.

Responsibilities:

* receive ETH
* release ETH via timelock only
* update serious parameter(s) via timelock only

Examples:

* `releaseEth(address to, uint256 amount)`
* `setGrantLimit(uint256 newLimit)`

---

## Community lane

### 6. `UdraBadgeNFT`

**Type:** `ERC721Votes`

Responsibilities:

* stores fun/community voting power
* supports delegation
* minted on discrete participation milestones

---

### 7. `UdraCommunityGovernor`

Responsibilities:

* reads votes from badge NFT
* governs cosmetic/community settings

---

### 8. `UdraCommunityTimelock`

Responsibilities:

* executes only harmless community actions

---

### 9. `UdraCommunityTarget`

Responsibilities:

* stores theme / color / cosmetic settings

Examples:

* `setTheme(uint8 themeId)`
* `setAccentColor(bytes32 color)`
* `setBannerId(uint256 bannerId)`

---

# 4. Why this architecture is good

## Why 2 governors

Because **one governance lane should not rule everything**.

Core:

* money
* serious protocol changes

Community:

* fun and expression

This avoids:

* using cosmetic badge holders to move treasury funds
* using high-friction treasury governance for harmless UI decisions

---

## Why Tally

Tally is the interface layer for:

* proposals
* votes
* queue
* execute

It works well with:

* `Governor`
* `TimelockController`
* `ERC20Votes` / `ERC721Votes`

---

## Why vote checkpoints matter

OpenZeppelin Votes tracks historical voting power via checkpoints.

This lets Governor use:

* `getPastVotes(account, snapshotBlock)`

So votes are based on a **proposal snapshot**, not live balances during voting.

That prevents governance weirdness like:

* acquire votes after proposal creation
* shuffle votes around mid-vote

---

# 5. Planning steps to tackle implementation

## Step 0 — Prerequisites [DONE]

* `forge install OpenZeppelin/openzeppelin-contracts --no-commit`
* Add remappings to `foundry.toml`:
  ```
  remappings = ["@openzeppelin/=lib/openzeppelin-contracts/"]
  ```
* Confirm OZ v5 is installed (v5 uses `_update` override pattern, not `_beforeTokenTransfer`)

---

## Step 1 — Lock the design doc ✓ [DONE]
## Step 2 — Build core governance first [DONE]

Implemented:

1. `UdraPowerToken` — `ERC20Votes` + `AccessControlDefaultAdminRules`, non-transferable, auto-self-delegate
2. `UdraEarner` — `checkIn()` + `fundTreasury()`, bitmap tracking, epoch caps, `Ownable2Step` + `Pausable`
3. `UdraCoreTarget` (was `UdraTreasuryTarget`) — `releaseEth` + `setGrantLimit`, `Ownable2Step` transferred to timelock
4. `TimelockController` — OZ wrapper + `acceptTargetOwnership`
5. `UdraCoreGovernor` — OZ Governor stack

Deploy script: `script/DeployUdraCore.s.sol` with constants in `script/ProtocolConfig.sol`.

## Step 3 — Test core lane end-to-end [DONE]

144 tests pass across unit, fuzz, invariant, and reentrancy suites.

Must prove:
* earn votes ✓
* delegate ✓
* propose ✓
* vote ✓
* queue ✓
* execute ✓
* real state change happens ✓

---

## Step 4 — Add community lane [NOT STARTED]

Implement:

1. `UdraBadgeNFT` — `ERC721Votes`, participation milestone minting
2. `UdraCommunityTarget` — cosmetic settings (`setTheme`, `setAccentColor`, etc.)
3. `UdraCommunityTimelock` — short delay (5–10 min)
4. `UdraCommunityGovernor` — reads from badge NFT

Then test:
* mint badge
* delegate
* vote on cosmetic proposal
* execute cosmetic change

---

## Step 5 — Add hardening tests [DONE]

* fuzz earning inputs ✓
* fuzz epoch edges ✓
* reentrancy attack on payout path ✓
* invariants on caps and authorization ✓

---

## Step 6 — Deploy to Sepolia [DONE]

Core lane deployed. Snapshot integration live.

* earn votes ✓
* self delegate ✓
* Snapshot proposal created and voted ✓
* on-chain Governor lifecycle — pending execution tx recording
* record URLs / tx hashes / before-after state — Snapshot URL recorded; execution tx pending

> Note: Governance UI is Snapshot (off-chain signal, gasless voting) + on-chain Governor for execution. Not Tally.

Snapshot space: https://testnet.snapshot.org/#/s-tn:rashiop.eth

After that, community lane if time allows.

---

# 6. Numbers table draft

Here’s a starting set you can use and later tweak.

## Core lane

| Parameter           |                Value | Why                          |
| ------------------- | -------------------: | ---------------------------- |
| Epoch length        |                1 day | easy recurring participation |
| Check-in reward     |             10 power | low-value, anti-spam         |
| Check-in user cap   |          1 per epoch | prevents spam                |
| Check-in global cap |     5000 power/epoch | controls inflation           |
| Donation reward     | 100 power / 0.01 ETH | strong but understandable    |
| Donation user cap   |     1000 power/epoch | anti-whale                   |
| Donation global cap |    10000 power/epoch | inflation control            |
| Voting delay        |          7200 blocks | ~1 day; time to delegate before snapshot |
| Voting period       |         50400 blocks | ~1 week; broad async participation |
| Proposal threshold  |            200 power | blocks spam                  |
| Quorum              |                   4% | safety/liveness balance      |
| Timelock delay      |               1 hour | observable execution delay   |

---

## Community lane
| Parameter          |       Value | Why                       |
| ------------------ | ----------: | ------------------------- |
| Voting delay       |   60 blocks | fast, low-risk            |
| Voting period      | 1200 blocks | quick community decisions |
| Proposal threshold |  1 vote/NFT | inclusive                 |
| Quorum             |          5% | easy participation        |
| Timelock delay     |    5–10 min | enough for flow, low-risk |

---

# 7. Recommendation on scope

## Must-finish

* full core lane ✓ (done)
* Snapshot integration on Sepolia ✓ (done; note: UI is Snapshot, not Tally)

## Nice-to-have

* full community lane (not started)
* second governance demo for NFT-based community proposals

---

# 8. Final planning summary

## udra DAO blueprint

* **Core lane:** participation-earned non-transferable ERC20Votes for serious governance — **DONE**
* **Community lane:** ERC721Votes for fun/cosmetic governance — **NOT STARTED**
* **Two governors:** clean domain separation — core done, community pending
* **Two timelocks:** best separation of authority — core done, community pending
* **One combined treasury target in core lane:** efficient assignment scope — done (`UdraCoreTarget`)
* **On-chain checkpoints:** required for historical voting power — done
* **Snapshot:** off-chain governance signal (gasless voting) + on-chain Governor for execution — **deployed**; space at testnet.snapshot.org/#/s-tn:rashiop.eth
