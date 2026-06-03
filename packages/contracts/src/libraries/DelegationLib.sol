// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  DelegationLib
/// @notice Shared data structures for the Agos delegation system.
///         Library only — never deployed on its own.
///         DelegationRegistry imports and uses these structs.
///
/// @dev    Delegation in Agos works like a budget tree.
///         A parent agent delegates a slice of its budget to a child agent.
///         When the child spends, the spend cascades UP the tree to all
///         ancestors. No ancestor can be over-spent.
library DelegationLib {

    // ── Constants ─────────────────────────────────────────────────

    /// @notice Maximum depth of delegation tree.
    ///         human → A → B → C → D = 4 levels deep.
    ///         Prevents unbounded loops in cascade and depth checks.
    uint8 internal constant MAX_DEPTH = 4;

    /// @notice Maximum number of direct children one parent can have.
    ///         Prevents unbounded children arrays and storage bloat.
    uint8 internal constant MAX_CHILDREN = 10;

    // ── Core delegation struct ────────────────────────────────────
    //
    // One Delegation is created every time a parent delegates budget
    // to a child. It is the single source of truth for:
    //   - how much the child was given (allocatedBudget)
    //   - how much the child has used   (spentAmount)
    //   - whether it is still active    (active)
    //
    // All amounts in USDC base units (6 decimals).
    // 1 USDC = 1_000_000

    struct Delegation {
        bytes32 parentId;        // agent that delegated
        bytes32 childId;         // agent that received the delegation
        uint128 allocatedBudget; // total budget given to child
        uint128 spentAmount;     // how much child has spent so far
        uint48  expiresAt;       // unix timestamp — 0 = no expiry
        bool    active;          // false = revoked by parent
        bool    exists;          // true once created — never reset
    }

    // ── Agent node struct ─────────────────────────────────────────
    //
    // Stored per agentId. Tracks where in the tree this agent sits.
    // If parentDelegationId == bytes32(0), this is a root agent
    // (directly owned by a human, no delegation parent).

    struct AgentNode {
        bytes32   parentDelegationId; // delegation ID linking to parent
        bytes32[] childDelegationIds; // delegation IDs for all children
        uint8     depth;              // 0 = root, 1 = child of root, etc.
        bool      exists;             // true once registered
    }

    // ── Helper functions ──────────────────────────────────────────

    /// @notice Remaining budget the child can still spend.
    ///         Returns 0 if already over-spent (should not happen but safe).
    function remaining(
        Delegation storage d
    ) internal view returns (uint128) {
        if (d.spentAmount >= d.allocatedBudget) return 0;
        return d.allocatedBudget - d.spentAmount;
    }

    /// @notice True if this delegation has expired.
    function isExpired(
        Delegation storage d
    ) internal view returns (bool) {
        return d.expiresAt != 0 && block.timestamp > d.expiresAt;
    }

    /// @notice True if delegation is usable — active, not expired, exists.
    function isUsable(
        Delegation storage d
    ) internal view returns (bool) {
        return d.exists && d.active && !isExpired(d);
    }
}