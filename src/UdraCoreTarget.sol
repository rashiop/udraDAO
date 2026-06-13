// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract UdraCoreTarget is Ownable2Step, ReentrancyGuard {
    /// @notice Per-release grant limit. 0 means uncapped.
    uint256 public grantLimit;

    event GrantReleased(address indexed to, uint256 amount);
    event GrantLimitUpdated(uint256 oldLimit, uint256 newLimit);

    error InsufficientBalance();
    error ExceedsGrantLimit();
    error NoZeroAddress();
    error NoZeroAmount();
    error ReleaseFailed();

    constructor(uint256 initialGrantLimit, address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert NoZeroAddress();
    
        grantLimit = initialGrantLimit;
    }

    receive() external payable {}

    function releaseEth(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert NoZeroAddress();
        if (amount == 0) revert NoZeroAmount();
        if (address(this).balance < amount) revert InsufficientBalance();
        if (grantLimit != 0 && amount > grantLimit) revert ExceedsGrantLimit(); // 0 = uncapped
        
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert ReleaseFailed();
        emit GrantReleased(to, amount);
    }

    function setGrantLimit(uint256 newLimit) external onlyOwner {
        uint256 old = grantLimit;
        grantLimit = newLimit;

        emit GrantLimitUpdated(old, newLimit);
    }
}
