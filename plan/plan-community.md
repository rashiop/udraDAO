
# udra DAO

## Community Lane

> Build only after core lane tests pass.

Order:

1. `UdraBadgeNFT`
2. `UdraCommunityTarget`
3. `UdraCommunityTimelock`
4. `UdraCommunityGovernor`
5. tests

---

## Design decisions

| Decision | Choice | Reason |
|---|---|---|
| Badge transferability | **non-transferable** | badges represent identity/membership, not tradeable assets |
| Minting model | **pull-based** (user claims) | avoids bidirectional coupling between `UdraEarner` and `UdraBadgeNFT` (PRD OQ-4) |
| Eligibility source | `UdraEarner` view functions (read-only) | one-way dependency; earner never references badge NFT |
| Badge supply | uncapped | symbolic, low risk |
| Badge types | `uint8 badgeType` | 0 = genesis (first check-in), 1 = donor (first donation ≥ threshold) |
| One badge per type per user | yes | `mapping(address => mapping(uint8 => bool)) public hasBadge` |
| Quorum | override with floor of 1 | 5% of small NFT supply rounds to 0 in integer math; floor prevents trivial quorum bypass (PRD OQ-2) |

---

---

## 6. `UdraBadgeNFT`

**Type:** `ERC721Votes`

## Responsibility

* mint community voting badges
* support delegation/checkpoints
* power fun governance

## Minting model — pull-based (PRD OQ-4, resolved)

Users **claim** their badge by calling `claimBadge(uint8 badgeType)`. The badge contract reads eligibility from `UdraEarner` view functions. `UdraEarner` never holds a reference to `UdraBadgeNFT`.

This avoids bidirectional coupling. The dependency is one-way: `UdraBadgeNFT` → reads `UdraEarner`.

Eligibility rules:
* `badgeType = 0` (genesis): user has ever completed at least one check-in → `earner.hasEverCheckedIn(user)`
* `badgeType = 1` (donor): user has ever funded the treasury → `earner.hasEverFunded(user)`

**Required additions to `UdraEarner`:**
```solidity
// new view functions to expose lifetime participation state
function hasEverCheckedIn(address user) external view returns (bool);
function hasEverFunded(address user) external view returns (bool);
```

`hasEverCheckedIn`: scan the user's bitmap across stored epochIndices — or track a `_hasCheckedIn[user]` bool set on first check-in (simpler, recommended).

`hasEverFunded`: track a `_hasEverFunded[user]` bool set on first successful `fundTreasury` call (simpler than scanning epoch mappings).

Do not overcomplicate metadata unless needed.

## Storage

```solidity
uint256 private _nextTokenId;
address public immutable EARNER;                              // set in constructor, immutable
mapping(address => mapping(uint8 => bool)) public hasBadge;  // user → badgeType → claimed
```

`EARNER` is immutable — set once at deploy, cannot be changed. Eliminates a class of admin key risk.

## Key functions

* `claimBadge(uint8 badgeType) external` — pull-based; checks eligibility via earner views; reverts if already claimed
* override `_update(...)` to block transfers (allow mint from address(0), block user-to-user)
* `tokenURI(...)` — return minimal or fixed URI per badgeType; not required for governance

## Key events

* `BadgeClaimed(address indexed to, uint256 indexed tokenId, uint8 indexed badgeType)`

## Delegation note

* call `_delegate(to, to)` inside `_mintBadge` so badge is self-delegated at mint
* otherwise new holders have zero voting power until they explicitly delegate

---

## 7. `UdraCommunityTarget`

**Responsibility**

* harmless community state

## Storage

* `uint256 public theme`
* `bytes32 public accentColor`
* maybe `string` is avoidable; use ids for cheaper state

## Key functions

* `setTheme(uint256 newTheme) external onlyOwner`
* `setAccentColor(bytes32 newColor) external onlyOwner`

## Events

* `ThemeChanged(uint256 oldTheme, uint256 newTheme)`
* `AccentColorChanged(bytes32 oldColor, bytes32 newColor)`

---

## 8. `UdraCommunityTimelock`

Same OZ `TimelockController` pattern as core, with shorter delay.

```solidity
TimelockController(
    minDelay:   300,                          // 5 minutes
    proposers:  [address(communityGovernor)],
    executors:  [address(0)],
    admin:      deployer                      // renounce after setup
)
```

