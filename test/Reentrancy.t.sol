// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BaseTest} from "./BaseTest.t.sol";
import {UdraCoreTarget} from "../src/UdraCoreTarget.sol";

// ---------------------------------------------------------------------------
// ReentrantAttacker — absorbs the blocked re-entry via try/catch.
// The outer releaseEth SUCCEEDS (proving ETH was only released once).
// Uses uint256 counters to avoid bool-getter overload resolution issues.
// ---------------------------------------------------------------------------
contract ReentrantAttacker is Ownable {
    UdraCoreTarget public target;
    uint256 public lastAmount;
    uint256 public reentryAttempts; // on receive()
    uint256 public reentryBlocks; // on revert()

    constructor() Ownable(msg.sender) {}

    function setTarget(UdraCoreTarget _target) external onlyOwner {
        target = _target;
    }

    function attack(uint256 amount) external {
        lastAmount = amount;
        target.releaseEth(payable(address(this)), amount);
    }

    receive() external payable {
        if (lastAmount == 0) return;

        reentryAttempts++;
        uint256 amount = lastAmount;
        lastAmount = 0; // avoid infinite loop

        // should not reach here — ReentrancyGuard blocks this
        try target.releaseEth(payable(address(this)), amount) {}
            catch {
            reentryBlocks++;
        }
    }
}

contract ReentrancyTest is BaseTest {
    function test_Reentrancy_GuardFires_OnReentrantReceive() public {
        // attack as owner
        ReentrantAttacker attacker = new ReentrantAttacker();
        UdraCoreTarget treasury = new UdraCoreTarget(0, address(attacker));
        attacker.setTarget(treasury);

        vm.deal(address(treasury), 2 ether);
        // attack: outer releaseEth succeeds, blocked by guard
        attacker.attack(1 ether);
        assertGt(attacker.reentryAttempts(), 0); // reentry was attempted
        assertGt(attacker.reentryBlocks(), 0); // ReentrancyGuard blocked it

        // only 1 ether released — not 2
        assertEq(address(attacker).balance, 1 ether);
        assertEq(address(treasury).balance, 1 ether);
    }

    function test_Reentrancy_LegitimateRelease_Unaffected() public {
        vm.deal(address(target), 2 ether);
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(address(timelock));
        target.releaseEth(payable(alice), 1 ether);

        assertEq(alice.balance, aliceBalanceBefore + 1 ether);
        assertEq(address(target).balance, 1 ether);
    }

    function test_Reentrancy_SequentialReleases_BothSucceed() public {
        vm.deal(address(target), 2 ether);
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(address(timelock));
        target.releaseEth(payable(alice), 1 ether);

        vm.prank(address(timelock));
        target.releaseEth(payable(alice), 1 ether);

        assertEq(alice.balance, aliceBalanceBefore + 2 ether);
        assertEq(address(target).balance, 0);
    }
}
