// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/core/PolicyEngine.sol";
import "../src/libraries/PolicyLib.sol";

contract PolicyEngineTest is Test {

    PolicyEngine public engine;

    // test accounts
    address public owner   = makeAddr("owner");
    address public agent   = makeAddr("agent");
    address public payee   = makeAddr("payee");
    address public randos  = makeAddr("randos");

    bytes32 public agentId;

    // ─── Setup ────────────────────────────────────────────────────
    function setUp() public {
        engine  = new PolicyEngine(owner);
        agentId = keccak256(abi.encodePacked(agent, uint256(84532)));
    }

    // helper: build a basic policy
    function _basicPolicy() internal pure returns (PolicyLib.Policy memory) {
        address[] memory payees = new address[](0); // allow all
        return PolicyLib.Policy({
            maxPerTransaction:    10_000_000,   // 10 USDC
            maxPerDay:           100_000_000,   // 100 USDC
            maxPerHour:           50_000_000,   // 50 USDC
            requireApprovalAbove: 8_000_000,    // 8 USDC needs approval
            expiresAt:            0,            // never expires
            active:               true,
            exists:               true,
            allowedPayees:        payees
        });
    }

    // ─── setPolicy ────────────────────────────────────────────────
    function test_setPolicy_works() public {
        vm.prank(owner);
        engine.setPolicy(agentId, _basicPolicy());

        PolicyLib.Policy memory p = engine.getPolicy(agentId);
        assertEq(p.maxPerTransaction, 10_000_000);
        assertEq(p.active, true);
    }

    function test_setPolicy_revertsIfNotOwner() public {
        vm.prank(randos);
        vm.expectRevert();
        engine.setPolicy(agentId, _basicPolicy());
    }
    function test_setPolicy_revertsInvalidPolicy() public {
    PolicyLib.Policy memory p = _basicPolicy();

    // Invalid:
    // maxPerTransaction > maxPerHour
    p.maxPerTransaction = 60_000_000;
    p.maxPerHour = 50_000_000;

    vm.prank(owner);

    vm.expectRevert(
        IPolicyEngine.InvalidPolicy.selector
    );

    engine.setPolicy(agentId, p);
}

    // ─── enforce: happy path ──────────────────────────────────────
    function test_enforce_smallPayment_passes() public {
        vm.prank(owner);
        engine.setPolicy(agentId, _basicPolicy());

        // 5 USDC — under all limits, no approval needed
        bool needsApproval = engine.enforce(agentId, 5_000_000, payee);
        assertFalse(needsApproval);
    }

    function test_enforce_aboveApprovalThreshold_flagged() public {
        vm.prank(owner);
        engine.setPolicy(agentId, _basicPolicy());

        // 9 USDC — under per-tx limit but above approval threshold
        bool needsApproval = engine.enforce(agentId, 9_000_000, payee);
        assertTrue(needsApproval);
    }

    // ─── enforce: per-tx limit ────────────────────────────────────
    function test_enforce_revertsWhenExceedsPerTxLimit() public {
        vm.prank(owner);
        engine.setPolicy(agentId, _basicPolicy());

        // 11 USDC — over 10 USDC per-tx limit
        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyEngine.ExceedsPerTxLimit.selector,
                agentId, uint128(11_000_000), uint128(10_000_000)
            )
        );
        engine.enforce(agentId, 11_000_000, payee);
    }

function test_enforce_perTxLimit_exactBoundaryWorks() public {
    vm.prank(owner);
    engine.setPolicy(agentId, _basicPolicy());

    bool needsApproval =
        engine.enforce(
            agentId,
            10_000_000,
            payee
        );

    assertTrue(needsApproval);
}
    // ─── enforce: daily limit ─────────────────────────────────────
    function test_enforce_revertsWhenExceedsDailyLimit() public {
        vm.prank(owner);
        engine.setPolicy(agentId, _basicPolicy());

        // spend 90 USDC across 9 payments (fine)
        for (uint256 i = 0; i < 9; i++) {
            engine.enforce(agentId, 10_000_000, payee);
        }

        // 10th payment would push to 100 USDC — exactly at limit, still fine
        engine.enforce(agentId, 10_000_000, payee);

        // 11th — over 100 USDC daily limit
        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyEngine.ExceedsDailyLimit.selector,
                agentId, uint128(110_000_000), uint128(100_000_000)
            )
        );
        engine.enforce(agentId, 10_000_000, payee);
    }

    function test_enforce_dailyLimitResets_afterNewDay() public {
        vm.prank(owner);
        engine.setPolicy(agentId, _basicPolicy());

        // max out daily limit
        for (uint256 i = 0; i < 10; i++) {
            engine.enforce(agentId, 10_000_000, payee);
        }

        // warp forward 1 day — new day bucket
        vm.warp(block.timestamp + 1 days);

        // should work again from zero
        bool ok = engine.enforce(agentId, 10_000_000, payee);
        assertFalse(ok); // no approval needed, just checking it doesn't revert
    }

