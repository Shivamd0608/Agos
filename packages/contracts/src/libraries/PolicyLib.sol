// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library PolicyLib {
    struct Policy {
        uint256 maxPerTransaction;
        uint256 maxPerDay;
        uint256 maxPerHour;
        uint256 requireApprovalAbove;
        uint256 expiresAt;          // unix ts, type(uint256).max = forever
        address[] allowedPayees;    // empty = all allowed
    }
}
