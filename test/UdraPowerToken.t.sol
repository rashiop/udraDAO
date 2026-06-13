// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseTest} from "./BaseTest.t.sol";
import {UdraPowerToken} from "../src/UdraPowerToken.sol";
import {UdraEarner} from "../src/UdraEarner.sol";

contract UdraPowerTokenTest is BaseTest {
    function test_Constructor_Success() public view {
        assertEq(token.name(), TOKEN_NAME);
        assertEq(token.symbol(), TOKEN_SYMBOL);
        assertEq(token.defaultAdmin(), deployer);
        assertEq(token.defaultAdminDelay(), ADMIN_TRANSFER_DELAY);
    }

    function test_Constructor_Revert_EmptyOwner() public {
        vm.expectRevert();
        new UdraPowerToken(address(0), TOKEN_NAME, TOKEN_SYMBOL, ADMIN_TRANSFER_DELAY);
    }

    function test_Constructor_Revert_InvalidTokenName() public {
        vm.expectRevert(UdraPowerToken.InvalidTokenName.selector);
        new UdraPowerToken(deployer, "", TOKEN_SYMBOL, ADMIN_TRANSFER_DELAY);
    }

    function test_Constructor_Revert_InvalidTokenSymbol() public {
        vm.expectRevert(UdraPowerToken.InvalidTokenSymbol.selector);
        new UdraPowerToken(deployer, TOKEN_NAME, "", ADMIN_TRANSFER_DELAY);
    }

    function test_SetEarner_ByAdmin_Success() public {
        vm.prank(deployer);
        vm.expectEmit(true, false, false, true);
        emit UdraPowerToken.EarnerGranted(alice);
        token.setEarner(alice);
        assertTrue(token.hasRole(token.EARNER_ROLE(), alice));
    }

    function test_SetEarner_Revert_NoZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(UdraPowerToken.NoZeroAddress.selector);
        token.setEarner(address(0));
    }

    function test_SetEarner_Revert_Unauthorized() public {
        vm.prank(bob);
        vm.expectRevert();
        token.setEarner(alice);
    }

    function test_RevokeEarner_Success() public {
        vm.startPrank(deployer);
        token.setEarner(alice);
        vm.expectEmit(true, false, false, true);
        emit UdraPowerToken.EarnerRevoked(alice);
        token.revokeEarner(alice);
        vm.stopPrank();

        uint256 mintAmount = 10 ether;
        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, mintAmount);
    }

    function test_RevokeEarner_Revert_NoZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(UdraPowerToken.NoZeroAddress.selector);
        token.revokeEarner(address(0));
    }

    function test_EvokeEarner_Revert_Unauthorized() public {
        vm.prank(deployer);
        token.setEarner(alice);

        vm.prank(bob);
        vm.expectRevert();
        token.revokeEarner(alice);
    }

    function test_Mint_ByEarner_Success() public {
        vm.prank(deployer);
        token.setEarner(alice);

        uint256 mintAmount = 10 ether;
        uint256 aliceBalanceBefore = token.balanceOf(alice);
        uint256 aliceBalanceExpected = aliceBalanceBefore + mintAmount;

        vm.prank(alice);
        token.mint(alice, mintAmount);
        assertEq(token.balanceOf(alice), aliceBalanceExpected);
    }

    function test_Mint_AutoDelegateOnFirstMint_Success() public {
        vm.prank(deployer);
        token.setEarner(alice);

        uint256 mintAmount = 10 ether;
        vm.prank(alice);
        token.mint(alice, mintAmount);
        assertTrue(token.delegates(alice) == alice);
        assertEq(token.getVotes(alice), mintAmount);
    }

    function test_Mint_PreservesExplicitDelegation_Success() public {
        vm.prank(deployer);
        token.setEarner(alice);

        uint256 mintAmount = 10 ether;

        vm.startPrank(alice);
        token.mint(alice, mintAmount);
        token.delegate(bob);
        assertEq(token.getVotes(bob), mintAmount);
        token.mint(alice, mintAmount);
        vm.stopPrank();

        assertTrue(token.delegates(alice) == bob);
        assertEq(token.getVotes(alice), 0);
    }

    function test_Mint_Revert_Unauthorized() public {
        vm.prank(deployer);
        token.setEarner(alice);

        vm.prank(bob);
        vm.expectRevert();
        uint256 mintAmount = 10 ether;
        token.mint(bob, mintAmount);
    }

    function test_TransferFrom_Revert_TransfersDisabled() public {
        vm.prank(deployer);
        token.setEarner(alice);

        uint256 mintAmount = 10 ether;
        vm.prank(alice);
        token.mint(alice, mintAmount);

        vm.prank(alice);
        token.approve(bob, mintAmount);

        vm.prank(bob);
        vm.expectRevert(UdraPowerToken.TransfersDisabled.selector);
        bool ok = token.transferFrom(alice, bob, mintAmount);
        assertFalse(ok);
    }

    function test_TransferToken_Revert_TransfersDisabled() public {
        vm.prank(deployer);
        token.setEarner(alice);

        uint256 mintAmount = 10 ether;

        vm.startPrank(alice);
        token.mint(alice, mintAmount);
        vm.expectRevert(UdraPowerToken.TransfersDisabled.selector);
        bool ok = token.transfer(bob, mintAmount);
        assertFalse(ok);
        vm.stopPrank();
    }

    function test_TransferOwnership_Success() public {
        vm.prank(deployer);
        token.beginDefaultAdminTransfer(alice);

        vm.warp(block.timestamp + ADMIN_TRANSFER_DELAY + 1 seconds);
        vm.prank(alice);
        token.acceptDefaultAdminTransfer();

        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), alice));
    }

    function test_TransferOwnership_Revert_NotAdmin() public {
        vm.prank(bob);
        vm.expectRevert();
        token.beginDefaultAdminTransfer(alice);
    }

    function test_TransferOwnership_Revert_NotTarget() public {
        vm.prank(deployer);
        token.beginDefaultAdminTransfer(alice);

        vm.prank(bob);
        vm.expectRevert();
        token.acceptDefaultAdminTransfer();
    }

    function test_Checkpoints_GetPastVotesSnapshot() public {
        vm.prank(deployer);
        token.setEarner(alice);

        vm.roll(10); // pin to a known block before minting

        uint256 mintAmount = 10 ether;
        vm.prank(alice);
        token.mint(alice, mintAmount);

        vm.roll(11); // advance past the checkpoint block

        assertEq(token.getPastVotes(alice, 10), mintAmount);
    }

    /// multiple earner contracts are granted EARNER_ROLE simultaneously

    // 2 earner that track their own per-epoch caps independently
    // A user can earn from both in the same epoch
    function test_MultipleEarners_IndependentCapsAndMint() public {
        UdraEarner earner2 = new UdraEarner(
            token,
            deployer,
            CHECKIN_REWARD,
            FUND_REWARD_PER_UNIT,
            FUND_UNIT,
            CHECKIN_GLOBAL_CAP,
            FUND_USER_CAP,
            FUND_GLOBAL_CAP,
            EPOCH_LENGTH,
            address(target)
        );

        vm.prank(deployer);
        token.setEarner(address(earner2));

        // in same epoch, alice can earn from both
        // 1. from the earner1
        vm.prank(alice);
        earner.checkIn();
        assertEq(token.balanceOf(alice), CHECKIN_REWARD);

        // 2. from earner2
        vm.prank(alice);
        earner2.checkIn();
        assertEq(token.balanceOf(alice), CHECKIN_REWARD * 2);

        assertEq(token.totalSupply(), CHECKIN_REWARD * 2);
    }

    /// multiple earner contracts are granted EARNER_ROLE simultaneously
    function test_MultipleEarners_RevokeOne_OtherUnaffected() public {
        UdraEarner earner2 = new UdraEarner(
            token,
            deployer,
            CHECKIN_REWARD,
            FUND_REWARD_PER_UNIT,
            FUND_UNIT,
            CHECKIN_GLOBAL_CAP,
            FUND_USER_CAP,
            FUND_GLOBAL_CAP,
            EPOCH_LENGTH,
            address(target)
        );

        vm.startPrank(deployer);
        token.setEarner(address(earner2));
        // revoke the original earner
        token.revokeEarner(address(earner));
        vm.stopPrank();

        // original earner can no longer mint
        vm.prank(alice);
        vm.expectRevert();
        earner.checkIn();

        // earner2 still works
        vm.prank(bob);
        earner2.checkIn();
        assertEq(token.balanceOf(bob), CHECKIN_REWARD);
    }

    function test_Checkpoints_GetPastVotes_BeforeMint() public {
        // snapshot at block 10 — no tokens minted yet
        vm.roll(10);

        vm.prank(deployer);
        token.setEarner(alice);

        vm.roll(11); // advance
        vm.prank(alice);
        token.mint(alice, 10 ether); // minted at block 11, after snapshot

        assertEq(token.getPastVotes(alice, 10), 0);
    }

}
