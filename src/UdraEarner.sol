// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {UdraPowerToken} from "./UdraPowerToken.sol";

// TODO
// DAO-4	Earning Voting Power – Users earn votes via funding the Treasury or epoch-based check-ins.
// v a. Enforce per-epoch and per-user caps.
// v b. Mark claimed states using bitmaps/counters.
// v c. Checks paused state.
// v d. Emit PointsEarned.
// DAO-5	Delegation & Views – Users delegate votes to self or others.
// v a. Expose standard OZ events (DelegateChanged, DelegateVotesChanged).
// v b. Provide constant-time views: currentEpoch(), claimedCheckIn(), remainingUserCap(), remainingGlobalCap()
// v c. and token snapshots. ERC20Votes' getPastVotes(account, snapshotBlock)
// DAO-8	Security & Governance Parameters – Use AccessControl for Earner/admin roles.
// v a. CEI pattern on all value transfers & No tx.origin.
// v b. Pause/unpause blocks earning and value-moving functions.
// v c. Document and justify votingDelay, votingPeriod, proposalThreshold, quorum.

contract UdraEarner is Ownable2Step, Pausable, ReentrancyGuardTransient {
    enum ActionType {
        FUND,
        CHECK_IN
    }
    // user -> epochIndex -> bitmap
    mapping(address => mapping(uint256 => uint256)) private _claimedCheckIn;
    mapping(address => mapping(uint256 => uint256)) private _userFundingRewards;
    mapping(uint256 => uint256) private _checkInUsedPerEpoch;
    mapping(uint256 => uint256) private _fundUsedPerEpoch;

    event CheckinClaimed(address indexed user, uint256 indexed epoch, uint256 amountToken);
    event PointsEarned(address indexed user, ActionType indexed actionType, uint256 indexed epoch, uint256 amount);
    event TreasuryFunded(address indexed user, uint256 amountEth, uint256 amountToken);
    event TreasuryWalletUpdated(address indexed oldWallet, address indexed newWallet);

    error BelowMinimumUnit();
    error InvalidConfig();
    error FailToFund();
    error FailToRefund();
    error NoCapLeft();
    error NoZeroAddress();
    error NoZeroAmount();
    error UseFundTreasuryFunction();

    UdraPowerToken private immutable TOKEN;
    uint256 public immutable START_TIME;
    uint256 public immutable EPOCH_LENGTH;
    uint256 public immutable CHECKIN_REWARD;
    uint256 public immutable CHECKIN_GLOBAL_CAP;
    uint256 public immutable FUND_REWARD_PER_UNIT;
    uint256 public immutable FUND_UNIT;
    uint256 public immutable FUND_GLOBAL_CAP;
    uint256 public immutable FUND_USER_CAP;
    address public treasuryWallet;

    constructor(
        UdraPowerToken _token,
        address admin,
        uint256 _checkInReward,
        uint256 _fundRewardPerUnit,
        uint256 _fundUnit,
        uint256 _checkInGlobalCap,
        uint256 _fundUserCap,
        uint256 _fundGlobalCap,
        uint256 _epochLength,
        address _treasuryWallet
    ) Ownable(admin) {
        if (_treasuryWallet == address(0)) revert NoZeroAddress();
        if (admin == address(0)) revert NoZeroAddress();
        if (address(_token) == address(0)) revert NoZeroAddress();

        if (_checkInReward == 0) revert NoZeroAmount();
        if (_fundRewardPerUnit == 0) revert NoZeroAmount();
        if (_fundUnit == 0) revert NoZeroAmount();
        if (_checkInGlobalCap == 0) revert NoZeroAmount();
        if (_fundUserCap == 0) revert NoZeroAmount();
        if (_fundGlobalCap == 0) revert NoZeroAmount();
        if (_epochLength == 0) revert NoZeroAmount();
        if (_fundUserCap > _fundGlobalCap) revert InvalidConfig();
        if (_checkInReward > _checkInGlobalCap) revert InvalidConfig();

        TOKEN = _token;
        CHECKIN_REWARD = _checkInReward;
        FUND_REWARD_PER_UNIT = _fundRewardPerUnit;
        FUND_UNIT = _fundUnit;
        CHECKIN_GLOBAL_CAP = _checkInGlobalCap;
        FUND_USER_CAP = _fundUserCap;
        FUND_GLOBAL_CAP = _fundGlobalCap;
        EPOCH_LENGTH = _epochLength;
        treasuryWallet = _treasuryWallet;

        START_TIME = block.timestamp;
    }

    function setTreasuryWallet(address _treasuryWallet) external onlyOwner {
        if (_treasuryWallet == address(0)) revert NoZeroAddress();

        address oldWallet = treasuryWallet;
        treasuryWallet = _treasuryWallet;

        emit TreasuryWalletUpdated(oldWallet, _treasuryWallet);
    }

    function checkIn() external whenNotPaused nonReentrant {
        if (_userCheckInCap(msg.sender) < CHECKIN_REWARD) revert NoCapLeft();

        uint256 epoch = currentEpoch();
        uint256 epochIndex = epoch >> 8; // divide by 256
        uint256 bit = epoch & 255; // modulo 256
        uint256 mask = uint256(1) << bit;

        _claimedCheckIn[msg.sender][epochIndex] |= mask;

        uint256 reward = CHECKIN_REWARD;
        _checkInUsedPerEpoch[epoch] += reward;

        _mint(msg.sender, reward);

        emit CheckinClaimed(msg.sender, epoch, reward);
        emit PointsEarned(msg.sender, ActionType.CHECK_IN, epoch, reward);
    }

    function fundTreasury() external payable whenNotPaused nonReentrant {
        _fundTreasury(msg.sender, msg.value);
    }

    function _fundTreasury(address from, uint256 value) internal {
        if (from == address(0)) revert NoZeroAddress();
        if (value < FUND_UNIT) revert BelowMinimumUnit();

        uint256 units = value / FUND_UNIT;
        uint256 fundReward = units * FUND_REWARD_PER_UNIT;
        if (_userFundingCap(from) < fundReward) revert NoCapLeft();

        uint256 epoch = currentEpoch();
        _fundUsedPerEpoch[epoch] += fundReward;
        _userFundingRewards[from][epoch] += fundReward;

        _mint(from, fundReward);

        uint256 forwardAmount = units * FUND_UNIT;
        (bool ok,) = payable(treasuryWallet).call{value: forwardAmount}("");
        if (!ok) revert FailToFund();

        uint256 refund = value - forwardAmount;
        if (refund > 0) {
            (ok,) = payable(from).call{value: refund}("");
            if (!ok) revert FailToRefund();
        }

        emit TreasuryFunded(from, value, fundReward);
        emit PointsEarned(from, ActionType.FUND, epoch, fundReward);
    }

    // DAO-5	Delegation & Views – Users delegate votes to self or others.
    // Expose standard OZ events (DelegateChanged, DelegateVotesChanged).
    // Provide constant-time views: currentEpoch(), claimedCheckIn(), remainingUserCap(), remainingGlobalCap(), and token snapshots.
    function currentEpoch() public view returns (uint256) {
        uint256 epoch = (block.timestamp - START_TIME) / EPOCH_LENGTH;
        return epoch;
    }

    function claimedCheckIn(address user) external view returns (bool) {
        if (user == address(0)) revert NoZeroAddress();

        return _claimed(user, currentEpoch());
    }

    function remainingUserCap(address user) external view returns (uint256 checkin, uint256 fund) {
        checkin = _userCheckInCap(user);
        fund = _userFundingCap(user);
        return (checkin, fund);
    }

    function _userFundingCap(address user) internal view returns (uint256) {
        if (user == address(0)) revert NoZeroAddress();

        uint256 epoch = currentEpoch();

        uint256 userReward = _userFundingRewards[user][epoch];
        uint256 userCapLeft = FUND_USER_CAP >= userReward ? FUND_USER_CAP - userReward : 0;

        uint256 fundUsedPerEpoch = _fundUsedPerEpoch[epoch];
        uint256 globalCapLeft = FUND_GLOBAL_CAP >= fundUsedPerEpoch ? FUND_GLOBAL_CAP - fundUsedPerEpoch : 0;

        if (globalCapLeft < userCapLeft) return globalCapLeft;

        return userCapLeft;
    }

    function _userCheckInCap(address user) internal view returns (uint256) {
        if (user == address(0)) revert NoZeroAddress();

        uint256 epoch = currentEpoch();
        uint256 userCapLeft = _claimed(user, epoch) ? 0 : CHECKIN_REWARD;
        uint256 checkInUsed = _checkInUsedPerEpoch[epoch];
        uint256 globalCapLeft = CHECKIN_GLOBAL_CAP >= checkInUsed ? CHECKIN_GLOBAL_CAP - checkInUsed : 0;

        if (globalCapLeft < userCapLeft) return globalCapLeft;
        return userCapLeft;
    }

    function _claimed(address user, uint256 epoch) internal view returns (bool) {
        uint256 epochIndex = epoch >> 8;
        uint256 bit = epoch & 255;
        uint256 mask = uint256(1) << bit;

        return (_claimedCheckIn[user][epochIndex] & mask) != 0;
    }

    function remainingGlobalCap() external view returns (uint256 checkin, uint256 fund) {
        return (_globalCheckInCap(), _globalFundCap());
    }

    function _globalCheckInCap() internal view returns (uint256) {
        uint256 used = _checkInUsedPerEpoch[currentEpoch()];
        return CHECKIN_GLOBAL_CAP > used ? CHECKIN_GLOBAL_CAP - used : 0;
    }

    function _globalFundCap() internal view returns (uint256) {
        uint256 used = _fundUsedPerEpoch[currentEpoch()];
        return FUND_GLOBAL_CAP > used ? FUND_GLOBAL_CAP - used : 0;
    }

    function _mint(address to, uint256 amount) internal {
        if (to == address(0)) revert NoZeroAddress();
        if (amount == 0) revert NoZeroAmount();
        TOKEN.mint(to, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    receive() external payable whenNotPaused nonReentrant{
        _fundTreasury(msg.sender, msg.value);
    }

    fallback() external payable {
        revert UseFundTreasuryFunction();
    }
}