---

## 9. `UdraCommunityGovernor`

Reads votes from `UdraBadgeNFT`.

Config:

* `votingDelay = 60` (~12 min at 12s/block — fast for low-risk decisions)
* `votingPeriod = 1200` (~4 hours)
* `proposalThreshold = 1` (any badge holder can propose)
* `quorumNumerator = 5` (5%)

## Quorum override — floor of 1 (PRD OQ-2, resolved)

`GovernorVotesQuorumFraction` computes `(pastTotalSupply * 5) / 100`. For small badge supplies (e.g. 10 badges), this rounds to 0 — quorum is always trivially met, making the check meaningless.

**Fix:** override `quorum()` in `UdraCommunityGovernor`:

```solidity
function quorum(uint256 blockNumber) public view override returns (uint256) {
    uint256 computed = super.quorum(blockNumber);
    return computed < 1 ? 1 : computed;
}
```

Behavior:
* supply ≤ 20 badges → quorum = 1 (floor applies)
* supply > 20 badges → 5% takes over naturally
* self-calibrating, no manual adjustment needed


---

## Deployment

Order:

1. deploy `UdraBadgeNFT` (constructor arg: `earner = address(UdraEarner)`)
2. deploy `UdraCommunityTarget` (initialOwner = deployer)
3. deploy `UdraCommunityTimelock` (minDelay=300, proposers=[communityGovernor_placeholder], executors=[address(0)], admin=deployer)
4. deploy `UdraCommunityGovernor` (token=UdraBadgeNFT, timelock=UdraCommunityTimelock)
5. transfer ownership of `UdraCommunityTarget` → community timelock (Ownable2Step: timelock must accept)
6. `communityTimelock.grantRole(CANCELLER_ROLE, deployer)` — guardian backstop (same pattern as core)
7. `communityTimelock.renounceRole(DEFAULT_ADMIN_ROLE, deployer)`

> **Removed from previous plan:** Step 7 `UdraEarner.badgeNFT = UdraBadgeNFT` is eliminated. Badge minting is pull-based — `UdraEarner` never references `UdraBadgeNFT`. No bidirectional coupling.

> **`UdraBadgeNFT.EARNER` is immutable** — set in constructor, no `setEarner()` function needed. Eliminates post-deploy admin step and reduces attack surface.

---

## Tests

### `UdraBadgeNFT`

Pull-based minting model — tests reflect `claimBadge()` not `mintBadge()`:

* user who has checked in can claim genesis badge (badgeType 0)
* user who has funded can claim donor badge (badgeType 1)
* user with no participation cannot claim either badge → reverts `NotEligible`
* second claim of same badge type reverts `AlreadyClaimed`
* different badge types allowed per user (can hold both 0 and 1)
* transfers revert (non-transferable)
* delegation auto-set on claim/mint

### `UdraEarner` new view functions

* `hasEverCheckedIn(user)` returns false before any check-in
* `hasEverCheckedIn(user)` returns true after first check-in (persists across epoch boundaries)
* `hasEverFunded(user)` returns false before any funding
* `hasEverFunded(user)` returns true after first successful `fundTreasury`

### `UdraCommunityTarget`

* only owner (community timelock) can call `setTheme` / `setAccentColor`
* events emitted on state change
* non-owner call reverts

### `UdraCommunityGovernor` — quorum floor

* with 1 badge minted: quorum = 1 (floor applies, not 5% = 0)
* with 21 badges minted: quorum = 1 (5% of 21 = 1, floor and fraction agree)
* with 100 badges minted: quorum = 5 (5% takes over)

### `UdraCommunityGovernor` lifecycle

1. user calls `checkIn()` on `UdraEarner`
2. user calls `claimBadge(0)` on `UdraBadgeNFT` → badge minted, auto-delegated
3. user proposes cosmetic change (threshold = 1)
4. roll blocks past `votingDelay` (60)
5. cast vote
6. roll blocks past `votingPeriod` (1200)
7. queue proposal
8. roll time past timelock delay (300s)
9. execute
10. assert theme/color changed on `UdraCommunityTarget`

### Edge cases

* user with 0 badges cannot propose (below threshold = 1)
* quorum not reached → proposal fails
* `claimBadge` with unset eligibility reverts (not just returns false — must not silently mint)
* user delegates to another address → that address can vote; original user cannot