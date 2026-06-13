// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

// TODO
// DAO-1	Participation Token Setup – Deploy ERC20Votes or ERC721Votes token (optionally non-transferable) with checkpoints.
// v a. Minting restricted to Earner contract.
// v b .Expose delegate/delegateBySig for Snapshot compatibility.
// v DAO-9 Snapshot Integration – Ensure token is OZ Votes-compatible and delegation works.
// a. Publish Governor + Timelock addresses and network info.
// b. Document delegation flow for Tally proposals and votes.

contract UdraPowerToken is ERC20, EIP712, ERC20Votes, AccessControlDefaultAdminRules {
    error TransfersDisabled();
    error NoZeroAddress();
    error InvalidTokenName();
    error InvalidTokenSymbol();

    bytes32 public constant EARNER_ROLE = keccak256("EARNER_ROLE");

    event EarnerGranted(address indexed earner);
    event EarnerRevoked(address indexed earner);

    constructor(address initialOwner, string memory tokenName, string memory tokenSymbol, uint48 adminTransferDelay)
        AccessControlDefaultAdminRules(adminTransferDelay, initialOwner)
        ERC20(tokenName, tokenSymbol)
        EIP712(tokenName, "1")
    {
        if (bytes(tokenName).length == 0) revert InvalidTokenName();
        if (bytes(tokenSymbol).length == 0) revert InvalidTokenSymbol();
    }

    function setEarner(address earner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (earner == address(0)) revert NoZeroAddress();
        _grantRole(EARNER_ROLE, earner);
        emit EarnerGranted(earner);
    }

    function revokeEarner(address earner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (earner == address(0)) revert NoZeroAddress();
        _revokeRole(EARNER_ROLE, earner);
        emit EarnerRevoked(earner);
    }

    function mint(address to, uint256 amount) external onlyRole(EARNER_ROLE) {
        _mint(to, amount);

        if (delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }

    // The following functions are overrides required by Solidity.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        // allow burn, mint but reject transfer
        if (from != address(0) && to != address(0)) revert TransfersDisabled();
        super._update(from, to, value);
    }
}
