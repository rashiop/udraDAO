// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseTest} from "./BaseTest.t.sol";
import {UdraCoreTarget} from "../src/UdraCoreTarget.sol";
import {TimeLock} from "../src/governance_standard/TimelockController.sol";

contract TimelockControllerTest is BaseTest {
    UdraCoreTarget internal pendingTarget;

    function setUp() public override {
        super.setUp();

        // Create a fresh target in pending state to test the acceptance flow
        pendingTarget = new UdraCoreTarget(0, address(this));
        pendingTarget.transferOwnership(address(timelock));
    }

    function test_AcceptTargetOwnership_Success() public {
        assertEq(pendingTarget.owner(), address(this));
        assertEq(pendingTarget.pendingOwner(), address(timelock));

        timelock.acceptTargetOwnership(address(pendingTarget));

        assertEq(pendingTarget.owner(), address(timelock));
        assertEq(pendingTarget.pendingOwner(), address(0));
    }

    function test_AcceptTargetOwnership_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit TimeLock.AcceptTargetOwnership(address(pendingTarget));
        timelock.acceptTargetOwnership(address(pendingTarget));
    }

    function test_AcceptTargetOwnership_Revert_NoPendingTransfer() public {
        UdraCoreTarget directTarget = new UdraCoreTarget(0, address(timelock));
        vm.expectRevert();
        timelock.acceptTargetOwnership(address(directTarget));
    }

    function test_AcceptTargetOwnership_Revert_NotPendingOwner() public {
        // target owned by alice, not timelock
        vm.prank(deployer);
        UdraCoreTarget aliceTarget = new UdraCoreTarget(0, deployer);
        vm.prank(deployer);
        aliceTarget.transferOwnership(alice);

        vm.expectRevert();
        timelock.acceptTargetOwnership(address(aliceTarget));
    }

    function test_AcceptTargetOwnership_Revert_ZeroAddress() public {
        vm.expectRevert(TimeLock.NoZeroAddress.selector);
        timelock.acceptTargetOwnership(address(0));
    }

    function test_AcceptTargetOwnership_ThenReleaseEth_ViaGovernance() public {
        // Complete ownership transfer
        timelock.acceptTargetOwnership(address(pendingTarget));
        vm.deal(address(pendingTarget), 1 ether);
        uint256 carolBefore = carol.balance;

        _earnProposerVotes(alice);

        (address[] memory targets_, uint256[] memory values, bytes[] memory calldatas) =
            _buildCall(address(pendingTarget), abi.encodeCall(pendingTarget.releaseEth, (payable(carol), 1 ether)));

        _runProposal(alice, targets_, values, calldatas, "Release 1 ETH after acceptOwnership");

        assertEq(carol.balance, carolBefore + 1 ether);
    }

    function test_Constructor_RolesAssigned() public view {
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), deployer));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer));
    }

    function test_Constructor_MinDelayCorrect() public view {
        assertEq(timelock.getMinDelay(), TIMELOCK_DELAY);
    }

    // Any address can call acceptTargetOwnership —
    // onlyRoleOrOpenRole(EXECUTOR_ROLE) skips the check on address(0)
    function test_AcceptTargetOwnership_RandomAddress_Succeeds_OpenExecutor() public {
        UdraCoreTarget newTarget = new UdraCoreTarget(0, address(this));
        newTarget.transferOwnership(address(timelock));

        address any = makeAddr("any");
        vm.prank(any);
        timelock.acceptTargetOwnership(address(newTarget));

        assertEq(newTarget.owner(), address(timelock));
        assertEq(newTarget.pendingOwner(), address(0));
    }

    // --------------------------------------------------
    // Helper
    // --------------------------------------------------

    function _buildCall(address target_, bytes memory data)
        internal
        pure
        returns (address[] memory targets_, uint256[] memory values, bytes[] memory calldatas)
    {
        targets_   = new address[](1);
        values     = new uint256[](1);
        calldatas  = new bytes[](1);
        targets_[0]   = target_;
        calldatas[0]  = data;
    }
}
