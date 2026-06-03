// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../libraries/DelegationLib.sol";

/// @title  IDelegationRegistry
/// @notice ABI definition for DelegationRegistry.
///         AgentWallet imports only this interface.
interface IDelegationRegistry {

    // ── Events ────────────────────────────────────────────────────

    /// @notice Fired when a parent delegates budget to a child agent.
    event DelegationCreated(
        bytes32 indexed delegationId,
        bytes32 indexed parentId,
        bytes32 indexed childId,
        uint128         allocatedBudget,
        uint48          expiresAt
    );

    /// @notice Fired when a parent revokes a child's delegation.
    event DelegationRevoked(
        bytes32 indexed delegationId,
        bytes32 indexed parentId,
        bytes32 indexed childId
    );

    /// @notice Fired every time a delegated spend is recorded.
    ///         amount is the payment; delegationId is the child's link.
    event SpendRecorded(
        bytes32 indexed delegationId,
        bytes32 indexed agentId,
        uint128         amount
    );

    /// @notice Fired when a root agent (no parent) is registered.
    event RootAgentRegistered(bytes32 indexed agentId);

    // ── Errors ────────────────────────────────────────────────────

    error ZeroAgentId();
    error ZeroAdmin();
    error ZeroBudget();
    error AgentAlreadyRegistered(bytes32 agentId);
    error AgentNotRegistered(bytes32 agentId);
    error DelegationNotFound(bytes32 delegationId);
    error DelegationNotActive(bytes32 delegationId);
    error DelegationExpired(bytes32 delegationId);
    error InsufficientDelegatedBudget(
        bytes32 delegationId,
        uint128 available,
        uint128 requested
    );
    error ExceedsParentRemainingBudget(
        bytes32 parentDelegationId,
        uint128 available,
        uint128 requested
    );
    error MaxDepthExceeded(bytes32 parentId, uint8 maxDepth);
    error MaxChildrenExceeded(bytes32 parentId, uint8 maxChildren);
    error CannotDelegateToSelf(bytes32 agentId);
    error ChildAlreadyHasDelegation(bytes32 childId);
    error NotParentOfDelegation(bytes32 delegationId, bytes32 caller);

    // ── Functions ─────────────────────────────────────────────────

    /// @notice Register a root agent (no parent, directly human-owned).
    ///         Called by AgentWalletFactory when creating a new top-level agent.
    ///         Caller must hold REGISTRY_ADMIN_ROLE.
    function registerRootAgent(bytes32 agentId) external;

    /// @notice Delegate a budget slice from parent agent to a new child agent.
    ///         Creates a Delegation record and registers child in the tree.
    ///         Caller must hold REGISTRY_ADMIN_ROLE.
    ///         Child must not already have a parent delegation.
    ///
    /// @param  parentId        agentId of the delegating agent
    /// @param  childId         agentId of the new child agent
    /// @param  allocatedBudget USDC amount (6 decimals) given to child
    /// @param  expiresAt       unix timestamp, 0 = no expiry
    /// @return delegationId    bytes32 key for this delegation record
    function delegate(
        bytes32 parentId,
        bytes32 childId,
        uint128 allocatedBudget,
        uint48  expiresAt
    ) external returns (bytes32 delegationId);

    /// @notice Revoke a child's delegation immediately.
    ///         Child wallet can no longer spend after this call.
    ///         Caller must be the REGISTRY_ADMIN_ROLE holder
    ///         AND the parentId of the delegation must match.
    function revoke(bytes32 delegationId) external;

    /// @notice Check that `agentId` can spend `amount` within its delegation,
    ///         and record the spend across the full ancestor chain.
    ///
    ///         Called by AgentWallet.execute() after PolicyEngine.enforce().
    ///         Reverts if any ancestor has insufficient remaining budget.
    ///         Caller must hold SPENDER_ROLE (only AgentWallet instances).
    ///
    ///         If agent is a root agent (no delegation), this is a no-op.
    function checkAndRecordSpend(bytes32 agentId, uint128 amount) external;

    // ── View functions ────────────────────────────────────────────

    /// @notice Returns the Delegation struct for a given delegationId.
    function getDelegation(bytes32 delegationId)
        external view returns (DelegationLib.Delegation memory);

    /// @notice Returns the AgentNode for a given agentId.
    function getAgentNode(bytes32 agentId)
        external view returns (DelegationLib.AgentNode memory);

    /// @notice Returns remaining budget for a delegated agent.
    ///         Returns type(uint128).max for root agents (no delegation limit).
    function getRemainingBudget(bytes32 agentId)
        external view returns (uint128);

    /// @notice Returns true if agentId is a root agent (no parent delegation).
    function isRootAgent(bytes32 agentId) external view returns (bool);

    /// @notice Returns true if agentId is registered in the registry.
    function isRegistered(bytes32 agentId) external view returns (bool);

    /// @notice Returns all direct child delegation IDs for a given parent.
    function getChildDelegations(bytes32 parentId)
        external view returns (bytes32[] memory);
}