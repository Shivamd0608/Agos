// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IPolicyEngine.sol";
import "../libraries/PolicyLib.sol";

/// @title  PolicyEngine
/// @notice On-chain enforcement of agent spending rules.
///         Called by AgentWallet before every payment.
contract PolicyEngine is IPolicyEngine, AccessControl, ReentrancyGuard {
    using PolicyLib for PolicyLib.Policy;

    bytes32 public constant POLICY_ADMIN_ROLE = keccak256("POLICY_ADMIN_ROLE");

    /// @dev agentId => Policy
    mapping(bytes32 => PolicyLib.Policy) private _policies;

    /// @dev agentId => day bucket => spent
    mapping(bytes32 => mapping(uint256 => uint256)) private _dailySpend;

    /// @dev agentId => hour bucket => spent
    mapping(bytes32 => mapping(uint256 => uint256)) private _hourlySpend;

    event PolicySet(bytes32 indexed agentId, address indexed owner);
    event PolicyEnforced(bytes32 indexed agentId, uint256 amount, address payee);
    event PolicyViolation(bytes32 indexed agentId, string reason);

    error PolicyNotFound(bytes32 agentId);
    error PolicyViolated(bytes32 agentId, string reason);
    error Unauthorized();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POLICY_ADMIN_ROLE, admin);
    }

    /// @notice Register or update a spending policy for an agent
    function setPolicy(
        bytes32 agentId,
        PolicyLib.Policy calldata policy
    ) external onlyRole(POLICY_ADMIN_ROLE) {
        _policies[agentId] = policy;
        emit PolicySet(agentId, msg.sender);
    }

    /// @notice Enforce policy before a payment. Reverts on violation.
    function enforce(
        bytes32 agentId,
        uint256 amount,
        address payee
    ) external nonReentrant returns (bool requiresApproval) {
        PolicyLib.Policy storage p = _policies[agentId];
        if (p.expiresAt == 0) revert PolicyNotFound(agentId);
        if (p.expiresAt != type(uint256).max && block.timestamp > p.expiresAt)
            revert PolicyViolated(agentId, "policy expired");
        if (amount > p.maxPerTransaction)
            revert PolicyViolated(agentId, "exceeds per-tx limit");

        uint256 dayBucket  = block.timestamp / 1 days;
        uint256 hourBucket = block.timestamp / 1 hours;

        uint256 newDaily  = _dailySpend[agentId][dayBucket]  + amount;
        uint256 newHourly = _hourlySpend[agentId][hourBucket] + amount;

        if (newDaily  > p.maxPerDay)  revert PolicyViolated(agentId, "exceeds daily limit");
        if (newHourly > p.maxPerHour) revert PolicyViolated(agentId, "exceeds hourly limit");

        _dailySpend[agentId][dayBucket]   = newDaily;
        _hourlySpend[agentId][hourBucket] = newHourly;

        requiresApproval = amount >= p.requireApprovalAbove;
        emit PolicyEnforced(agentId, amount, payee);
    }

    function getPolicy(bytes32 agentId) external view returns (PolicyLib.Policy memory) {
        return _policies[agentId];
    }
}
