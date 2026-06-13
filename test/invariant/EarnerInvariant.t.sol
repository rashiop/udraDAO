// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {ProtocolConfig} from "../../script/ProtocolConfig.sol";
import {UdraPowerToken} from "../../src/UdraPowerToken.sol";
import {UdraEarner} from "../../src/UdraEarner.sol";
import {UdraCoreTarget} from "../../src/UdraCoreTarget.sol";

// Invariant handler to ensure the calling sequences
// ghost variables for internal accounting across-epoch accumulated totals

contract EarnerHandler is CommonBase, StdCheats, StdUtils, ProtocolConfig {
    UdraEarner public earner;
    UdraPowerToken public token;

    address[] public users;

    uint256 public ghostTotalCheckInMinted;
    uint256 public ghostTotalFundMinted;
    mapping(uint256 => uint256) public ghostCheckInPerEpoch;
    mapping(address => mapping(uint256 => uint256)) public ghostFundPerUserPerEpoch;

    constructor(UdraEarner _earner, UdraPowerToken _token, address[] memory _users) {
        earner = _earner;
        token  = _token;
        users = _users;
        for (uint256 i = 0; i < _users.length; i++) {
            vm.deal(_users[i], 1_000 ether);
        }
    }

    function checkIn(uint256 seed) external {
        address user = users[bound(seed, 0, users.length - 1)];
        uint256 epoch = earner.currentEpoch();

        (uint256 cap,) = earner.remainingUserCap(user);
        if (cap == 0) return;

        vm.prank(user);
        try earner.checkIn() {
            ghostTotalCheckInMinted     += CHECKIN_REWARD;
            ghostCheckInPerEpoch[epoch] += CHECKIN_REWARD;
        } catch {
            // acceptable: paused or cap race
        }
    }

    function fund(uint256 userSeed, uint96 amount) external {
        address user = users[bound(userSeed, 0, users.length - 1)];
        amount = uint96(bound(amount, FUND_UNIT, 10 ether));

        uint256 epoch = earner.currentEpoch();
        (, uint256 cap) = earner.remainingUserCap(user);
        if (cap == 0) return;

        uint256 units  = amount / FUND_UNIT;
        uint256 reward = units * FUND_REWARD_PER_UNIT;
        if (reward > cap) return; // would exceed cap — skip

        vm.deal(user, uint256(amount));
        vm.prank(user);
        try earner.fundTreasury{value: amount}() {
            ghostTotalFundMinted                    += reward;
            ghostFundPerUserPerEpoch[user][epoch] += reward;
        } catch {
            // acceptable: paused or cap race
        }
    }

    // forward to next epoch
    function warpEpoch() external {
        vm.warp(block.timestamp + EPOCH_LENGTH);
    }
}

contract EarnerInvariantTest is Test, ProtocolConfig {
    UdraPowerToken internal token;
    UdraEarner     internal earner;
    UdraCoreTarget internal treasury;
    EarnerHandler  internal handler;

    address internal deployer = makeAddr("deployer");
    address[] internal users;

    function setUp() public {
        users.push(makeAddr("user0"));
        users.push(makeAddr("user1"));
        users.push(makeAddr("user2"));
        users.push(makeAddr("user3"));

        vm.startPrank(deployer);

        token    = new UdraPowerToken(deployer, TOKEN_NAME, TOKEN_SYMBOL, ADMIN_TRANSFER_DELAY);
        treasury = new UdraCoreTarget(0, deployer);

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
            address(treasury)
        );

        token.setEarner(address(earner));
        vm.stopPrank();

        handler = new EarnerHandler(earner, token, users);
        targetContract(address(handler));
    }

    /// Per-epoch check-in minted never exceeds CHECKIN_GLOBAL_CAP.
    function invariant_CheckIn_GlobalCapNotExceededCurrentEpoch() public view {
        uint256 epoch = earner.currentEpoch();
        assertLe(
            handler.ghostCheckInPerEpoch(epoch),
            CHECKIN_GLOBAL_CAP,
            "check-in global cap exceeded in current epoch"
        );
    }

    function invariant_CheckIn_RemainingGlobalCapNeverReverts() public view {
        (uint256 checkin,) = earner.remainingGlobalCap();
        assertLe(checkin, CHECKIN_GLOBAL_CAP, "global cap remainder exceeds cap constant");
    }

    function invariant_CheckIn_UserCapIsBinaryPerEpoch() public view {
        for (uint256 i = 0; i < users.length; i++) {
            (uint256 cap,) = earner.remainingUserCap(users[i]);
            assertTrue(cap == 0 || cap == CHECKIN_REWARD, "user check-in cap must be 0 or CHECKIN_REWARD");
        }
    }

    function invariant_Fund_UserCapNeverExceeded() public view {
        for (uint256 i = 0; i < users.length; i++) {
            (, uint256 fundCap) = earner.remainingUserCap(users[i]);
            assertLe(fundCap, FUND_USER_CAP, "user fund cap exceeded");
        }
    }

    function invariant_Fund_RemainingGlobalCapNeverReverts() public view {
        (, uint256 fundCap) = earner.remainingGlobalCap();
        assertLe(fundCap, FUND_GLOBAL_CAP, "global fund cap remainder exceeds cap constant");
    }

    function invariant_TotalSupplyMatchesGhostMinted() public view {
        assertEq(
            token.totalSupply(),
            handler.ghostTotalCheckInMinted() + handler.ghostTotalFundMinted(),
            "total supply diverged from ghost minted"
        );
    }
}
