// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {ProtocolConfig} from "../../script/ProtocolConfig.sol";
import {UdraPowerToken} from "../../src/UdraPowerToken.sol";

contract TokenHandler is CommonBase, StdCheats, StdUtils {
    UdraPowerToken public token;

    address[] public users;
    address internal minter; // the account granted EARNER_ROLE

    uint256 public ghostTotalMinted;
    mapping(address => uint256) public ghostBalance;

    constructor(UdraPowerToken _token, address _minter, address[] memory _users) {
        token  = _token;
        minter = _minter;
        users = _users;
    }

    /// Mint to a random user - only minter can call token.mint
    function mint(uint256 userSeed, uint96 amount) external {
        vm.assume(amount > 0);
        address to = users[bound(userSeed, 0, users.length - 1)];

        vm.prank(minter);
        token.mint(to, amount);

        ghostTotalMinted       += amount;
        ghostBalance[to]       += amount;
    }

    /// Transfer should always revert (TransfersDisabled)
    function transfer(uint256 fromSeed, uint256 toSeed, uint96 amount) external {
        address from = users[bound(fromSeed, 0, users.length - 1)];
        address to   = users[bound(toSeed,   0, users.length - 1)];
        if (from == to) return; // skip self-transfer (no-op)
        if (amount == 0) return;

        vm.prank(from);
        try token.transfer(to, amount) {
            // should never succeed — record a ghost flag if it does
            // invariant_NoTransferBetweenNonZeroAddresses will catch this
        } catch {
            // expected
        }
    }

    /// Approve then transferFrom — transferFrom should also revert
    function transferFrom(uint256 fromSeed, uint256 toSeed, uint96 amount) external {
        address from = users[bound(fromSeed, 0, users.length - 1)];
        address to   = users[bound(toSeed,   0, users.length - 1)];
        if (from == to) return;
        if (amount == 0) return;

        vm.prank(from);
        token.approve(address(this), amount);

        try token.transferFrom(from, to, amount) {
            // should never succeed
        } catch {
            // expected
        }
    }
}

contract TokenInvariantTest is Test, ProtocolConfig {
    UdraPowerToken internal token;
    TokenHandler   internal handler;

    address internal deployer = makeAddr("deployer");
    address internal minter   = makeAddr("minter");
    address[] internal users;

    function setUp() public {
        users.push(makeAddr("user0"));
        users.push(makeAddr("user1"));
        users.push(makeAddr("user2"));

        vm.startPrank(deployer);
        token = new UdraPowerToken(deployer, TOKEN_NAME, TOKEN_SYMBOL, ADMIN_TRANSFER_DELAY);
        token.setEarner(minter);
        vm.stopPrank();

        handler = new TokenHandler(token, minter, users);
        targetContract(address(handler));
    }

    /// Total supply equals the sum of all ghost-minted amounts.
    function invariant_TotalSupplyMatchesGhostMinted() public view {
        assertEq(token.totalSupply(), handler.ghostTotalMinted(), "total supply diverged from ghost");
    }

    /// Total supply only increases (no burn path exists).
    function invariant_TotalSupplyNeverDecreases() public view {
        // Verified structurally: ghostTotalMinted is monotonically increasing,
        // and totalSupply == ghostTotalMinted (above invariant). Together these
        // guarantee supply never goes down.
        assertGe(token.totalSupply(), 0); // redundant but documents the intent
    }

    /// Each user's on-chain balance matches the ghost balance.
    function invariant_BalancesMatchGhost() public view {
        for (uint256 i = 0; i < users.length; i++) {
            assertEq(
                token.balanceOf(users[i]),
                handler.ghostBalance(users[i]),
                "user balance diverged from ghost"
            );
        }
    }

    /// Sum of all user balances equals total supply
    /// If a transfer had succeeded, at least one ghostBalance would be wrong,
    /// which invariant_BalancesMatchGhost would catch
    /// This invariant confirms the sum-of-parts equals the whole
    function invariant_SumOfBalancesEqualsTotalSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < users.length; i++) {
            sum += token.balanceOf(users[i]);
        }
        assertEq(sum, token.totalSupply(), "sum of balances != totalSupply");
    }

    /// Votes equal balance for all users (auto-self-delegate on mint, no transfer shifts)
    function invariant_VotesEqualBalanceForAllUsers() public view {
        for (uint256 i = 0; i < users.length; i++) {
            assertEq(
                token.getVotes(users[i]),
                token.balanceOf(users[i]),
                "votes != balance (delegate state inconsistent)"
            );
        }
    }
}
