// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {BaseTest} from "./BaseTest.t.sol";
import {UdraEarner} from "../src/UdraEarner.sol";

/// A contract with no payable fallback to rejects all ETH transfers.
contract EthRejecter {}

/// A contract that can call fundTreasury (forwarding ETH) but has no receive(),
/// so any refund attempt back to it reverts.
contract FundingCallerNoReceive {
    function fund(UdraEarner earner) external payable {
        earner.fundTreasury{value: msg.value}();
    }
    // no receive() — refunds to this address will fail
}

contract UdraEarnerTest is BaseTest {

    function test_Constructor_SetsConfig() public view {
        assertEq(earner.owner(), deployer);
        assertEq(earner.CHECKIN_REWARD(), CHECKIN_REWARD);
        assertEq(earner.FUND_REWARD_PER_UNIT(), FUND_REWARD_PER_UNIT);
        assertEq(earner.FUND_UNIT(), FUND_UNIT);
        assertEq(earner.CHECKIN_GLOBAL_CAP(), CHECKIN_GLOBAL_CAP);
        assertEq(earner.FUND_USER_CAP(), FUND_USER_CAP);
        assertEq(earner.FUND_GLOBAL_CAP(), FUND_GLOBAL_CAP);
        assertEq(earner.EPOCH_LENGTH(), EPOCH_LENGTH);
        assertEq(earner.treasuryWallet(), address(target));
    }

    function test_Constructor_Revert_ZeroAddresses() public {
        // zero treasury
        vm.expectRevert(UdraEarner.NoZeroAddress.selector);
        new UdraEarner(
            token, deployer, CHECKIN_REWARD, FUND_REWARD_PER_UNIT, FUND_UNIT,
            CHECKIN_GLOBAL_CAP, FUND_USER_CAP, FUND_GLOBAL_CAP, EPOCH_LENGTH, address(0)
        );

        // zero admin — OZ Ownable reverts
        vm.expectRevert();
        new UdraEarner(
            token, address(0), CHECKIN_REWARD, FUND_REWARD_PER_UNIT, FUND_UNIT,
            CHECKIN_GLOBAL_CAP, FUND_USER_CAP, FUND_GLOBAL_CAP, EPOCH_LENGTH, address(target)
        );
    }

    function test_Constructor_Revert_InvalidConfig() public {
        // fund user cap exceeds fund global cap
        vm.expectRevert(UdraEarner.InvalidConfig.selector);
        new UdraEarner(
            token, deployer, CHECKIN_REWARD, FUND_REWARD_PER_UNIT, FUND_UNIT,
            CHECKIN_GLOBAL_CAP, FUND_GLOBAL_CAP + 1, FUND_GLOBAL_CAP, EPOCH_LENGTH, address(target)
        );

        // checkin reward exceeds checkin global cap
        vm.expectRevert(UdraEarner.InvalidConfig.selector);
        new UdraEarner(
            token, deployer, CHECKIN_GLOBAL_CAP + 1, FUND_REWARD_PER_UNIT, FUND_UNIT,
            CHECKIN_GLOBAL_CAP, FUND_USER_CAP, FUND_GLOBAL_CAP, EPOCH_LENGTH, address(target)
        );

    }

    function test_Constructor_Revert_ZeroAmounts() public {
        // CHECKIN_REWARD = 0
        vm.expectRevert(UdraEarner.NoZeroAmount.selector);
        new UdraEarner(
            token, deployer, 0, FUND_REWARD_PER_UNIT, FUND_UNIT,
            CHECKIN_GLOBAL_CAP, FUND_USER_CAP, FUND_GLOBAL_CAP, EPOCH_LENGTH, address(target)
        );

        // FUND_REWARD_PER_UNIT = 0
        vm.expectRevert(UdraEarner.NoZeroAmount.selector);
        new UdraEarner(
            token, deployer, CHECKIN_REWARD, 0, FUND_UNIT,
            CHECKIN_GLOBAL_CAP, FUND_USER_CAP, FUND_GLOBAL_CAP, EPOCH_LENGTH, address(target)
        );

        // FUND_UNIT = 0
        vm.expectRevert(UdraEarner.NoZeroAmount.selector);
        new UdraEarner(
            token, deployer, CHECKIN_REWARD, FUND_REWARD_PER_UNIT, 0,
            CHECKIN_GLOBAL_CAP, FUND_USER_CAP, FUND_GLOBAL_CAP, EPOCH_LENGTH, address(target)
        );

        // CHECKIN_GLOBAL_CAP = 0
        vm.expectRevert(UdraEarner.NoZeroAmount.selector);
        new UdraEarner(
            token, deployer, CHECKIN_REWARD, FUND_REWARD_PER_UNIT, FUND_UNIT,
            0, FUND_USER_CAP, FUND_GLOBAL_CAP, EPOCH_LENGTH, address(target)
        );

        // FUND_USER_CAP = 0
        vm.expectRevert(UdraEarner.NoZeroAmount.selector);
        new UdraEarner(
            token, deployer, CHECKIN_REWARD, FUND_REWARD_PER_UNIT, FUND_UNIT,
            CHECKIN_GLOBAL_CAP, 0, FUND_GLOBAL_CAP, EPOCH_LENGTH, address(target)
        );

        // FUND_GLOBAL_CAP = 0
        vm.expectRevert(UdraEarner.NoZeroAmount.selector);
        new UdraEarner(
            token, deployer, CHECKIN_REWARD, FUND_REWARD_PER_UNIT, FUND_UNIT,
            CHECKIN_GLOBAL_CAP, FUND_USER_CAP, 0, EPOCH_LENGTH, address(target)
        );

        // EPOCH_LENGTH = 0
        vm.expectRevert(UdraEarner.NoZeroAmount.selector);
        new UdraEarner(
            token, deployer, CHECKIN_REWARD, FUND_REWARD_PER_UNIT, FUND_UNIT,
            CHECKIN_GLOBAL_CAP, FUND_USER_CAP, FUND_GLOBAL_CAP, 0, address(target)
        );
    }

    // read:
    // 1. `address private token` cost ~2100 gas (cold SLOAD)
    // 2. immutable ~3 gas (baked into bytecode at deploy time)
    //    - not in storage
    function test_Token_IsImmutable_NotInStorage() public view {
        for (uint256 slot = 0; slot < 20; slot++) {
            bytes32 value = vm.load(address(earner), bytes32(slot));
            assertNotEq(
                address(uint160(uint256(value))),
                address(token),
                "TOKEN address found in storage: TOKEN must be immutable, not a storage variable"
            );
        }
    }

    function test_SetConfig_ByOwner_Succeeds() public {
        vm.startPrank(deployer);
    

        address newTreasury = address(0x123);
        vm.expectEmit(true, true, true, true);
        emit UdraEarner.TreasuryWalletUpdated(address(target), newTreasury);
        earner.setTreasuryWallet(newTreasury);
        assertEq(earner.treasuryWallet(), newTreasury);

        vm.stopPrank();
    }

    function test_SetConfig_Revert_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        earner.setTreasuryWallet(address(0x123));
    }

    // Changing the treasury wallet mid-epoch takes effect immediately on the next call - funds routing to new wallet during active funding
    function test_SetTreasuryWallet_MidEpoch_RoutesToNewWallet() public {
        address newWallet = makeAddr("newWallet");

        uint256 fund = FUND_UNIT;
        uint256 oldWalletBefore = address(target).balance;
        // 1. target = wallet-0, epoch 0; fund to wallet-0
        vm.prank(alice);
        earner.fundTreasury{value: fund}();
        assertEq(address(target).balance, oldWalletBefore + fund);
        assertEq(newWallet.balance, 0);

        // 2. target = wallet-1, epoch 0; fund to wallet-1
        vm.prank(deployer);
        earner.setTreasuryWallet(newWallet);

        // 3. target = wallet-1, epoch 0; fund to wallet-1
        vm.prank(bob);
        earner.fundTreasury{value: fund}();
        assertEq(address(target).balance, oldWalletBefore + fund);
        assertEq(newWallet.balance, fund);

        // Token rewards unaffected by treasury change
        assertEq(token.balanceOf(alice), FUND_REWARD_PER_UNIT);
        assertEq(token.balanceOf(bob), FUND_REWARD_PER_UNIT);
    }

    function test_CheckIn_MintsReward() public {
        vm.prank(alice);
        earner.checkIn();
        assertEq(token.balanceOf(alice), CHECKIN_REWARD);
    }

    function test_CheckIn_EmitsEvents() public {
        uint256 epoch = earner.currentEpoch();

        vm.expectEmit(true, false, true, true);
        emit UdraEarner.CheckinClaimed(alice, epoch, CHECKIN_REWARD);

        vm.expectEmit(true, true, true, true);
        emit UdraEarner.PointsEarned(alice, UdraEarner.ActionType.CHECK_IN, epoch, CHECKIN_REWARD);

        vm.prank(alice);
        earner.checkIn();
    }

    function test_CheckIn_AutoDelegatesOnMint() public {
        vm.prank(alice);
        earner.checkIn();
        // token auto-delegates on mint when delegate is unset
        assertEq(token.delegates(alice), alice);
        assertEq(token.getVotes(alice), CHECKIN_REWARD);
    }

    function test_CheckIn_OncePerEpoch_Revert() public {
        vm.startPrank(alice);
        earner.checkIn();
        vm.expectRevert(UdraEarner.NoCapLeft.selector);
        earner.checkIn();
        vm.stopPrank();
    }

    function test_CheckIn_NewEpochAllowsClaim() public {
        uint256 epoch0 = earner.currentEpoch();

        vm.prank(alice);
        earner.checkIn();

        vm.warp(block.timestamp + EPOCH_LENGTH);
        assertEq(earner.currentEpoch(), epoch0 + 1);

        vm.prank(alice);
        earner.checkIn(); // must not revert in new epoch
        assertEq(token.balanceOf(alice), CHECKIN_REWARD * 2);
    }

    function test_CheckIn_GlobalCapEnforced_Revert() public {
        // CHECKIN_GLOBAL_CAP / CHECKIN_REWARD = 500 users exactly fill the cap
        uint256 maxUsers = CHECKIN_GLOBAL_CAP / CHECKIN_REWARD;

        for (uint256 i = 1; i <= maxUsers; i++) {
            address user = vm.addr(i);
            vm.prank(user);
            earner.checkIn();
        }

        address extraUser = vm.addr(maxUsers + 1);
        vm.expectRevert(UdraEarner.NoCapLeft.selector);
        vm.prank(extraUser);
        earner.checkIn();
    }

    function test_CheckIn_GlobalCap_NoOverrun() public {
        // fill cap to the last possible check-in, verify total supply matches exactly
        uint256 maxUsers = CHECKIN_GLOBAL_CAP / CHECKIN_REWARD;

        for (uint256 i = 1; i <= maxUsers; i++) {
            address user = vm.addr(i);
            vm.prank(user);
            earner.checkIn();
        }

        assertEq(token.totalSupply(), CHECKIN_GLOBAL_CAP);

        // 501st reverts — cap is not exceeded
        address extraUser = vm.addr(maxUsers + 1);
        vm.expectRevert(UdraEarner.NoCapLeft.selector);
        vm.prank(extraUser);
        earner.checkIn();

        assertEq(token.totalSupply(), CHECKIN_GLOBAL_CAP);
    }
  
    function test_CheckIn_Paused_Revert() public {
        _pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        earner.checkIn();
    }

    function test_CheckIn_Unpaused_Succeeds() public {
        _pause();
        vm.prank(deployer);
        earner.unpause();

        vm.prank(alice);
        earner.checkIn();
        assertEq(token.balanceOf(alice), CHECKIN_REWARD);
    }

    function test_FundTreasury_RewardMath_OneUnit() public {
        // 0.01 ETH = 1 unit → 100 UDRA
        vm.prank(alice);
        earner.fundTreasury{value: 0.01 ether}();
        assertEq(token.balanceOf(alice), FUND_REWARD_PER_UNIT);
    }

    function test_FundTreasury_RewardMath_TwoUnits() public {
        // 0.02 ETH = 2 units → 200 UDRA
        vm.prank(alice);
        earner.fundTreasury{value: 0.02 ether}();
        assertEq(token.balanceOf(alice), FUND_REWARD_PER_UNIT * 2);
    }

    function test_FundTreasury_FractionalEthFlooredToUnit() public {
        // 0.015 ETH → floor(0.015 / 0.01) = 1 unit → 100 UDRA; 0.005 ETH refunded
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        earner.fundTreasury{value: 0.015 ether}();
        assertEq(token.balanceOf(alice), FUND_REWARD_PER_UNIT);
        // treasury only receives the exact unit amount
        assertEq(address(target).balance, 0.01 ether);
        // excess refunded to alice
        assertEq(alice.balance, aliceBefore - 0.01 ether);
    }

    function test_FundTreasury_RefundsExcessEth() public {
        // send 2.5 units - treasury gets 2 × FUND_UNIT, alice gets 0.5 FUND_UNIT back
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        earner.fundTreasury{value: 0.025 ether}();
        assertEq(token.balanceOf(alice), FUND_REWARD_PER_UNIT * 2);
        assertEq(address(target).balance, 0.02 ether);
        assertEq(alice.balance, aliceBefore - 0.02 ether);
    }

    function test_FundTreasury_TreasuryReceivesEth() public {
        uint256 before = address(target).balance;
        vm.prank(alice);
        earner.fundTreasury{value: 0.01 ether}();
        assertEq(address(target).balance, before + 0.01 ether);
    }

    function test_FundTreasury_BelowUnit_Revert() public {
        vm.expectRevert(UdraEarner.BelowMinimumUnit.selector);
        vm.prank(alice);
        earner.fundTreasury{value: 0.009 ether}();
    }

    function test_FundTreasury_ZeroValue_Revert() public {
        vm.expectRevert(UdraEarner.BelowMinimumUnit.selector);
        vm.prank(alice);
        earner.fundTreasury{value: 0}();
    }

    function test_FundTreasury_UserCapEnforced_Revert() public {
        // 0.1 ETH = 10 units × 100 UDRA = 1000 UDRA = FUND_USER_CAP exactly
        vm.prank(alice);
        earner.fundTreasury{value: 0.1 ether}();
        assertEq(token.balanceOf(alice), FUND_USER_CAP);

        // ecxeeds cap for this epoch
        vm.expectRevert(UdraEarner.NoCapLeft.selector);
        vm.prank(alice);
        earner.fundTreasury{value: 0.01 ether}();
    }

    function test_FundTreasury_UserCapResetsNextEpoch() public {
        vm.prank(alice);
        earner.fundTreasury{value: 0.1 ether}(); // exhaust user cap

        vm.warp(block.timestamp + EPOCH_LENGTH);

        vm.prank(alice);
        earner.fundTreasury{value: 0.01 ether}(); // succeeds in new epoch
        // epoch 1 reward on top of epoch 0
        assertEq(token.balanceOf(alice), FUND_USER_CAP + FUND_REWARD_PER_UNIT);
    }
  
    function test_FundTreasury_GlobalCapEnforced_NoOverrun() public {
        // 10 users × 0.1 ETH = 10 × 1000 UDRA = 10000 UDRA = FUND_GLOBAL_CAP
        uint256 maxUsers = FUND_GLOBAL_CAP / FUND_USER_CAP; // = 10

        for (uint256 i = 1; i <= maxUsers ; i++) {
            address user = vm.addr(i);
            vm.deal(user, 1 ether);
            vm.prank(user);
            earner.fundTreasury{value: 0.1 ether}();
        }

        assertEq(token.totalSupply(), FUND_GLOBAL_CAP);

        // 11th user — global cap exhausted
        address extra = vm.addr(maxUsers);
        vm.deal(extra, 1 ether);
        vm.expectRevert(UdraEarner.NoCapLeft.selector);
        vm.prank(extra);
        earner.fundTreasury{value: 0.01 ether}();

        assertEq(token.totalSupply(), FUND_GLOBAL_CAP);
    }
  
    function test_FundTreasury_EmitsEvents() public {
        uint256 epoch = earner.currentEpoch();

        vm.expectEmit(true, false, false, true);
        emit UdraEarner.TreasuryFunded(alice, 0.01 ether, FUND_REWARD_PER_UNIT);

        vm.expectEmit(true, true, true, true);
        emit UdraEarner.PointsEarned(alice, UdraEarner.ActionType.FUND, epoch, FUND_REWARD_PER_UNIT);

        vm.prank(alice);
        earner.fundTreasury{value: 0.01 ether}();
    }

    function test_FundTreasury_Paused_Revert() public {
        _pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        earner.fundTreasury{value: 0.01 ether}();
    }

    function test_Receive_RoutesToFundTreasury() public {
        uint256 targetBefore = address(target).balance;

        vm.prank(alice);
        (bool ok,) = payable(address(earner)).call{value: 0.01 ether}("");
        assertTrue(ok);

        assertEq(token.balanceOf(alice), FUND_REWARD_PER_UNIT);
        assertEq(address(target).balance, targetBefore + 0.01 ether);
    }

    function test_Receive_Paused_Revert() public {
        _pause();
        vm.prank(alice);
        (bool ok,) = payable(address(earner)).call{value: 0.01 ether}("");
        assertFalse(ok); // reverts inside _fundTreasury, ETH returned
    }

    function test_Fallback_Revert() public {
        vm.prank(alice);
        (bool ok,) = payable(address(earner)).call{value: 0.01 ether}(hex"deadbeef");
        assertFalse(ok);
    }

    function test_CurrentEpoch_ZeroAtDeploy() public view {
        assertEq(earner.currentEpoch(), 0);
    }

    function test_CurrentEpoch_IncrementsAfterOneDay() public {
        vm.warp(block.timestamp + EPOCH_LENGTH);
        assertEq(earner.currentEpoch(), 1);
    }

    function test_CurrentEpoch_MultipleEpochs() public {
        vm.warp(block.timestamp + 5 * EPOCH_LENGTH);
        assertEq(earner.currentEpoch(), 5);
    }

    function test_ClaimedCheckIn_FalseBeforeClaim() public view {
        assertFalse(earner.claimedCheckIn(alice));
    }

    function test_ClaimedCheckIn_TrueAfterClaim() public {
        vm.prank(alice);
        earner.checkIn();
        assertTrue(earner.claimedCheckIn(alice));
    }

    function test_ClaimedCheckIn_FalseInNewEpoch() public {
        vm.prank(alice);
        earner.checkIn();

        vm.warp(block.timestamp + EPOCH_LENGTH);
        assertFalse(earner.claimedCheckIn(alice)); // fresh in epoch 1
    }

    function test_ClaimedCheckIn_Revert_ZeroAddress() public {
        vm.expectRevert(UdraEarner.NoZeroAddress.selector);
        earner.claimedCheckIn(address(0));
    }

    function test_RemainingUserCap_FullAtStart() public view {
        (uint256 checkin, uint256 fund) = earner.remainingUserCap(alice);
        assertEq(checkin, CHECKIN_REWARD); // 1 check-in available
        assertEq(fund, FUND_USER_CAP);
    }

    function test_RemainingUserCap_CheckinDecrementsToZero() public {
        vm.prank(alice);
        earner.checkIn();

        (uint256 checkin,) = earner.remainingUserCap(alice);
        assertEq(checkin, 0);
    }

    function test_RemainingUserCap_FundDecrements() public {
        vm.prank(alice);
        earner.fundTreasury{value: 0.01 ether}(); // 100 UDRA

        (, uint256 fund) = earner.remainingUserCap(alice);
        assertEq(fund, FUND_USER_CAP - FUND_REWARD_PER_UNIT);
    }

    function test_RemainingUserCap_ResetsNextEpoch() public {
        vm.prank(alice);
        earner.checkIn();
        vm.prank(alice);
        earner.fundTreasury{value: 0.1 ether}(); // exhaust fund cap

        vm.warp(block.timestamp + EPOCH_LENGTH);

        (uint256 checkin, uint256 fund) = earner.remainingUserCap(alice);
        assertEq(checkin, CHECKIN_REWARD);
        assertEq(fund, FUND_USER_CAP);
    }

    function test_RemainingGlobalCap_FullAtStart() public view {
        (uint256 checkin, uint256 fund) = earner.remainingGlobalCap();
        assertEq(checkin, CHECKIN_GLOBAL_CAP);
        assertEq(fund, FUND_GLOBAL_CAP);
    }

    function test_RemainingGlobalCap_CheckInDecrements() public {
        vm.prank(alice);
        earner.checkIn();

        (uint256 checkin,) = earner.remainingGlobalCap();
        assertEq(checkin, CHECKIN_GLOBAL_CAP - CHECKIN_REWARD);
    }

    function test_RemainingGlobalCap_FundDecrements() public {
        vm.prank(alice);
        earner.fundTreasury{value: 0.01 ether}();

        (, uint256 fund) = earner.remainingGlobalCap();
        assertEq(fund, FUND_GLOBAL_CAP - FUND_REWARD_PER_UNIT);
    }

    function test_RemainingGlobalCap_ResetsNextEpoch() public {
        vm.prank(alice);
        earner.checkIn();

        vm.warp(block.timestamp + EPOCH_LENGTH);

        (uint256 checkin, uint256 fund) = earner.remainingGlobalCap();
        assertEq(checkin, CHECKIN_GLOBAL_CAP); // fresh in epoch 1
        assertEq(fund, FUND_GLOBAL_CAP);
    }

    function test_Pause_ByOwner_Succeeds() public {
        _pause();
        assertTrue(earner.paused());
    }

    function test_Unpause_ByOwner_Succeeds() public {
        _pause();
        vm.prank(deployer);
        earner.unpause();
        assertFalse(earner.paused());
    }

    function test_Pause_Revert_NotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        earner.pause();
    }

    function test_Unpause_Revert_NotOwner() public {
        _pause();
        vm.expectRevert();
        vm.prank(alice);
        earner.unpause();
    }

    // TREASURY_WALLET (the target) rejects ETH (e.g., if target's receive() is removed)

    // wallet has no receive()
    //  ok=false & _fundTreasury reverts with `FailToFund`
    function test_FundTreasury_Revert_TreasuryRejectsEth() public {
        EthRejecter rejecter = new EthRejecter();

        UdraEarner badEarner = new UdraEarner(
            token, deployer,
            CHECKIN_REWARD, FUND_REWARD_PER_UNIT, FUND_UNIT,
            CHECKIN_GLOBAL_CAP, FUND_USER_CAP, FUND_GLOBAL_CAP,
            EPOCH_LENGTH, address(rejecter)
        );

        vm.prank(deployer);
        token.setEarner(address(badEarner));

        vm.expectRevert(UdraEarner.FailToFund.selector);
        vm.prank(alice);
        uint256 aliceBalanceBefore = alice.balance;
        badEarner.fundTreasury{value: 0.01 ether}();

        assertEq(token.balanceOf(alice), 0); // no tokens minted
        assertEq(alice.balance, aliceBalanceBefore); // no ETH lost
    }

    // caller is an external contract with no receive()
    // msg.value is not a clean multiple of fundUnit (excess > 0)
    // the refund call fails with FailToRefund
    function test_FundTreasury_Revert_SenderCannotReceiveRefund() public {
        FundingCallerNoReceive caller = new FundingCallerNoReceive();
        vm.deal(address(caller), 1 ether);

        // 0.015 ETH = 1 unit forwarded (0.01) + 0.005 ETH refund
        vm.expectRevert(UdraEarner.FailToRefund.selector);
        caller.fund{value: 0.015 ether}(earner);

        // ETH transfer fails, entire tx reverts, no tokens minted
        assertEq(token.balanceOf(address(caller)), 0);
        assertEq(address(target).balance, 0);
    }

    function _pause() internal {
        vm.prank(deployer);
        earner.pause();
    }
}
