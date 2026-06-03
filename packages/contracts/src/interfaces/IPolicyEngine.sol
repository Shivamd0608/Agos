// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../libraries/PolicyLib.sol";

interface IPolicyEngine {

    // ─── Events ───────────────────────────────────────────────────
    event PolicySet(bytes32 indexed agentId, address indexed owner);
    event PolicyUpdated(bytes32 indexed agentId, address indexed owner); // ← distinguish update vs create
    event PolicyRevoked(bytes32 indexed agentId);
    event PaymentEnforced(bytes32 indexed agentId, uint128 amount, address indexed payee);
    event ApprovalRequired(bytes32 indexed agentId, uint128 amount, address indexed payee);
    // removed PolicyViolation(string) — covered by custom errors below

    // ─── Errors ───────────────────────────────────────────────────
    error PolicyNotFound(bytes32 agentId);
    error PolicyExpired(bytes32 agentId);
    error PolicyInactive(bytes32 agentId);
    error ExceedsPerTxLimit(bytes32 agentId, uint128 attempted, uint128 limit);
    error ExceedsDailyLimit(bytes32 agentId, uint128 attempted, uint128 limit);
    error ExceedsHourlyLimit(bytes32 agentId, uint128 attempted, uint128 limit);
    error PayeeNotAllowed(bytes32 agentId, address payee);
    error InvalidPolicy();
    error TooManyPayees(uint256 provided, uint256 max);  // ← new
    error ZeroAdmin();                                    // ← new

    // ─── Functions ────────────────────────────────────────────────
    function setPolicy(bytes32 agentId, PolicyLib.Policy calldata policy) external;
    function revokePolicy(bytes32 agentId) external;
    function enforce(bytes32 agentId, uint128 amount, address payee)
        external returns (bool requiresApproval);
    function getPolicy(bytes32 agentId) external view returns (PolicyLib.Policy memory);
    function getSpendRecord(bytes32 agentId) external view returns (PolicyLib.SpendRecord memory);
}