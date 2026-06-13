// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseTest} from "../BaseTest.t.sol";
import {UdraCoreTarget} from "../../src/UdraCoreTarget.sol";

contract TargetFuzzTest is BaseTest {
    /// If grantLimit > 0: amount > limit reverts
    /// Else if amount <= limit succeeds.
    function testFuzz_GrantLimit(uint128 limit, uint128 amount) public {
        vm.assume(limit > 0);
        vm.assume(amount > 0);

        vm.prank(address(timelock));
        target.setGrantLimit(limit);
        vm.deal(address(target), uint256(amount) + 1 ether);

        if (amount > limit) {
            vm.prank(address(timelock));
            vm.expectRevert(UdraCoreTarget.ExceedsGrantLimit.selector);
            target.releaseEth(payable(grantee), amount);
        } else {
            vm.prank(address(timelock));
            target.releaseEth(payable(grantee), amount);
            assertEq(grantee.balance, amount);
        }
    }

    function testFuzz_GrantLimit_Zero_AlwaysUncapped(uint96 amount) public {
        vm.assume(amount > 0);
        assertEq(target.grantLimit(), 0);

        vm.deal(address(target), uint256(amount));

        vm.prank(address(timelock));
        target.releaseEth(payable(grantee), amount);
        assertEq(grantee.balance, amount);
        assertEq(address(target).balance, 0);
    }

    function testFuzz_ReleaseEth_BalanceDecreasesExactly(uint96 amount) public {
        vm.assume(amount > 0);
        vm.deal(address(target), uint256(amount) + 1 ether);
        uint256 before = address(target).balance;

        vm.prank(address(timelock));
        target.releaseEth(payable(grantee), amount);

        assertEq(address(target).balance, before - amount);
        assertEq(grantee.balance, amount);
    }

    /// Full drain (amount == balance) always succeeds with grantLimit=0
    function testFuzz_ReleaseEth_FullDrain_Succeeds(uint96 balance_) public {
        vm.assume(balance_ > 0);
        vm.deal(address(target), balance_);

        vm.prank(address(timelock));
        target.releaseEth(payable(grantee), balance_);

        assertEq(address(target).balance, 0);
        assertEq(grantee.balance, balance_);
    }

    /// Amount strictly above balance always reverts with InsufficientBalance.
    function testFuzz_ReleaseEth_AboveBalance_Reverts(uint96 balance_, uint96 extra) public {
        vm.assume(extra > 0);
        uint256 amount = uint256(balance_) + extra; // > balance_
        vm.assume(amount <= type(uint128).max); // prevent overflow

        vm.deal(address(target), balance_);

        vm.prank(address(timelock));
        vm.expectRevert(UdraCoreTarget.InsufficientBalance.selector);
        target.releaseEth(payable(grantee), amount);
    }

    function testFuzz_SetGrantLimit_StoresValue(uint256 limit) public {
        vm.prank(address(timelock));
        target.setGrantLimit(limit);
        assertEq(target.grantLimit(), limit);
    }
}
