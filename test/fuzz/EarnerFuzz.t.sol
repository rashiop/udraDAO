// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseTest} from "../BaseTest.t.sol";

contract EarnerFuzzTest is BaseTest {
    /// reward = floor(amount / FUND_UNIT) * FUND_REWARD_PER_UNIT
    /// capped at FUND_USER_CAP
    // bound amount so reward wont revert with NoCapLeft
    function testFuzz_FundTreasury_Reward(uint96 amount) public {
        // max amount within user cap
        uint256 maxAmount = FUND_USER_CAP * FUND_UNIT / FUND_REWARD_PER_UNIT;
        amount = uint96(bound(amount, FUND_UNIT, maxAmount));

        vm.deal(alice, amount);
        vm.prank(alice);
        earner.fundTreasury{value: amount}();

        uint256 units = amount / FUND_UNIT;
        uint256 expectedReward = units * FUND_REWARD_PER_UNIT;
        assertEq(token.balanceOf(alice), expectedReward);
    }

    /// If succeeds, token balance GTE user cap
    function testFuzz_FundTreasury_BalanceWithinUserCap(uint96 amount) public {
        amount = uint96(bound(amount, FUND_UNIT, 100 ether));
        vm.deal(alice, amount);

        vm.prank(alice);
        try earner.fundTreasury{value: amount}() {
            assertLe(token.balanceOf(alice), FUND_USER_CAP);
        } catch {
            // expected to revert when reward exceeds cap — acceptable
        }
    }

    /// Treasury receives exactly units * FUND_UNIT; excess refunded to sender
    function testFuzz_FundTreasury_TreasuryReceivesExactUnits(uint96 amount) public {
        amount = uint96(bound(amount, FUND_UNIT, 1 ether));
        uint256 maxAmount = FUND_USER_CAP * FUND_UNIT / FUND_REWARD_PER_UNIT;
        vm.assume(amount <= maxAmount);

        vm.deal(alice, amount);
        uint256 treasuryBefore = address(target).balance;
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        earner.fundTreasury{value: amount}();

        uint256 units = amount / FUND_UNIT;
        uint256 forwardAmount = units * FUND_UNIT;
        uint256 refund = amount - forwardAmount;

        assertEq(address(target).balance, treasuryBefore + forwardAmount);
        assertEq(alice.balance, aliceBefore - forwardAmount);
        if (refund > 0) {
            assertEq(alice.balance, aliceBefore - forwardAmount);
        }
    }

    /// amount less than FUND_UNIT reverts
    function testFuzz_FundTreasury_BelowUnit_Reverts(uint96 amount) public {
        amount = uint96(bound(amount, 1, FUND_UNIT - 1));
        vm.deal(alice, amount);

        vm.prank(alice);
        vm.expectRevert();
        earner.fundTreasury{value: amount}();
    }

    /// checkin at any epoch works
    /// uint16 to keep timestamps within safe range.
    function testFuzz_CheckIn_EpochBoundary(uint16 epochOffset) public {
        // cache base before any warp —> block.timestamp is stale inside loops
        uint256 base = block.timestamp;
        vm.warp(base + uint256(epochOffset) * EPOCH_LENGTH);

        assertFalse(earner.claimedCheckIn(alice));
        vm.prank(alice);
        earner.checkIn();
        assertTrue(earner.claimedCheckIn(alice));
    }

    /// checkin at epoch1 wont mark epoch2 as claimed
    function testFuzz_CheckIn_BitmapNeverCollides(uint16 epoch1, uint16 epoch2) public {
        vm.assume(epoch1 < epoch2); // forward warp only

        uint256 base = block.timestamp;

        vm.warp(base + uint256(epoch1) * EPOCH_LENGTH);
        vm.prank(alice);
        earner.checkIn();

        vm.warp(base + uint256(epoch2) * EPOCH_LENGTH);
        assertFalse(earner.claimedCheckIn(alice), "epoch2 shouldnt claimed");
    }

    /// Double checkin in the same epoch will reverts
    function testFuzz_CheckIn_DoubleClaimReverts(uint16 epochOffset) public {
        uint256 base = block.timestamp;
        vm.warp(base + uint256(epochOffset) * EPOCH_LENGTH);

        vm.prank(alice);
        earner.checkIn();

        vm.prank(alice);
        vm.expectRevert();
        earner.checkIn();
    }

    /// epoch = floor((timestamp - START_TIME) / EPOCH_LENGTH)
    function testFuzz_CurrentEpoch_Correct(uint32 secondsElapsed) public {
        uint256 base = block.timestamp;
        vm.warp(base + secondsElapsed);
        uint256 expectedEpoch = secondsElapsed / EPOCH_LENGTH;
        assertEq(earner.currentEpoch(), expectedEpoch);
    }

    /// proposer needs minimal 20 checkin
    function testFuzz_CheckIn_ProposalThreshold(uint8 checkins) public {
        checkins = uint8(bound(checkins, 0, 25));

        uint256 base = block.timestamp;
        for (uint256 i = 0; i < checkins; i++) {
            vm.warp(base + (i + 1) * EPOCH_LENGTH);
            vm.prank(alice);
            earner.checkIn();
        }
        vm.roll(block.number + 1);

        uint256 votes = token.getVotes(alice);
        assertEq(votes, uint256(checkins) * CHECKIN_REWARD);

        if (checkins >= 20) {
            assertGe(votes, PROPOSAL_THRESHOLD);
        } else {
            assertLt(votes, PROPOSAL_THRESHOLD);
        }
    }
}
