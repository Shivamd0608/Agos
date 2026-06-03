// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";       // ← ADDED BACK
import "../interfaces/IPolicyEngine.sol";
import "../libraries/PolicyLib.sol";

contract PolicyEngine is IPolicyEngine, AccessControl, ReentrancyGuard {
    using PolicyLib for PolicyLib.Policy;
    using PolicyLib for PolicyLib.SpendRecord;

    bytes32 public constant POLICY_ADMIN_ROLE = keccak256("POLICY_ADMIN_ROLE");
    bytes32 public constant ENFORCER_ROLE     = keccak256("ENFORCER_ROLE");
    // AgentWallet gets granted ENFORCER_ROLE by factory on deployment

    mapping(bytes32 => PolicyLib.Policy)      private _policies;
    mapping(bytes32 => PolicyLib.SpendRecord) private _spendRecords;

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAdmin();      // ← zero-address check
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POLICY_ADMIN_ROLE,  admin);
    }

    function setPolicy(
        bytes32 agentId,
        PolicyLib.Policy calldata policy
    ) external onlyRole(POLICY_ADMIN_ROLE) {
        // Validate payee list size
        if (policy.allowedPayees.length > PolicyLib.MAX_ALLOWED_PAYEES)
            revert TooManyPayees(policy.allowedPayees.length, PolicyLib.MAX_ALLOWED_PAYEES);

        // Validate limit hierarchy
        if (policy.maxPerTransaction > policy.maxPerHour)  revert InvalidPolicy();
        if (policy.maxPerHour        > policy.maxPerDay)   revert InvalidPolicy();
        // requireApprovalAbove must be <= maxPerTransaction (no point flagging what's already blocked)
        if (policy.requireApprovalAbove > policy.maxPerTransaction) revert InvalidPolicy();

        bool isUpdate = _policies[agentId].exists;
        _policies[agentId] = policy;
        _policies[agentId].exists = true;  // always set exists = true

        if (isUpdate) {
            emit PolicyUpdated(agentId, msg.sender);
        } else {
            emit PolicySet(agentId, msg.sender);
        }
    }

    function revokePolicy(bytes32 agentId) external onlyRole(POLICY_ADMIN_ROLE) {
        if (!_policies[agentId].exists) revert PolicyNotFound(agentId);  // ← uses exists
        _policies[agentId].active = false;
        emit PolicyRevoked(agentId);
    }

    function enforce(
        bytes32 agentId,
        uint128 amount,
        address payee
    ) external nonReentrant onlyRole(ENFORCER_ROLE) returns (bool requiresApproval) {
        // ← ENFORCER_ROLE: only AgentWallet can call this
        PolicyLib.Policy     storage p = _policies[agentId];
        PolicyLib.SpendRecord storage r = _spendRecords[agentId];

        if (!p.exists)   revert PolicyNotFound(agentId);   // ← clean exists check
        if (!p.active)   revert PolicyInactive(agentId);
        if (p.isExpired()) revert PolicyExpired(agentId);
        if (!p.isPayeeAllowed(payee)) revert PayeeNotAllowed(agentId, payee);
        if (amount > p.maxPerTransaction)
            revert ExceedsPerTxLimit(agentId, amount, p.maxPerTransaction);

        if (r.isNewHour()) { r.hourlyAmount = 0; r.hourBucket = PolicyLib.currentHourBucket(); }
        if (r.isNewDay())  { r.dailyAmount  = 0; r.dayBucket  = PolicyLib.currentDayBucket();  }

        uint128 newHourly = r.hourlyAmount + amount;
        uint128 newDaily  = r.dailyAmount  + amount;

        if (newHourly > p.maxPerHour) revert ExceedsHourlyLimit(agentId, newHourly, p.maxPerHour);
        if (newDaily  > p.maxPerDay)  revert ExceedsDailyLimit(agentId,  newDaily,  p.maxPerDay);

        r.hourlyAmount = newHourly;
        r.dailyAmount  = newDaily;

        requiresApproval = amount >= p.requireApprovalAbove;

        if (requiresApproval) {
            emit ApprovalRequired(agentId, amount, payee);
        } else {
            emit PaymentEnforced(agentId, amount, payee);
        }
    }

    function getPolicy(bytes32 agentId) external view returns (PolicyLib.Policy memory) {
        return _policies[agentId];
    }

    function getSpendRecord(bytes32 agentId) external view returns (PolicyLib.SpendRecord memory) {
        return _spendRecords[agentId];
    }
}