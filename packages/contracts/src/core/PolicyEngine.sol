// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";

import "../interfaces/IPolicyEngine.sol";
import "../libraries/PolicyLib.sol";

/// @title PolicyEngine
/// @notice Enforces spending policies for agent wallets.
///         AgentWallet must call enforce() before every payment.
contract PolicyEngine is IPolicyEngine, AccessControl {
    using PolicyLib for PolicyLib.Policy;
    using PolicyLib for PolicyLib.SpendRecord;

    bytes32 public constant POLICY_ADMIN_ROLE =
        keccak256("POLICY_ADMIN_ROLE");

    /// @dev agentId => Policy
    mapping(bytes32 => PolicyLib.Policy)
        private _policies;

    /// @dev agentId => SpendRecord
    mapping(bytes32 => PolicyLib.SpendRecord)
        private _spendRecords;

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POLICY_ADMIN_ROLE, admin);
    }

    // ============================================================
    // WRITE FUNCTIONS
    // ============================================================

    /// @notice Create or update an agent policy
    function setPolicy(
        bytes32 agentId,
        PolicyLib.Policy calldata policy
    )
        external
        onlyRole(POLICY_ADMIN_ROLE)
    {
        // Basic sanity checks

        if (
            policy.maxPerTransaction >
            policy.maxPerHour
        ) {
            revert InvalidPolicy();
        }

        if (
            policy.maxPerHour >
            policy.maxPerDay
        ) {
            revert InvalidPolicy();
        }

        _policies[agentId] = policy;

        emit PolicySet(
            agentId,
            msg.sender
        );
    }

    /// @notice Disable a policy
    function revokePolicy(
        bytes32 agentId
    )
        external
        onlyRole(POLICY_ADMIN_ROLE)
    {
        PolicyLib.Policy storage p =
            _policies[agentId];

        if (
            p.maxPerTransaction == 0 &&
            !p.active
        ) {
            revert PolicyNotFound(agentId);
        }

        p.active = false;

        emit PolicyRevoked(agentId);
    }

    /// @notice Enforce policy before payment.
    ///         Reverts if payment violates rules.
    function enforce(
        bytes32 agentId,
        uint128 amount,
        address payee
    )
        external
        returns (bool requiresApproval)
    {
        PolicyLib.Policy storage p =
            _policies[agentId];

        PolicyLib.SpendRecord storage r =
            _spendRecords[agentId];

        // --------------------------------------------------------
        // 1. Policy must exist
        // --------------------------------------------------------

        if (
            p.maxPerTransaction == 0 &&
            !p.active
        ) {
            revert PolicyNotFound(agentId);
        }

        // --------------------------------------------------------
        // 2. Policy must be active
        // --------------------------------------------------------

        if (!p.active) {
            revert PolicyInactive(agentId);
        }

        // --------------------------------------------------------
        // 3. Policy must not be expired
        // --------------------------------------------------------

        if (p.isExpired()) {
            revert PolicyExpired(agentId);
        }

        // --------------------------------------------------------
        // 4. Payee must be allowed
        // --------------------------------------------------------

        if (
            !p.isPayeeAllowed(payee)
        ) {
            revert PayeeNotAllowed(
                agentId,
                payee
            );
        }

        // --------------------------------------------------------
        // 5. Per transaction limit
        // --------------------------------------------------------

        if (
            amount >
            p.maxPerTransaction
        ) {
            revert ExceedsPerTxLimit(
                agentId,
                amount,
                p.maxPerTransaction
            );
        }

        // --------------------------------------------------------
        // 6. Reset spend windows if needed
        // --------------------------------------------------------

        if (r.isNewHour()) {
            r.hourlyAmount = 0;
            r.hourBucket =
                PolicyLib.currentHourBucket();
        }

        if (r.isNewDay()) {
            r.dailyAmount = 0;
            r.dayBucket =
                PolicyLib.currentDayBucket();
        }

        // --------------------------------------------------------
        // 7. Hourly limit
        // --------------------------------------------------------

        uint128 newHourly =
            r.hourlyAmount + amount;

        if (
            newHourly >
            p.maxPerHour
        ) {
            revert ExceedsHourlyLimit(
                agentId,
                newHourly,
                p.maxPerHour
            );
        }

        // --------------------------------------------------------
        // 8. Daily limit
        // --------------------------------------------------------

        uint128 newDaily =
            r.dailyAmount + amount;

        if (
            newDaily >
            p.maxPerDay
        ) {
            revert ExceedsDailyLimit(
                agentId,
                newDaily,
                p.maxPerDay
            );
        }

        // --------------------------------------------------------
        // 9. Commit spend
        // --------------------------------------------------------

        r.hourlyAmount = newHourly;
        r.dailyAmount = newDaily;

        // --------------------------------------------------------
        // 10. Approval threshold
        // --------------------------------------------------------

        requiresApproval =
            amount >=
            p.requireApprovalAbove;

        if (requiresApproval) {
            emit ApprovalRequired(
                agentId,
                amount,
                payee
            );
        } else {
            emit PaymentEnforced(
                agentId,
                amount,
                payee
            );
        }
    }

    // ============================================================
    // READ FUNCTIONS
    // ============================================================

    function getPolicy(
        bytes32 agentId
    )
        external
        view
        returns (
            PolicyLib.Policy memory
        )
    {
        return _policies[agentId];
    }

    function getSpendRecord(
        bytes32 agentId
    )
        external
        view
        returns (
            PolicyLib.SpendRecord memory
        )
    {
        return _spendRecords[agentId];
    }
}