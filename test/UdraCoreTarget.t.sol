// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseTest} from "./BaseTest.t.sol";
import {UdraCoreTarget} from "../src/UdraCoreTarget.sol";

contract UdraCoreTargetTest is BaseTest {
    function test_Constructor_Success() public view {
        assertEq(target.grantLimit(), 0);
        assertEq(target.owner(), address(timelock));
    }

    function test_Constructor_Revert_ZeroOwner() public {
        vm.expectRevert();
        new UdraCoreTarget(0, address(0));
    }

    function test_Receive_AcceptsEth_Success() public {
        uint256 before = address(target).balance;
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = payable(address(target)).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(target).balance, before + 1 ether);
    }

    function test_ReleaseEth_Success() public {
        vm.deal(address(target), 2 ether);
        uint256 recipientBefore = alice.balance;

        vm.prank(address(timelock));
        target.releaseEth(payable(alice), 1 ether);

        assertEq(alice.balance, recipientBefore + 1 ether);
        assertEq(address(target).balance, 1 ether);
    }

    function test_ReleaseEth_EmitsGrantReleased() public {
        vm.deal(address(target), 1 ether);

        vm.prank(address(timelock));
        vm.expectEmit(true, false, false, true);
        emit UdraCoreTarget.GrantReleased(carol, 1 ether);
        target.releaseEth(payable(carol), 1 ether);
    }

    function test_ReleaseEth_FullDrain_Succeeds() public {
        vm.deal(address(target), 1 ether);

        vm.prank(address(timelock));
        target.releaseEth(payable(carol), 1 ether); // amount == balance → allowed

        assertEq(address(target).balance, 0);
    }

    function test_ReleaseEth_GrantLimitZero_Uncapped() public {
        // grantLimit=0 in BaseTest setUp — any amount should pass
        assertEq(target.grantLimit(), 0);
        vm.deal(address(target), 100 ether);

        vm.prank(address(timelock));
        target.releaseEth(payable(carol), 50 ether); // large amount, no cap

        assertEq(address(target).balance, 50 ether);
    }

    function test_ReleaseEth_GrantLimitNonZero_BelowLimit_Succeeds() public {
        vm.prank(address(timelock));
        target.setGrantLimit(2 ether);
        vm.deal(address(target), 5 ether);

        vm.prank(address(timelock));
        target.releaseEth(payable(carol), 1 ether); // 1 ether <= 2 ether limit

        assertEq(address(target).balance, 4 ether);
    }

    function test_ReleaseEth_GrantLimitNonZero_ExactLimit_Succeeds() public {
        vm.prank(address(timelock));
        target.setGrantLimit(1 ether);
        vm.deal(address(target), 5 ether);

        vm.prank(address(timelock));
        target.releaseEth(payable(carol), 1 ether); // exactly at limit

        assertEq(address(target).balance, 4 ether);
    }

    function test_ReleaseEth_Revert_NotOwner() public {
        vm.deal(address(target), 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        target.releaseEth(payable(carol), 1 ether);
    }

    function test_ReleaseEth_Revert_ZeroAddress() public {
        vm.deal(address(target), 1 ether);
        vm.prank(address(timelock));
        vm.expectRevert(UdraCoreTarget.NoZeroAddress.selector);
        target.releaseEth(payable(address(0)), 1 ether);
    }

    function test_ReleaseEth_Revert_ZeroAmount() public {
        vm.deal(address(target), 1 ether);
        vm.prank(address(timelock));
        vm.expectRevert(UdraCoreTarget.NoZeroAmount.selector);
        target.releaseEth(payable(carol), 0);
    }

    function test_ReleaseEth_Revert_InsufficientBalance() public {
        // target has 0.5 ether but we request 1 ether
        vm.deal(address(target), 0.5 ether);
        vm.prank(address(timelock));
        vm.expectRevert(UdraCoreTarget.InsufficientBalance.selector);
        target.releaseEth(payable(carol), 1 ether);
    }

    function test_ReleaseEth_Revert_ExceedsGrantLimit() public {
        vm.prank(address(timelock));
        target.setGrantLimit(1 ether);
        vm.deal(address(target), 5 ether);

        vm.prank(address(timelock));
        vm.expectRevert(UdraCoreTarget.ExceedsGrantLimit.selector);
        target.releaseEth(payable(carol), 2 ether); // 2 > 1 ether limit
    }

    function test_SetGrantLimit_Success() public {
        vm.prank(address(timelock));
        target.setGrantLimit(5 ether);
        assertEq(target.grantLimit(), 5 ether);
    }

    function test_SetGrantLimit_EmitsEvent() public {
        vm.prank(address(timelock));
        vm.expectEmit(false, false, false, true);
        emit UdraCoreTarget.GrantLimitUpdated(0, 5 ether);
        target.setGrantLimit(5 ether);
    }

    function test_SetGrantLimit_Revert_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        target.setGrantLimit(5 ether);
    }

    function test_SetGrantLimit_BackToZero_Uncaps() public {
        // set a limit, then reset to 0 → uncapped again
        vm.startPrank(address(timelock));
        target.setGrantLimit(1 ether);
        target.setGrantLimit(0);
        vm.stopPrank();

        vm.deal(address(target), 10 ether);
        vm.prank(address(timelock));
        target.releaseEth(payable(carol), 5 ether); // should pass now
        assertEq(address(target).balance, 5 ether);
    }

    function test_TransferOwnership_TwoStep_Success() public {
        vm.startPrank(deployer);
        target = new UdraCoreTarget(0, deployer);
        target.transferOwnership(alice);
        vm.stopPrank();

        assertEq(target.pendingOwner(), alice);
        assertEq(target.owner(), deployer); // not transferred yet

        vm.prank(alice);
        target.acceptOwnership();
        assertEq(target.owner(), alice);
    }

    function test_TransferOwnership_Revert_NotPendingOwner() public {
        vm.prank(deployer);
        target = new UdraCoreTarget(0, deployer);
        vm.prank(deployer);
        target.transferOwnership(alice);

        vm.prank(bob);
        vm.expectRevert();
        target.acceptOwnership();
    }
}
