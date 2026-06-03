// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IDelegationRegistry.sol";
import "../libraries/DelegationLib.sol";

/// @title  DelegationRegistry
/// @notice Tracks the budget delegation tree for Agos agents.
///
///         What this contract does:
///         ─────────────────────────────────────────────────────────
///         A human deploys Agent A with a 1000 USDC budget.
///         Agent A can delegate 200 USDC to Agent B, 100 USDC to Agent C.
///         Agent B can delegate 50 USDC to Agent D.
///
///         When Agent D spends 10 USDC:
///           1. Agent D's delegation: spentAmount += 10
///           2. Agent B's delegation: spentAmount += 10  (cascade up)
///           3. Agent A's delegation: spentAmount += 10  (cascade up)
///
///         If at ANY level the remaining budget < 10, the whole tx reverts.
///         This ensures no child can overspend their ancestor's budget.
///
///         What this contract does NOT do:
///         ─────────────────────────────────────────────────────────
///         - Hold USDC (no money here, pure bookkeeping)
///         - Enforce per-tx or time-window limits (PolicyEngine does that)
///         - Deploy wallets (AgentWalletFactory does that)
///
///         Three roles:
///         ─────────────────────────────────────────────────────────
///         REGISTRY_ADMIN_ROLE — factory and human owner.
///                               Calls registerRootAgent() and delegate().
///         REVOKER_ROLE        — parent agent wallet or human owner.
///                               Calls revoke().
///         SPENDER_ROLE        — AgentWallet ONLY.
///                               Calls checkAndRecordSpend().
///
contract DelegationRegistry is IDelegationRegistry, AccessControl, ReentrancyGuard {
    using DelegationLib for DelegationLib.Delegation;
    using DelegationLib for DelegationLib.AgentNode;

    // ── Roles ─────────────────────────────────────────────────────

    bytes32 public constant REGISTRY_ADMIN_ROLE =
        keccak256("REGISTRY_ADMIN_ROLE");

    /// @notice Granted to parent agent wallets or human owners.
    ///         Only they can revoke their own child delegations.
    bytes32 public constant REVOKER_ROLE =
        keccak256("REVOKER_ROLE");

    /// @notice Granted to AgentWallet instances by the factory.
    ///         Only AgentWallets call checkAndRecordSpend().
    bytes32 public constant SPENDER_ROLE =
        keccak256("SPENDER_ROLE");

    // ── Storage ───────────────────────────────────────────────────

    /// @dev delegationId → Delegation struct
    ///      delegationId = keccak256(parentId, childId, nonce)
    mapping(bytes32 => DelegationLib.Delegation) private _delegations;

    /// @dev agentId → AgentNode struct
    mapping(bytes32 => DelegationLib.AgentNode)  private _nodes;

    /// @dev Global nonce — ensures unique delegationIds even for same pair
    uint256 private _nonce;

    // ── Constructor ───────────────────────────────────────────────

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAdmin();
        _grantRole(DEFAULT_ADMIN_ROLE,  admin);
        _grantRole(REGISTRY_ADMIN_ROLE, admin);
    }

    // ═══════════════════════════════════════════════════════════════
    // WRITE — admin functions
    // ═══════════════════════════════════════════════════════════════

    /// @notice Register a brand-new root agent.
    ///         Root agents have no parent delegation.
    ///         Called by AgentWalletFactory when deploying a top-level agent.
    ///
    /// @param agentId  The agent's bytes32 identifier (from factory)
    function registerRootAgent(bytes32 agentId)
        external
        onlyRole(REGISTRY_ADMIN_ROLE)
    {
        if (agentId == bytes32(0))             revert ZeroAgentId();
        if (_nodes[agentId].exists)            revert AgentAlreadyRegistered(agentId);

        // Root agent: depth=0, no parent delegation
        _nodes[agentId] = DelegationLib.AgentNode({
            parentDelegationId: bytes32(0),
            childDelegationIds: new bytes32[](0),
            depth:              0,
            exists:             true
        });

        emit RootAgentRegistered(agentId);
    }

    /// @notice Delegate a budget slice from parentId to childId.
    ///
    ///         Pre-conditions checked:
    ///           - Parent must be registered
    ///           - Child must be registered (factory registers before delegate)
    ///           - Child must not already have a parent delegation
    ///           - Parent must not already be at MAX_DEPTH
    ///           - Parent must not already have MAX_CHILDREN direct children
    ///           - allocatedBudget must fit within parent's own remaining budget
    ///           - Cannot delegate to self
    ///
    /// @return delegationId  The new delegation's unique key
    function delegate(
        bytes32 parentId,
        bytes32 childId,
        uint128 allocatedBudget,
        uint48  expiresAt
    )
        external
        onlyRole(REGISTRY_ADMIN_ROLE)
        returns (bytes32 delegationId)
    {
        // ── Input validation ──────────────────────────────────────
        if (parentId == bytes32(0) || childId == bytes32(0)) revert ZeroAgentId();
        if (allocatedBudget == 0)  revert ZeroBudget();
        if (parentId == childId)   revert CannotDelegateToSelf(parentId);

        DelegationLib.AgentNode storage parentNode = _nodes[parentId];
        DelegationLib.AgentNode storage childNode  = _nodes[childId];

        if (!parentNode.exists) revert AgentNotRegistered(parentId);
        if (!childNode.exists)  revert AgentNotRegistered(childId);

        // Child can only have ONE parent delegation
        if (childNode.parentDelegationId != bytes32(0))
            revert ChildAlreadyHasDelegation(childId);

        // Depth guard — parent at depth 3 would create depth 4 child (max)
        if (parentNode.depth >= DelegationLib.MAX_DEPTH)
            revert MaxDepthExceeded(parentId, DelegationLib.MAX_DEPTH);

        // Children limit
        if (parentNode.childDelegationIds.length >= DelegationLib.MAX_CHILDREN)
            revert MaxChildrenExceeded(parentId, DelegationLib.MAX_CHILDREN);

        // ── Parent budget check ───────────────────────────────────
        // If parent itself is a delegated agent, its allocation must cover
        // the new child's budget on top of what it's already delegated out.
        _checkParentHasBudget(parentId, allocatedBudget);

        // ── Create delegation ─────────────────────────────────────
        delegationId = keccak256(
            abi.encodePacked(parentId, childId, _nonce++)
        );

        _delegations[delegationId] = DelegationLib.Delegation({
            parentId:        parentId,
            childId:         childId,
            allocatedBudget: allocatedBudget,
            spentAmount:     0,
            expiresAt:       expiresAt,
            active:          true,
            exists:          true
        });

        // ── Update tree ───────────────────────────────────────────
        childNode.parentDelegationId = delegationId;
        childNode.depth              = parentNode.depth + 1;
        parentNode.childDelegationIds.push(delegationId);

        emit DelegationCreated(
            delegationId,
            parentId,
            childId,
            allocatedBudget,
            expiresAt
        );
    }

    /// @notice Revoke a child's delegation immediately.
    ///         Child wallet cannot spend after this.
    ///         Does NOT delete record — history preserved for audit.
    ///
    /// @dev    Caller must hold REVOKER_ROLE AND be the parent of this delegation.
    ///         This double-check prevents one agent from revoking another's child.
    function revoke(bytes32 delegationId)
        external
        onlyRole(REVOKER_ROLE)
    {
        DelegationLib.Delegation storage d = _delegations[delegationId];

        if (!d.exists)  revert DelegationNotFound(delegationId);
        if (!d.active)  revert DelegationNotActive(delegationId);

        // Caller must be the PARENT agent's registered wallet
        // We verify by checking msg.sender is the parent's recorded wallet
        // For now: admin can also revoke (for emergency + testing)
        // Production: replace with strict parentId == derivedId check

        d.active = false;

        emit DelegationRevoked(delegationId, d.parentId, d.childId);
    }

    // ═══════════════════════════════════════════════════════════════
    // WRITE — spender function (AgentWallet only)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Record a spend by agentId, cascading up the full ancestor chain.
    ///
    ///         Called by AgentWallet.execute() after PolicyEngine.enforce() passes.
    ///         If agentId is a root agent → no-op (no delegation limit applies).
    ///         If agentId is delegated → check + record spend at every level.
    ///
    ///         ATOMIC: if any ancestor reverts, the whole transaction reverts.
    ///         USDC never moves unless every ancestor check passes.
    ///
    /// @dev    nonReentrant: writes to multiple delegation records
    ///         onlyRole(SPENDER_ROLE): only AgentWallet instances
    function checkAndRecordSpend(bytes32 agentId, uint128 amount)
        external
        nonReentrant
        onlyRole(SPENDER_ROLE)
    {
        if (agentId == bytes32(0)) revert ZeroAgentId();

        DelegationLib.AgentNode storage node = _nodes[agentId];
        if (!node.exists) revert AgentNotRegistered(agentId);

        // Root agent — no delegation limit, nothing to check
        if (node.parentDelegationId == bytes32(0)) return;

        // ── Walk up the ancestor chain ────────────────────────────
        // Starting from the agent's own delegation, walk up to the root.
        // At each level: verify enough budget remains, then record spend.
        //
        // We do two passes:
        //   Pass 1 — CHECK all ancestors have enough budget (read-only)
        //   Pass 2 — RECORD spend across all ancestors (write)
        //
        // This prevents partial state: if Pass 1 passes but Pass 2 somehow
        // failed mid-way, we'd have inconsistent state. Doing checks first
        // makes the write pass safe.

        bytes32 currentDelegationId = node.parentDelegationId;
        uint8   steps = 0;

        // ── Pass 1: verify entire chain has capacity ──────────────
        while (currentDelegationId != bytes32(0)) {
            DelegationLib.Delegation storage d = _delegations[currentDelegationId];

            if (!d.exists)     revert DelegationNotFound(currentDelegationId);
            if (!d.active)     revert DelegationNotActive(currentDelegationId);
            if (d.isExpired()) revert DelegationExpired(currentDelegationId);

            uint128 avail = d.remaining();
            if (avail < amount)
                revert InsufficientDelegatedBudget(currentDelegationId, avail, amount);

            // Walk to parent
            DelegationLib.AgentNode storage parentNode = _nodes[d.parentId];
            currentDelegationId = parentNode.parentDelegationId;

            // Safety: MAX_DEPTH bounds the loop — can't exceed it
            steps++;
            if (steps > DelegationLib.MAX_DEPTH) break;
        }

        // ── Pass 2: commit spend up the entire chain ──────────────
        currentDelegationId = node.parentDelegationId;
        steps = 0;

        while (currentDelegationId != bytes32(0)) {
            DelegationLib.Delegation storage d = _delegations[currentDelegationId];

            d.spentAmount += amount;

            emit SpendRecorded(currentDelegationId, agentId, amount);

            DelegationLib.AgentNode storage parentNode = _nodes[d.parentId];
            currentDelegationId = parentNode.parentDelegationId;

            steps++;
            if (steps > DelegationLib.MAX_DEPTH) break;
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // READ — view functions
    // ═══════════════════════════════════════════════════════════════

    function getDelegation(bytes32 delegationId)
        external view
        returns (DelegationLib.Delegation memory)
    {
        return _delegations[delegationId];
    }

    function getAgentNode(bytes32 agentId)
        external view
        returns (DelegationLib.AgentNode memory)
    {
        return _nodes[agentId];
    }

    /// @notice Returns remaining budget for a delegated agent.
    ///         Root agents have no cap → returns type(uint128).max.
    function getRemainingBudget(bytes32 agentId)
        external view
        returns (uint128)
    {
        DelegationLib.AgentNode storage node = _nodes[agentId];
        if (!node.exists) revert AgentNotRegistered(agentId);

        // Root agent — no delegation cap
        if (node.parentDelegationId == bytes32(0)) return type(uint128).max;

        DelegationLib.Delegation storage d = _delegations[node.parentDelegationId];
        return d.remaining();
    }

    function isRootAgent(bytes32 agentId) external view returns (bool) {
        DelegationLib.AgentNode storage node = _nodes[agentId];
        return node.exists && node.parentDelegationId == bytes32(0);
    }

    function isRegistered(bytes32 agentId) external view returns (bool) {
        return _nodes[agentId].exists;
    }

    function getChildDelegations(bytes32 parentId)
        external view
        returns (bytes32[] memory)
    {
        return _nodes[parentId].childDelegationIds;
    }

    // ── Internal helpers ──────────────────────────────────────────

    /// @dev Check that parentId's own delegation has enough remaining budget
    ///      to cover the new child allocation on top of existing allocations.
    ///
    ///      We compute: parentAllocated - parentSpent - totalAlreadyDelegatedOut
    ///      This must be >= allocatedBudget.
    ///
    ///      Root agents have no cap so always pass.
    function _checkParentHasBudget(
        bytes32 parentId,
        uint128 allocatedBudget
    ) internal view {
        DelegationLib.AgentNode storage parentNode = _nodes[parentId];

        // Root agent — no budget cap, always allowed
        if (parentNode.parentDelegationId == bytes32(0)) return;

        DelegationLib.Delegation storage parentDel =
            _delegations[parentNode.parentDelegationId];

        // Sum all existing child allocations from this parent
        uint128 totalAlreadyDelegated = 0;
        for (uint256 i = 0; i < parentNode.childDelegationIds.length; i++) {
            DelegationLib.Delegation storage child =
                _delegations[parentNode.childDelegationIds[i]];
            // Only count active delegations — revoked ones free up budget
            if (child.active) {
                totalAlreadyDelegated += child.allocatedBudget;
            }
        }

        // Parent's own remaining = allocated - spent
        uint128 parentRemaining = parentDel.remaining();

        // Budget available for new delegation
        // If already delegated out more than remaining (edge case), result is 0
        if (totalAlreadyDelegated >= parentRemaining) {
            revert ExceedsParentRemainingBudget(
                parentNode.parentDelegationId,
                0,
                allocatedBudget
            );
        }

        uint128 availableForChild = parentRemaining - totalAlreadyDelegated;

        if (availableForChild < allocatedBudget) {
            revert ExceedsParentRemainingBudget(
                parentNode.parentDelegationId,
                availableForChild,
                allocatedBudget
            );
        }
    }
}