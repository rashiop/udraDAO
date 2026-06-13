// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseTest} from "./BaseTest.t.sol";
import {UdraCoreTarget} from "../src/UdraCoreTarget.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

contract UdraCoreGovernorTest is BaseTest {
    // Deploy a UdraCoreTarget whose owner is the timelock
    // to avoids acceptOwnership step needed in BaseTest's target
    function _timelockOwnedTarget() internal returns (UdraCoreTarget) {
        return new UdraCoreTarget(0, address(timelock));
    }

    function _singleCall(address target, bytes memory data)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = target;
        calldatas[0] = data;
    }

    function test_Settings() public view {
        assertEq(governor.votingDelay(), VOTING_DELAY);
        assertEq(governor.votingPeriod(), VOTING_PERIOD);
        assertEq(governor.proposalThreshold(), PROPOSAL_THRESHOLD);
        assertEq(governor.quorumNumerator(), 4);
        assertEq(governor.name(), "UdraCoreGovernor");
        assertEq(governor.timelock(), address(timelock));
    }
    function test_Propose_Success() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        _earnProposerVotes(alice);

        (address[] memory targets,, bytes[] memory calldatas) =
            _singleCall(
                address(t), 
                abi.encodeCall(t.setGrantLimit, (1 ether))
            );
        uint256[] memory values = new uint256[](1);

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, "set limit");
        assertTrue(proposalId != 0);
    }

    function test_Propose_StateIsPending() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        _earnProposerVotes(alice);

        (address[] memory targets,, bytes[] memory calldatas) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));
        uint256[] memory values = new uint256[](1);

        vm.prank(alice);
        uint256 id = governor.propose(targets, values, calldatas, "pending");

        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Pending));
    }

    function test_Propose_Revert_BelowThreshold() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        // alice has 0 votes — never earned any
        (address[] memory targets,, bytes[] memory calldatas) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));
        uint256[] memory values = new uint256[](1);

        vm.prank(alice);
        vm.expectRevert();
        governor.propose(targets, values, calldatas, "insufficient votes");
    }

    // --------------------------------------------------
    // State transitions
    // --------------------------------------------------

    function test_State_Active_AfterVotingDelay() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        _earnProposerVotes(alice);

        (address[] memory targets,, bytes[] memory calldatas) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));
        uint256[] memory values = new uint256[](1);

        vm.prank(alice);
        uint256 id = governor.propose(targets, values, calldatas, "active");

        _rollPastDelay();
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Active));
    }

    function test_State_Defeated_NoVotes() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        _earnProposerVotes(alice);

        (address[] memory targets,, bytes[] memory calldatas) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));
        uint256[] memory values = new uint256[](1);

        vm.prank(alice);
        uint256 id = governor.propose(targets, values, calldatas, "defeated");

        _rollPastPeriod(); // nobody voted → quorum not reached
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_State_Succeeded_AfterForVotes() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        _earnProposerVotes(alice);

        (address[] memory targets,, bytes[] memory calldatas) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));
        uint256[] memory values = new uint256[](1);

        vm.prank(alice);
        uint256 id = governor.propose(targets, values, calldatas, "succeeded");

        _rollPastDelay();
        vm.prank(alice);
        governor.castVote(id, 1); // For

        _rollPastPeriod();
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function test_State_Queued_AfterQueue() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        _earnProposerVotes(alice);

        (address[] memory targets,, bytes[] memory calldatas) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));
        uint256[] memory values = new uint256[](1);
        string memory desc = "queued";

        vm.prank(alice);
        uint256 id = governor.propose(targets, values, calldatas, desc);

        _rollPastDelay();
        vm.prank(alice);
        governor.castVote(id, 1);
        _rollPastPeriod();
        governor.queue(targets, values, calldatas, keccak256(bytes(desc)));

        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Queued));
    }

    function test_CastVote_For_Success() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        _earnProposerVotes(alice);

        (address[] memory targets,, bytes[] memory calldatas) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));
        uint256[] memory values = new uint256[](1);

        vm.prank(alice);
        uint256 id = governor.propose(targets, values, calldatas, "vote");
        _rollPastDelay();

        vm.prank(alice);
        governor.castVote(id, 1); // For

        (uint256 against, uint256 forVotes, uint256 abstain) = governor.proposalVotes(id);
        assertEq(forVotes, PROPOSAL_THRESHOLD); // 200e18 votes
        assertEq(against, 0);
        assertEq(abstain, 0);
    }

    function test_CastVote_Against_Success() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        _earnProposerVotes(alice);

        (address[] memory targets,, bytes[] memory calldatas_) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));
        uint256[] memory values = new uint256[](1);

        vm.prank(alice);
        uint256 id = governor.propose(targets, values, calldatas_, "vote");
        _rollPastDelay();

        vm.prank(alice);
        governor.castVote(id, 0); // Against

        (uint256 against,,) = governor.proposalVotes(id);
        assertEq(against, PROPOSAL_THRESHOLD);
    }

    function test_CastVote_Abstain_Success() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        _earnProposerVotes(alice);

        (address[] memory targets,, bytes[] memory calldatas_) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));
        uint256[] memory values = new uint256[](1);

        vm.prank(alice);
        uint256 id = governor.propose(targets, values, calldatas_, "vote");
        _rollPastDelay();

        vm.prank(alice);
        governor.castVote(id, 2); // Abstain

        (,, uint256 abstain) = governor.proposalVotes(id);
        assertEq(abstain, PROPOSAL_THRESHOLD);
    }

    function test_CastVote_Revert_NotActive() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        _earnProposerVotes(alice);

        (address[] memory targets,, bytes[] memory calldatas_) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));
        uint256[] memory values = new uint256[](1);

        vm.prank(alice);
        uint256 id = governor.propose(targets, values, calldatas_, "early vote");

        // still Pending — voting hasn't opened yet
        vm.prank(alice);
        vm.expectRevert();
        governor.castVote(id, 1);
    }

    function test_CastVote_Revert_AlreadyVoted() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        _earnProposerVotes(alice);

        (address[] memory targets,, bytes[] memory calldatas) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));
        uint256[] memory values = new uint256[](1);

        vm.prank(alice);
        uint256 id = governor.propose(targets, values, calldatas, "dup vote");
        _rollPastDelay();

        vm.prank(alice);
        governor.castVote(id, 1);

        vm.prank(alice);
        vm.expectRevert();
        governor.castVote(id, 1);
    }

    function test_Quorum_Value_IsCorrect() public {
        _earnProposerVotes(alice); // mints 200e18 → total supply = 200e18

        UdraCoreTarget t = _timelockOwnedTarget();
        (address[] memory targets_,, bytes[] memory calldatas) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));
        uint256[] memory values = new uint256[](1);

        vm.prank(alice);
        uint256 id = governor.propose(targets_, values, calldatas, "q");

        _rollPastDelay(); // now past snapshot block

        uint256 snap = governor.proposalSnapshot(id);
        uint256 q = governor.quorum(snap);
        assertEq(q, (200 ether * 4) / 100); // 4% of 200e18 = 8e18
    }

    function test_Cancel_ByProposer_Success() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        _earnProposerVotes(alice);

        (address[] memory targets_,, bytes[] memory calldatas) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));
        uint256[] memory values = new uint256[](1);
        string memory desc = "cancel me";

        vm.prank(alice);
        uint256 id = governor.propose(targets_, values, calldatas, desc);

        vm.prank(alice);
        governor.cancel(targets_, values, calldatas, keccak256(bytes(desc)));

        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Canceled));
    }

    function test_Cancel_Revert_NotProposer() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        _earnProposerVotes(alice);

        (address[] memory targets_,, bytes[] memory calldatas) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));
        uint256[] memory values = new uint256[](1);
        string memory desc = "cancel attempt";

        vm.prank(alice);
        governor.propose(targets_, values, calldatas, desc);

        // bob is not the proposer and alice still has votes -> revert
        vm.prank(bob);
        vm.expectRevert();
        governor.cancel(targets_, values, calldatas, keccak256(bytes(desc)));
    }

    function test_Execute_Revert_TimelockNotExpired() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        _earnProposerVotes(alice);

        (address[] memory targets_,, bytes[] memory calldatas) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));
        uint256[] memory values = new uint256[](1);
        string memory desc = "timelock test";

        vm.prank(alice);
        uint256 id = governor.propose(targets_, values, calldatas, desc);
        _rollPastDelay();
        vm.prank(alice);
        governor.castVote(id, 1);
        _rollPastPeriod();
        governor.queue(targets_, values, calldatas, keccak256(bytes(desc)));

        // attempt execute immediately — timelock delay not elapsed
        vm.expectRevert();
        governor.execute(targets_, values, calldatas, keccak256(bytes(desc)));
    }

    function test_FullLifecycle_SetGrantLimit() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        _earnProposerVotes(alice);
        assertEq(t.grantLimit(), 0);

        (address[] memory targets_, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));

        _runProposal(alice, targets_, values, calldatas, "Set grant limit to 1 ether");

        assertEq(t.grantLimit(), 1 ether);
    }

    function test_FullLifecycle_ReleaseEth() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        vm.deal(address(t), 2 ether);
        _earnProposerVotes(alice);
        uint256 carolBefore = carol.balance;

        (address[] memory targets_, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(t), abi.encodeCall(t.releaseEth, (payable(carol), 1 ether)));

        _runProposal(alice, targets_, values, calldatas, "Release 1 ETH to carol");

        assertEq(carol.balance, carolBefore + 1 ether);
        assertEq(address(t).balance, 1 ether);
    }

    function test_FullLifecycle_StateIsExecuted() public {
        UdraCoreTarget t = _timelockOwnedTarget();
        _earnProposerVotes(alice);

        (address[] memory targets_, uint256[] memory values, bytes[] memory calldatas) =
            _singleCall(address(t), abi.encodeCall(t.setGrantLimit, (1 ether)));
        string memory desc = "exec state check";

        uint256 id = _runProposal(alice, targets_, values, calldatas, desc);

        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Executed));
    }


    function test_VotesComeFromParticipation() public {
        // confirm alice earned votes via checkIn, not free allocation
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.getVotes(alice), 0);

        _earnProposerVotes(alice);

        assertEq(token.balanceOf(alice), PROPOSAL_THRESHOLD); // 200e18 from 20 check-ins
        assertEq(token.getVotes(alice), PROPOSAL_THRESHOLD);
    }
}
