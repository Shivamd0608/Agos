// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  PolicyLib
/// @notice Shared data structures for the Agos policy engine.
///         This is a library — it never gets deployed on its own.
///         Every contract that needs a Policy struct imports this.
library PolicyLib {

    // ─── Core policy struct ───────────────────────────────────────
    // This is the "spending rule" that a human owner sets for their agent.
    // All amounts are in USDC base units (6 decimals).
    // So 1 USDC = 1_000_000, 0.01 USDC = 10_000

    struct Policy {
        uint128 maxPerTransaction;    // max a single payment can be
        uint128 maxPerDay;            // rolling 24h spend ceiling
        uint128 maxPerHour;           // rolling 1h spend ceiling
        uint128 requireApprovalAbove; // payments >= this need human sign-off
        uint48  expiresAt;            // unix timestamp, 0 = never expires
        bool    active;               // false = policy is paused/revoked
        address[] allowedPayees;      // empty array = any payee is allowed
    }

    // ─── Spend tracking struct ────────────────────────────────────
    // Stored per-agent. Tracks rolling spend windows.
    // The "bucket" trick: instead of storing a timestamp,
    // we store block.timestamp / window_size as an integer.
    // When the bucket number changes, we know we're in a new window.

    struct SpendRecord {
        uint128 hourlyAmount;   // amount spent in current hour bucket
        uint128 dailyAmount;    // amount spent in current day bucket
        uint32  hourBucket;     // block.timestamp / 3600
        uint32  dayBucket;      // block.timestamp / 86400
    }

    // ─── Helper functions ─────────────────────────────────────────

    /// @notice Returns true if the policy has expired
    function isExpired(Policy storage p) internal view returns (bool) {
        return p.expiresAt != 0 && block.timestamp > p.expiresAt;
    }

    /// @notice Returns true if a given payee is allowed by this policy.
    ///         If allowedPayees is empty, all payees are allowed.
    function isPayeeAllowed(
        Policy storage p,
        address payee
    ) internal view returns (bool) {
        if (p.allowedPayees.length == 0) return true;
        for (uint256 i = 0; i < p.allowedPayees.length; i++) {
            if (p.allowedPayees[i] == payee) return true;
        }
        return false;
    }

    /// @notice Get the current hour bucket number
    ///         Changes every 3600 seconds. When it changes,
    ///         the hourly spend counter resets to 0.
    function currentHourBucket() internal view returns (uint32) {
        return uint32(block.timestamp / 3600);
    }

    /// @notice Get the current day bucket number
    ///         Changes every 86400 seconds.
    function currentDayBucket() internal view returns (uint32) {
        return uint32(block.timestamp / 86400);
    }

    /// @notice Check if the hourly window has rolled over.
    ///         If yes, the caller should reset hourlyAmount to 0.
    function isNewHour(SpendRecord storage r) internal view returns (bool) {
        return currentHourBucket() != r.hourBucket;
    }

    /// @notice Check if the daily window has rolled over.
    function isNewDay(SpendRecord storage r) internal view returns (bool) {
        return currentDayBucket() != r.dayBucket;
    }
}