// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

abstract contract ProtocolConfig {
    // token
    string internal constant TOKEN_NAME   = "UDRA POWER";
    string internal constant TOKEN_SYMBOL = "UPT";
    uint48 internal constant ADMIN_TRANSFER_DELAY = 3 days;

    // earner
    uint256 internal constant CHECKIN_REWARD       = 10 ether;     // UPT per checkin
    uint256 internal constant CHECKIN_GLOBAL_CAP   = 5_000 ether;  // max checkin UPT/epoch
    uint256 internal constant FUND_REWARD_PER_UNIT = 100 ether;    // UPT per 0.01 ETH
    uint256 internal constant FUND_UNIT            = 0.01 ether;   // minimum funding increment
    uint256 internal constant FUND_USER_CAP        = 1_000 ether;  // max fund UPT/user/epoch
    uint256 internal constant FUND_GLOBAL_CAP      = 10_000 ether; // max fund UPT/epoch
    uint256 internal constant EPOCH_LENGTH         = 1 days;

    // governor
    uint48  internal constant VOTING_DELAY       = 7_200;    // ~1 day at 12s/block
    uint32  internal constant VOTING_PERIOD      = 50_400;   // ~1 week
    uint256 internal constant PROPOSAL_THRESHOLD = 200 ether; // 20 checkins at 10 UPT each
    uint256 internal constant TIMELOCK_DELAY     = 3_600;    // 1 hour
}
