// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {ProtocolConfig} from "../script/ProtocolConfig.sol";
import {UdraPowerToken} from "../src/UdraPowerToken.sol";
import {UdraEarner} from "../src/UdraEarner.sol";
import {UdraCoreTarget} from "../src/UdraCoreTarget.sol";
import {TimeLock} from "../src/governance_standard/TimelockController.sol";
import {UdraCoreGovernor} from "../src/governance_standard/UdraCoreGovernor.sol";

abstract contract BaseTest is Test, ProtocolConfig {
    // users
    address internal deployer = makeAddr("deployer");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal carol    = makeAddr("carol");
    address internal grantee  = makeAddr("grantee");

    // contracts
    UdraPowerToken    internal token;
    UdraEarner        internal earner;
    UdraCoreTarget    internal target;
    TimeLock internal timelock;
    UdraCoreGovernor  internal governor;

    function setUp() public virtual {
        vm.startPrank(deployer);

        // 1. Token
        token = new UdraPowerToken(deployer, TOKEN_NAME, TOKEN_SYMBOL, ADMIN_TRANSFER_DELAY);

        // 2. Treasury
        target = new UdraCoreTarget(0, deployer); // grantLimit=0 = uncapped

        // 3. Timelock
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = deployer; // temporary — replaced by governor in step 7
        executors[0] = address(0); // open executor

        timelock = new TimeLock(TIMELOCK_DELAY, proposers, executors, deployer);

        // 4. Governor
        governor = new UdraCoreGovernor(IVotes(address(token)), timelock);

        // 5. Earner
        earner = new UdraEarner(
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

        // 6. Grant EARNER_ROLE to earner
        token.setEarner(address(earner));

        // 7. Governor gets PROPOSER_ROLE; no deployer canceller — fully decentralised
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));

        // 8. Transfer target ownership to timelock and complete the two-step handshake
        target.transferOwnership(address(timelock));
        timelock.acceptTargetOwnership(address(target)); // executor is open — any caller works

        // 9. Deployer renounces proposer, canceller, and admin — timelock is fully autonomous
        timelock.renounceRole(timelock.PROPOSER_ROLE(),   deployer);
        timelock.renounceRole(timelock.CANCELLER_ROLE(),  deployer);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopPrank();

        // fund users with ETH for funding tests
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    /// earn 200 UPT (20 × 10 UPT check-ins) to meets the proposal threshold
    function _earnProposerVotes(address user) internal {
        // make all epochs distinct by cache timestamp as base
        // block.timestamp is stale in Foundry's test
        uint256 base = block.timestamp;
        for (uint256 i = 0; i < 20; i++) {
            vm.warp(base + (i + 1) * EPOCH_LENGTH);
            vm.prank(user);
            earner.checkIn();
        }
        vm.roll(block.number + 1);
    }

    /// Roll to active voting window for a proposal
    function _rollPastDelay() internal {
        vm.roll(block.number + VOTING_DELAY + 1);
    }

    /// Roll past voting period so proposal can be queued
    function _rollPastPeriod() internal {
        vm.roll(block.number + VOTING_DELAY + VOTING_PERIOD + 1);
    }

    /// Warp past timelock delay
    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
    }

    /// Full proposal → vote → queue → execute, returns proposalId
    function _runProposal(
        address proposer,
        address[] memory targets_,
        uint256[] memory values_,
        bytes[] memory calldatas_,
        string memory description
    ) internal returns (uint256 proposalId) {
        vm.prank(proposer);
        proposalId = governor.propose(targets_, values_, calldatas_, description);

        _rollPastDelay();

        vm.prank(proposer);
        governor.castVote(proposalId, 1); // For

        _rollPastPeriod();

        governor.queue(targets_, values_, calldatas_, keccak256(bytes(description)));

        _warpPastTimelock();

        governor.execute(targets_, values_, calldatas_, keccak256(bytes(description)));
    }
}
