// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Script, console2} from "forge-std/Script.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {ProtocolConfig} from "./ProtocolConfig.sol";
import {UdraPowerToken} from "../src/UdraPowerToken.sol";
import {UdraEarner} from "../src/UdraEarner.sol";
import {UdraCoreTarget} from "../src/UdraCoreTarget.sol";
import {UdraCoreGovernor} from "../src/governance_standard/UdraCoreGovernor.sol";
import {TimeLock} from "../src/governance_standard/TimelockController.sol";

contract DeployUdraCore is Script, ProtocolConfig {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        string memory tokenName   = vm.envOr("TOKEN_NAME",   TOKEN_NAME);
        string memory tokenSymbol = vm.envOr("TOKEN_SYMBOL", TOKEN_SYMBOL);
        uint48 adminTransferDelay = uint48(vm.envOr("ADMIN_TRANSFER_DELAY", ADMIN_TRANSFER_DELAY));

        uint256 checkinReward     = vm.envOr("CHECKIN_REWARD",       CHECKIN_REWARD);
        uint256 fundRewardPerUnit = vm.envOr("FUND_REWARD_PER_UNIT", FUND_REWARD_PER_UNIT);
        uint256 fundUnit          = vm.envOr("FUND_UNIT",            FUND_UNIT);
        uint256 checkinGlobalCap  = vm.envOr("CHECKIN_GLOBAL_CAP",   CHECKIN_GLOBAL_CAP);
        uint256 fundUserCap       = vm.envOr("FUND_USER_CAP",        FUND_USER_CAP);
        uint256 fundGlobalCap     = vm.envOr("FUND_GLOBAL_CAP",      FUND_GLOBAL_CAP);
        uint256 epochLength       = vm.envOr("EPOCH_LENGTH",         EPOCH_LENGTH);
        uint256 timelockDelay     = vm.envOr("TIMELOCK_DELAY",       TIMELOCK_DELAY);


        vm.startBroadcast(deployerPrivateKey);

        // 1. Token
        UdraPowerToken token = new UdraPowerToken(deployer, tokenName, tokenSymbol, adminTransferDelay);

        // 2. Treasury
        UdraCoreTarget target = new UdraCoreTarget(0, deployer);

        // 3. Timelock
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = deployer; // temporary — replaced by governor in step 7
        executors[0] = address(0); // open executor

        TimeLock timelock =
            new TimeLock(timelockDelay, proposers, executors, deployer);

        // 4. Governor
        UdraCoreGovernor governor = new UdraCoreGovernor(IVotes(address(token)), timelock);

        // 5. Earner
        UdraEarner earner = new UdraEarner(
            token,
            deployer,
            checkinReward,
            fundRewardPerUnit,
            fundUnit,
            checkinGlobalCap,
            fundUserCap,
            fundGlobalCap,
            epochLength,
            address(target)
        );

        // 6. Grant EARNER_ROLE
        token.setEarner(address(earner));

        // 7. Governor gets PROPOSER_ROLE; no deployer canceller — fully decentralised
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));

        // 8. Transfer target ownership to timelock and immediately accept (Ownable2Step)
        target.transferOwnership(address(timelock));
        timelock.acceptTargetOwnership(address(target));

        // 9. Deployer renounces proposer, canceller, and admin — timelock is fully autonomous
        timelock.renounceRole(timelock.PROPOSER_ROLE(),   deployer);
        timelock.renounceRole(timelock.CANCELLER_ROLE(),  deployer);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        console2.log("UdraPowerToken    :", address(token));
        console2.log("UdraEarner        :", address(earner));
        console2.log("UdraCoreTarget    :", address(target));
        console2.log("TimelockController:", address(timelock));
        console2.log("UdraCoreGovernor  :", address(governor));
        console2.log("Deployer          :", deployer);
    }
}
