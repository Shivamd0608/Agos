// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/core/PolicyEngine.sol";
import "../src/interfaces/IPolicyEngine.sol";
import "../src/libraries/PolicyLib.sol";

/// @title  PolicyEngineTest
/// @notice Full test suite for PolicyEngine.sol
///         Tests are grouped by function, then by scenario.
///         Run: forge test --match-contract PolicyEngineTest -vvv
contract PolicyEngineTest is Test {

    // ── Contracts ─────────────────────────────────────────────────
    PolicyEngine public engine;

    // ── Actors ────────────────────────────────────────────────────
    address public admin  = makeAddr("admin");   // deployed engine, has POLICY_ADMIN_ROLE
    address public alice  = makeAddr("alice");   // agent owner
    address public payee  = makeAddr("payee");   // receives USDC
    address public payee2 = makeAddr("payee2");  // second payee for whitelist tests
    address public randos = makeAddr("randos");  // has no roles — attacker / stranger

    // ── Agent IDs ─────────────────────────────────────────────────
    bytes32 public agentId;
    bytes32 public agentId2;

    // ── USDC amounts (6 decimals) ─────────────────────────────────
    uint128 constant ONE_USDC     = 1_000_000;
    uint128 constant FIVE_USDC    = 5_000_000;
    uint128 constant TEN_USDC     = 10_000_000;
    uint128 constant FIFTY_USDC   = 50_000_000;
    uint128 constant HUNDRED_USDC = 100_000_000;

    // ─────────────────────────────────────────────────────────────
    // SETUP
    // ─────────────────────────────────────────────────────────────

    function setUp() public {
        engine   = new PolicyEngine(admin);
        agentId  = keccak256(abi.encodePacked(alice, uint256(1)));
        agentId2 = keccak256(abi.encodePacked(alice, uint256(2)));
    }

    // ─────────────────────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────────────────────

    /// @dev Build a standard valid policy. Edit fields per test.
    function _policy() internal pure returns (PolicyLib.Policy memory) {
        address[] memory payees = new address[](0); // allow all
        PolicyLib.Policy memory p;
        p.maxPerTransaction = TEN_USDC;     // 10 USDC per tx
        p.maxPerDay = HUNDRED_USDC;         // 100 USDC per day
        p.maxPerHour = FIFTY_USDC;          // 50 USDC per hour
        p.requireApprovalAbove = FIVE_USDC; // >= 5 USDC needs approval
        p.expiresAt = 0;                    // never expires
        p.active = true;
        p.allowedPayees = payees;
        return p;
    }

    /// @dev Set a policy from admin with no boilerplate.
    function _setPolicy(bytes32 id, PolicyLib.Policy memory p) internal {
        vm.prank(admin);
        engine.setPolicy(id, p);
    }

    /// @dev Call enforce() directly (no access control in your current contract).
    function _enforce(
        bytes32 id,
        uint128 amount,
        address to
    ) internal returns (bool) {
        return engine.enforce(id, amount, to);
    }

    // ─────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────

    function test_constructor_adminHasPolicyAdminRole() public view {
        assertTrue(
            engine.hasRole(engine.POLICY_ADMIN_ROLE(), admin)
        );
    }

    function test_constructor_adminHasDefaultAdminRole() public view {
        assertTrue(
            engine.hasRole(engine.DEFAULT_ADMIN_ROLE(), admin)
        );
    }

    function test_constructor_randosHasNoRole() public view {
        assertFalse(engine.hasRole(engine.POLICY_ADMIN_ROLE(), randos));
        assertFalse(engine.hasRole(engine.DEFAULT_ADMIN_ROLE(), randos));
    }

    // ─────────────────────────────────────────────────────────────
    // setPolicy — access control
    // ─────────────────────────────────────────────────────────────

    function test_setPolicy_adminCanSet() public {
        vm.prank(admin);
        engine.setPolicy(agentId, _policy());

        PolicyLib.Policy memory p = engine.getPolicy(agentId);
        assertEq(p.maxPerTransaction, TEN_USDC);
        assertTrue(p.active);
    }

    function test_setPolicy_revertsIfCallerHasNoRole() public {
        vm.prank(randos);
        vm.expectRevert(); // AccessControl revert
        engine.setPolicy(agentId, _policy());
    }

    function test_setPolicy_aliceCannotSetWithoutRole() public {
        vm.prank(alice);
        vm.expectRevert();
        engine.setPolicy(agentId, _policy());
    }

    // ─────────────────────────────────────────────────────────────
    // setPolicy — validation
    // ─────────────────────────────────────────────────────────────

    function test_setPolicy_revertsWhenPerTxExceedsPerHour() public {
        PolicyLib.Policy memory p = _policy();
        p.maxPerTransaction = HUNDRED_USDC; // bigger than maxPerHour (50)
        p.maxPerHour        = FIFTY_USDC;

        vm.prank(admin);
        vm.expectRevert(IPolicyEngine.InvalidPolicy.selector);
        engine.setPolicy(agentId, p);
    }

    function test_setPolicy_revertsWhenPerHourExceedsPerDay() public {
        PolicyLib.Policy memory p = _policy();
        p.maxPerHour = HUNDRED_USDC + ONE_USDC; // bigger than maxPerDay (100)

        vm.prank(admin);
        vm.expectRevert(IPolicyEngine.InvalidPolicy.selector);
        engine.setPolicy(agentId, p);
    }

    function test_setPolicy_allowsEqualLimits() public {
        // maxPerTransaction == maxPerHour == maxPerDay is valid (strict limit)
        PolicyLib.Policy memory p = _policy();
        p.maxPerTransaction = TEN_USDC;
        p.maxPerHour        = TEN_USDC;
        p.maxPerDay         = TEN_USDC;

        vm.prank(admin);
        engine.setPolicy(agentId, p);

        PolicyLib.Policy memory stored = engine.getPolicy(agentId);
        assertEq(stored.maxPerTransaction, TEN_USDC);
    }

    function test_setPolicy_emitsPolicySetEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IPolicyEngine.PolicySet(agentId, admin);

        vm.prank(admin);
        engine.setPolicy(agentId, _policy());
    }

    function test_setPolicy_canOverwriteExistingPolicy() public {
        // First set
        _setPolicy(agentId, _policy());

        // Overwrite with lower limit
        PolicyLib.Policy memory p2 = _policy();
        p2.maxPerTransaction = FIVE_USDC;

        vm.prank(admin);
        engine.setPolicy(agentId, p2);

        PolicyLib.Policy memory stored = engine.getPolicy(agentId);
        assertEq(stored.maxPerTransaction, FIVE_USDC);
    }

    function test_setPolicy_withPayeeWhitelist() public {
        address[] memory allowed = new address[](2);
        allowed[0] = payee;
        allowed[1] = payee2;

        PolicyLib.Policy memory p = _policy();
        p.allowedPayees = allowed;

        vm.prank(admin);
        engine.setPolicy(agentId, p);

        PolicyLib.Policy memory stored = engine.getPolicy(agentId);
        assertEq(stored.allowedPayees.length, 2);
        assertEq(stored.allowedPayees[0], payee);
        assertEq(stored.allowedPayees[1], payee2);
    }

    function test_setPolicy_withExpiryTimestamp() public {
        PolicyLib.Policy memory p = _policy();
        p.expiresAt = uint48(block.timestamp + 7 days);

        _setPolicy(agentId, p);

        PolicyLib.Policy memory stored = engine.getPolicy(agentId);
        assertEq(stored.expiresAt, uint48(block.timestamp + 7 days));
    }

    // ─────────────────────────────────────────────────────────────
    // revokePolicy
    // ─────────────────────────────────────────────────────────────

    function test_revokePolicy_setsActiveToFalse() public {
        _setPolicy(agentId, _policy());

        vm.prank(admin);
        engine.revokePolicy(agentId);

        PolicyLib.Policy memory p = engine.getPolicy(agentId);
        assertFalse(p.active);
    }

    function test_revokePolicy_emitsEvent() public {
        _setPolicy(agentId, _policy());

        vm.expectEmit(true, false, false, false);
        emit IPolicyEngine.PolicyRevoked(agentId);

        vm.prank(admin);
        engine.revokePolicy(agentId);
    }

    function test_revokePolicy_revertsIfNoPolicySet() public {
        // agentId has never had a policy set
        bytes32 unknown = keccak256("ghost");

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IPolicyEngine.PolicyNotFound.selector, unknown)
        );
        engine.revokePolicy(unknown);
    }

    function test_revokePolicy_revertsIfCallerHasNoRole() public {
        _setPolicy(agentId, _policy());

        vm.prank(randos);
        vm.expectRevert();
        engine.revokePolicy(agentId);
    }

    // ─────────────────────────────────────────────────────────────
    // enforce — policy existence + state
    // ─────────────────────────────────────────────────────────────

    function test_enforce_revertsWhenNoPolicySet() public {
        bytes32 unknown = keccak256("nobody");

        vm.expectRevert(
            abi.encodeWithSelector(IPolicyEngine.PolicyNotFound.selector, unknown)
        );
        _enforce(unknown, ONE_USDC, payee);
    }

    function test_enforce_revertsWhenPolicyInactive() public {
        _setPolicy(agentId, _policy());

        vm.prank(admin);
        engine.revokePolicy(agentId);

        vm.expectRevert(
            abi.encodeWithSelector(IPolicyEngine.PolicyInactive.selector, agentId)
        );
        _enforce(agentId, ONE_USDC, payee);
    }

    function test_enforce_revertsWhenPolicyExpired() public {
        PolicyLib.Policy memory p = _policy();
        p.expiresAt = uint48(block.timestamp + 1 hours);
        _setPolicy(agentId, p);

        // Jump past expiry
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(
            abi.encodeWithSelector(IPolicyEngine.PolicyExpired.selector, agentId)
        );
        _enforce(agentId, ONE_USDC, payee);
    }

    function test_enforce_doesNotRevertAtExactExpiry() public {
        // expiresAt is exclusive: expires AFTER, not AT
        uint48 expiry = uint48(block.timestamp + 1 hours);
        PolicyLib.Policy memory p = _policy();
        p.expiresAt = expiry;
        _setPolicy(agentId, p);

        // Warp to exactly the expiry second
        vm.warp(expiry);

        // Your contract: `block.timestamp > p.expiresAt` so AT expiry is still valid
        bool ok = _enforce(agentId, ONE_USDC, payee);
        assertFalse(ok); // no approval needed for 1 USDC
    }

    function test_enforce_passesWhenNoExpirySet() public {
        // expiresAt = 0 means never expires
        _setPolicy(agentId, _policy());

        vm.warp(block.timestamp + 365 days);

        bool ok = _enforce(agentId, ONE_USDC, payee);
        assertFalse(ok);
    }

    // ─────────────────────────────────────────────────────────────
    // enforce — payee whitelist
    // ─────────────────────────────────────────────────────────────

    function test_enforce_allowsAnyPayeeWhenListEmpty() public {
        _setPolicy(agentId, _policy()); // allowedPayees is empty

        // Should not revert for any address
        _enforce(agentId, ONE_USDC, payee);
        _enforce(agentId, ONE_USDC, payee2);
        _enforce(agentId, ONE_USDC, randos);
    }

    function test_enforce_allowsWhitelistedPayee() public {
        address[] memory allowed = new address[](1);
        allowed[0] = payee;

        PolicyLib.Policy memory p = _policy();
        p.allowedPayees = allowed;
        _setPolicy(agentId, p);

        // Should pass for whitelisted payee
        _enforce(agentId, ONE_USDC, payee);
    }

    function test_enforce_revertsForNonWhitelistedPayee() public {
        address[] memory allowed = new address[](1);
        allowed[0] = payee;

        PolicyLib.Policy memory p = _policy();
        p.allowedPayees = allowed;
        _setPolicy(agentId, p);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyEngine.PayeeNotAllowed.selector,
                agentId,
                randos
            )
        );
        _enforce(agentId, ONE_USDC, randos);
    }

    function test_enforce_allowsAllPayeesInWhitelist() public {
        address[] memory allowed = new address[](2);
        allowed[0] = payee;
        allowed[1] = payee2;

        PolicyLib.Policy memory p = _policy();
        p.allowedPayees = allowed;
        _setPolicy(agentId, p);

        _enforce(agentId, ONE_USDC, payee);
        _enforce(agentId, ONE_USDC, payee2);
    }

    // ─────────────────────────────────────────────────────────────
    // enforce — per-transaction limit
    // ─────────────────────────────────────────────────────────────

    function test_enforce_passesAtExactPerTxLimit() public {
        _setPolicy(agentId, _policy()); // maxPerTransaction = 10 USDC

        // Exactly at limit — should pass
        _enforce(agentId, TEN_USDC, payee);
    }

    function test_enforce_revertsOneAbovePerTxLimit() public {
        _setPolicy(agentId, _policy()); // maxPerTransaction = 10 USDC

        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyEngine.ExceedsPerTxLimit.selector,
                agentId,
                TEN_USDC + 1,
                TEN_USDC
            )
        );
        _enforce(agentId, TEN_USDC + 1, payee);
    }

    function test_enforce_revertsWellAbovePerTxLimit() public {
        _setPolicy(agentId, _policy());

        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyEngine.ExceedsPerTxLimit.selector,
                agentId,
                HUNDRED_USDC,
                TEN_USDC
            )
        );
        _enforce(agentId, HUNDRED_USDC, payee);
    }

    // ─────────────────────────────────────────────────────────────
    // enforce — hourly limit
    // ─────────────────────────────────────────────────────────────

    function test_enforce_passesUpToHourlyLimit() public {
        _setPolicy(agentId, _policy());
        // maxPerHour = 50 USDC, maxPerTx = 10 USDC
        // 5 payments of 10 USDC = 50 USDC exactly

        for (uint256 i = 0; i < 5; i++) {
            _enforce(agentId, TEN_USDC, payee);
        }

        PolicyLib.SpendRecord memory r = engine.getSpendRecord(agentId);
        assertEq(r.hourlyAmount, FIFTY_USDC);
    }

    function test_enforce_revertsWhenHourlyLimitExceeded() public {
        _setPolicy(agentId, _policy());

        // Max out hourly limit (5 × 10 = 50 USDC)
        for (uint256 i = 0; i < 5; i++) {
            _enforce(agentId, TEN_USDC, payee);
        }

        // 6th payment would push to 60 USDC — over 50 limit
        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyEngine.ExceedsHourlyLimit.selector,
                agentId,
                FIFTY_USDC + TEN_USDC, // 60 USDC attempted
                FIFTY_USDC             // 50 USDC limit
            )
        );
        _enforce(agentId, TEN_USDC, payee);
    }

    function test_enforce_hourlyLimitResetsAfterNewHour() public {
        _setPolicy(agentId, _policy());

        // Max out hourly limit
        for (uint256 i = 0; i < 5; i++) {
            _enforce(agentId, TEN_USDC, payee);
        }

        // Warp forward 1 hour + 1 second — new hour bucket
        vm.warp(block.timestamp + 1 hours + 1);

        // Should work again — fresh hour window
        _enforce(agentId, TEN_USDC, payee);

        PolicyLib.SpendRecord memory r = engine.getSpendRecord(agentId);
        assertEq(r.hourlyAmount, TEN_USDC); // only the new payment
    }

    function test_enforce_hourlyBucketUpdatedOnReset() public {
        _setPolicy(agentId, _policy());
        _enforce(agentId, ONE_USDC, payee);

        uint32 bucket1 = engine.getSpendRecord(agentId).hourBucket;

        vm.warp(block.timestamp + 1 hours + 1);
        _enforce(agentId, ONE_USDC, payee);

        uint32 bucket2 = engine.getSpendRecord(agentId).hourBucket;

        // Bucket number must have incremented
        assertGt(bucket2, bucket1);
    }

    // ─────────────────────────────────────────────────────────────
    // enforce — daily limit
    // ─────────────────────────────────────────────────────────────

    function test_enforce_passesUpToDailyLimit() public {
        _setPolicy(agentId, _policy());
        // maxPerDay = 100 USDC, maxPerHour = 50, maxPerTx = 10
        // Spread over multiple hours to avoid hitting hourly limit

        for (uint256 day = 0; day < 2; day++) {
            // 5 payments per hour window = 50 USDC per hour
            for (uint256 tx = 0; tx < 5; tx++) {
                _enforce(agentId, TEN_USDC, payee);
            }
            // Move to next hour
            vm.warp(block.timestamp + 1 hours + 1);
        }

        PolicyLib.SpendRecord memory r = engine.getSpendRecord(agentId);
        assertEq(r.dailyAmount, HUNDRED_USDC);
    }

    function test_enforce_revertsWhenDailyLimitExceeded() public {
        _setPolicy(agentId, _policy());

        // Max out day across 2 hourly windows (50 + 50 = 100 USDC)
        for (uint256 tx = 0; tx < 5; tx++) {
            _enforce(agentId, TEN_USDC, payee);
        }
        vm.warp(block.timestamp + 1 hours + 1);
        for (uint256 tx = 0; tx < 5; tx++) {
            _enforce(agentId, TEN_USDC, payee);
        }

        // Now daily is at 100 USDC — move to new hour so hourly resets
        vm.warp(block.timestamp + 1 hours + 1);

        // But daily limit is still exhausted — should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyEngine.ExceedsDailyLimit.selector,
                agentId,
                HUNDRED_USDC + TEN_USDC, // 110 attempted
                HUNDRED_USDC             // 100 limit
            )
        );
        _enforce(agentId, TEN_USDC, payee);
    }

    function test_enforce_dailyLimitResetsAfterNewDay() public {
        _setPolicy(agentId, _policy());

        // Max out daily limit
        for (uint256 tx = 0; tx < 5; tx++) {
            _enforce(agentId, TEN_USDC, payee);
        }
        vm.warp(block.timestamp + 1 hours + 1);
        for (uint256 tx = 0; tx < 5; tx++) {
            _enforce(agentId, TEN_USDC, payee);
        }

        // Warp to next day
        vm.warp(block.timestamp + 1 days + 1);

        // Fresh day — should work
        _enforce(agentId, TEN_USDC, payee);

        PolicyLib.SpendRecord memory r = engine.getSpendRecord(agentId);
        assertEq(r.dailyAmount, TEN_USDC); // only new day's spend
    }

    function test_enforce_dailyBucketUpdatedOnReset() public {
        _setPolicy(agentId, _policy());
        _enforce(agentId, ONE_USDC, payee);

        uint32 bucket1 = engine.getSpendRecord(agentId).dayBucket;

        vm.warp(block.timestamp + 1 days + 1);
        _enforce(agentId, ONE_USDC, payee);

        uint32 bucket2 = engine.getSpendRecord(agentId).dayBucket;

        assertGt(bucket2, bucket1);
    }

    // ─────────────────────────────────────────────────────────────
    // enforce — approval threshold
    // ─────────────────────────────────────────────────────────────

    function test_enforce_returnsFalseWhenBelowThreshold() public {
        _setPolicy(agentId, _policy()); // requireApprovalAbove = 5 USDC

        // 4.99 USDC — below threshold
        bool needsApproval = _enforce(agentId, FIVE_USDC - 1, payee);
        assertFalse(needsApproval);
    }

    function test_enforce_returnsTrueAtExactThreshold() public {
        _setPolicy(agentId, _policy()); // requireApprovalAbove = 5 USDC

        // Exactly 5 USDC — at threshold, should require approval
        bool needsApproval = _enforce(agentId, FIVE_USDC, payee);
        assertTrue(needsApproval);
    }

    function test_enforce_returnsTrueAboveThreshold() public {
        _setPolicy(agentId, _policy()); // requireApprovalAbove = 5 USDC

        bool needsApproval = _enforce(agentId, TEN_USDC, payee);
        assertTrue(needsApproval);
    }

    function test_enforce_emitsApprovalRequiredWhenAboveThreshold() public {
        _setPolicy(agentId, _policy());

        vm.expectEmit(true, false, false, true);
        emit IPolicyEngine.ApprovalRequired(agentId, TEN_USDC, payee);

        _enforce(agentId, TEN_USDC, payee);
    }

    function test_enforce_emitsPaymentEnforcedWhenBelowThreshold() public {
        _setPolicy(agentId, _policy());

        vm.expectEmit(true, false, false, true);
        emit IPolicyEngine.PaymentEnforced(agentId, ONE_USDC, payee);

        _enforce(agentId, ONE_USDC, payee);
    }

    // ─────────────────────────────────────────────────────────────
    // enforce — spend record state
    // ─────────────────────────────────────────────────────────────

    function test_enforce_updatesSpendRecordAfterPayment() public {
        _setPolicy(agentId, _policy());

        _enforce(agentId, TEN_USDC, payee);

        PolicyLib.SpendRecord memory r = engine.getSpendRecord(agentId);
        assertEq(r.hourlyAmount, TEN_USDC);
        assertEq(r.dailyAmount,  TEN_USDC);
    }

    function test_enforce_accumulatesSpendAcrossMultipleCalls() public {
        _setPolicy(agentId, _policy());

        _enforce(agentId, ONE_USDC, payee);
        _enforce(agentId, ONE_USDC, payee);
        _enforce(agentId, ONE_USDC, payee);

        PolicyLib.SpendRecord memory r = engine.getSpendRecord(agentId);
        assertEq(r.hourlyAmount, ONE_USDC * 3);
        assertEq(r.dailyAmount,  ONE_USDC * 3);
    }

    function test_enforce_spendDoesNotLeakAcrossAgents() public {
        // Give both agents the same policy
        _setPolicy(agentId,  _policy());
        _setPolicy(agentId2, _policy());

        // Max out agentId
        for (uint256 i = 0; i < 5; i++) {
            _enforce(agentId, TEN_USDC, payee);
        }

        // agentId2 should still be completely fresh
        PolicyLib.SpendRecord memory r2 = engine.getSpendRecord(agentId2);
        assertEq(r2.hourlyAmount, 0);
        assertEq(r2.dailyAmount,  0);

        // And agentId2 can still spend freely
        _enforce(agentId2, TEN_USDC, payee);
    }

    // ─────────────────────────────────────────────────────────────
    // enforce — does NOT revert on success (positive path)
    // ─────────────────────────────────────────────────────────────

    function test_enforce_happyPath_smallPayment() public {
        _setPolicy(agentId, _policy());

        // 1 USDC — well under all limits
        bool needsApproval = _enforce(agentId, ONE_USDC, payee);
        assertFalse(needsApproval);
    }

    function test_enforce_happyPath_manySmallPayments() public {
        _setPolicy(agentId, _policy());

        // 10 payments of 1 USDC each — total 10 USDC
        for (uint256 i = 0; i < 10; i++) {
            _enforce(agentId, ONE_USDC, payee);
        }

        PolicyLib.SpendRecord memory r = engine.getSpendRecord(agentId);
        assertEq(r.dailyAmount, ONE_USDC * 10);
    }

    // ─────────────────────────────────────────────────────────────
    // getPolicy / getSpendRecord — view functions
    // ─────────────────────────────────────────────────────────────

    function test_getPolicy_returnsEmptyStructForUnknownAgent() public view {
        bytes32 ghost = keccak256("ghost");
        PolicyLib.Policy memory p = engine.getPolicy(ghost);
        assertEq(p.maxPerTransaction, 0);
        assertFalse(p.active);
    }

    function test_getPolicy_returnsCorrectlyAfterSet() public {
        PolicyLib.Policy memory p = _policy();
        p.maxPerTransaction = FIVE_USDC;
        _setPolicy(agentId, p);

        PolicyLib.Policy memory stored = engine.getPolicy(agentId);
        assertEq(stored.maxPerTransaction,    FIVE_USDC);
        assertEq(stored.maxPerDay,            HUNDRED_USDC);
        assertEq(stored.maxPerHour,           FIFTY_USDC);
        assertEq(stored.requireApprovalAbove, FIVE_USDC);
        assertTrue(stored.active);
    }

    function test_getSpendRecord_returnsZeroBeforeAnyEnforce() public view {
        PolicyLib.SpendRecord memory r = engine.getSpendRecord(agentId);
        assertEq(r.hourlyAmount, 0);
        assertEq(r.dailyAmount,  0);
    }

    function test_getSpendRecord_updatesAfterEnforce() public {
        _setPolicy(agentId, _policy());
        _enforce(agentId, FIVE_USDC, payee);

        PolicyLib.SpendRecord memory r = engine.getSpendRecord(agentId);
        assertEq(r.hourlyAmount, FIVE_USDC);
        assertEq(r.dailyAmount,  FIVE_USDC);
        assertGt(r.hourBucket, 0);
        assertGt(r.dayBucket,  0);
    }

    // ─────────────────────────────────────────────────────────────
    // FUZZ TESTS
    // ─────────────────────────────────────────────────────────────

    /// @dev Any amount from 1 to maxPerTransaction should pass
    ///      as long as it doesn't bust hourly or daily limits.
    function testFuzz_enforce_anyAmountUnderPerTxLimit(uint128 amount) public {
        _setPolicy(agentId, _policy());

        // Bound: 1 to maxPerTransaction (10 USDC)
        amount = uint128(bound(amount, 1, TEN_USDC));

        // Should not revert
        _enforce(agentId, amount, payee);

        PolicyLib.SpendRecord memory r = engine.getSpendRecord(agentId);
        assertEq(r.hourlyAmount, amount);
        assertEq(r.dailyAmount,  amount);
    }

    /// @dev Any amount strictly above maxPerTransaction must revert.
    function testFuzz_enforce_revertsForAnyAmountOverPerTxLimit(
        uint128 excess
    ) public {
        _setPolicy(agentId, _policy());

        // Bound: 1 above limit to a large number
        excess = uint128(bound(excess, 1, type(uint128).max - TEN_USDC));
        uint128 amount = TEN_USDC + excess;

        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyEngine.ExceedsPerTxLimit.selector,
                agentId,
                amount,
                TEN_USDC
            )
        );
        _enforce(agentId, amount, payee);
    }

    /// @dev Approval flag should be consistent with threshold.
    function testFuzz_enforce_approvalFlagMatchesThreshold(
        uint128 amount
    ) public {
        _setPolicy(agentId, _policy()); // requireApprovalAbove = 5 USDC

        // Bound to valid range (won't bust hourly/daily on first call)
        amount = uint128(bound(amount, 1, TEN_USDC));

        bool needsApproval = _enforce(agentId, amount, payee);

        if (amount >= FIVE_USDC) {
            assertTrue(needsApproval,  "should require approval above threshold");
        } else {
            assertFalse(needsApproval, "should not require approval below threshold");
        }
    }
}