function test_enforce_dailyLimit_exactBoundaryWorks() public {
    vm.prank(owner);
    engine.setPolicy(agentId, _basicPolicy());

    // Exactly 100 USDC

    for (uint256 i = 0; i < 10; i++) {
        engine.enforce(
            agentId,
            10_000_000,
            payee
        );
    }

    PolicyLib.SpendRecord memory r =
        engine.getSpendRecord(agentId);

    assertEq(
        r.dailyAmount,
        100_000_000
    );
}
    // ─── enforce: hourly limit ────────────────────────────────────
    function test_enforce_revertsWhenExceedsHourlyLimit() public {
        vm.prank(owner);
        engine.setPolicy(agentId, _basicPolicy());

        // spend 50 USDC in one hour (5x 10 USDC — hits hourly limit)
        for (uint256 i = 0; i < 5; i++) {
            engine.enforce(agentId, 10_000_000, payee);
        }

        // next one busts the 50 USDC hourly limit
        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyEngine.ExceedsHourlyLimit.selector,
                agentId, uint128(60_000_000), uint128(50_000_000)
            )
        );
        engine.enforce(agentId, 10_000_000, payee);
    }

    function test_enforce_hourlyLimitResets_afterNewHour() public {
        vm.prank(owner);
        engine.setPolicy(agentId, _basicPolicy());

        // max out hourly
        for (uint256 i = 0; i < 5; i++) {
            engine.enforce(agentId, 10_000_000, payee);
        }

        // warp 1 hour
        vm.warp(block.timestamp + 1 hours);

        // works again
        engine.enforce(agentId, 10_000_000, payee);
    }

    // ─── enforce: payee whitelist ─────────────────────────────────
    function test_enforce_revertsWhenPayeeNotAllowed() public {
        address[] memory allowed = new address[](1);
        allowed[0] = payee;

        PolicyLib.Policy memory p = _basicPolicy();
        p.allowedPayees = allowed;

        vm.prank(owner);
        engine.setPolicy(agentId, p);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyEngine.PayeeNotAllowed.selector,
                agentId, randos
            )
        );
        engine.enforce(agentId, 1_000_000, randos);
    }

    // ─── enforce: inactive / expired ─────────────────────────────
    function test_enforce_revertsWhenPolicyInactive() public {
        vm.startPrank(owner);
        engine.setPolicy(agentId, _basicPolicy());
        engine.revokePolicy(agentId);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(IPolicyEngine.PolicyInactive.selector, agentId)
        );
        engine.enforce(agentId, 1_000_000, payee);
    }

    function test_enforce_revertsWhenPolicyExpired() public {
        PolicyLib.Policy memory p = _basicPolicy();
        p.expiresAt = uint48(block.timestamp + 1 hours);

        vm.prank(owner);
        engine.setPolicy(agentId, p);

        // warp past expiry
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(
            abi.encodeWithSelector(IPolicyEngine.PolicyExpired.selector, agentId)
        );
        engine.enforce(agentId, 1_000_000, payee);
    }

    // ─── revokePolicy ─────────────────────────────────────────────
    function test_revokePolicy_works() public {
        vm.startPrank(owner);
        engine.setPolicy(agentId, _basicPolicy());
        engine.revokePolicy(agentId);
        vm.stopPrank();

        PolicyLib.Policy memory p = engine.getPolicy(agentId);
        assertFalse(p.active);
    }

    // ─── no policy set ────────────────────────────────────────────
    function test_enforce_revertsWhenNoPolicySet() public {
        bytes32 unknownAgent = keccak256("nobody");
        vm.expectRevert(
            abi.encodeWithSelector(IPolicyEngine.PolicyNotFound.selector, unknownAgent)
        );
        engine.enforce(unknownAgent, 1_000_000, payee);
    }
}