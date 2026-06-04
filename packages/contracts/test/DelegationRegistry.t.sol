// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/core/DelegationRegistry.sol";
import "../src/interfaces/IDelegationRegistry.sol";
import "../src/libraries/DelegationLib.sol";

/// @title  DelegationRegistryTest
/// @notice Full test suite for DelegationRegistry.sol
///
///         Tree used in multi-level tests:
///
///           agentA (root, depth 0)
///             ├── agentB (depth 1, 200 USDC from A)
///             │     └── agentD (depth 2, 50 USDC from B)
///             └── agentC (depth 1, 100 USDC from A)
///
///         Run: forge test --match-contract DelegationRegistryTest -vvv
///
contract DelegationRegistryTest is Test {

    // ── Contracts ─────────────────────────────────────────────────
    DelegationRegistry public registry;

    // ── Actors ────────────────────────────────────────────────────
    address public admin  = makeAddr("admin");
    address public randos = makeAddr("randos");

    // ── Agent IDs ─────────────────────────────────────────────────
    bytes32 public agentA;
    bytes32 public agentB;
    bytes32 public agentC;
    bytes32 public agentD;
    bytes32 public agentE;

    // ── USDC amounts (6 decimals) ─────────────────────────────────
    uint128 constant ONE_USDC      = 1_000_000;
    uint128 constant FIVE_USDC     = 5_000_000;
    uint128 constant TEN_USDC      = 10_000_000;
    uint128 constant FIFTY_USDC    = 50_000_000;
    uint128 constant HUNDRED_USDC  = 100_000_000;
    uint128 constant TWO_HUNDRED   = 200_000_000;
    uint128 constant THOUSAND_USDC = 1_000_000_000;

    // ─────────────────────────────────────────────────────────────
    // SETUP
    // ─────────────────────────────────────────────────────────────

    function setUp() public {
        registry = new DelegationRegistry(admin);

        agentA = keccak256("agentA");
        agentB = keccak256("agentB");
        agentC = keccak256("agentC");
        agentD = keccak256("agentD");
        agentE = keccak256("agentE");

        // Grant test contract SPENDER_ROLE so tests can call checkAndRecordSpend
        vm.prank(admin);
        registry.grantRole(registry.SPENDER_ROLE(), address(this));

        // Grant test contract REVOKER_ROLE so tests can call revoke
        vm.prank(admin);
        registry.grantRole(registry.REVOKER_ROLE(), address(this));
    }

    // ─────────────────────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────────────────────

    /// @dev Build the full A->B->D + A->C tree in one call.
    function _buildTree() internal returns (bytes32 delAB, bytes32 delAC, bytes32 delBD) {
        vm.startPrank(admin);
        registry.registerRootAgent(agentA);
        registry.registerRootAgent(agentB);
        registry.registerRootAgent(agentC);
        registry.registerRootAgent(agentD);
        delAB = registry.delegate(agentA, agentB, TWO_HUNDRED,  0);
        delAC = registry.delegate(agentA, agentC, HUNDRED_USDC, 0);
        delBD = registry.delegate(agentB, agentD, FIFTY_USDC,   0);
        vm.stopPrank();
    }

    /// @dev Register two agents and delegate from parent to child.
    function _simpleDelegation(
        bytes32 parentId,
        bytes32 childId,
        uint128 budget
    ) internal returns (bytes32 delegationId) {
        vm.startPrank(admin);
        registry.registerRootAgent(parentId);
        registry.registerRootAgent(childId);
        delegationId = registry.delegate(parentId, childId, budget, 0);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────

    function test_constructor_adminHasDefaultAdminRole() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_constructor_adminHasRegistryAdminRole() public view {
        assertTrue(registry.hasRole(registry.REGISTRY_ADMIN_ROLE(), admin));
    }

    function test_constructor_randosHaveNoRoles() public view {
        assertFalse(registry.hasRole(registry.REGISTRY_ADMIN_ROLE(), randos));
        assertFalse(registry.hasRole(registry.REVOKER_ROLE(),         randos));
        assertFalse(registry.hasRole(registry.SPENDER_ROLE(),         randos));
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(IDelegationRegistry.ZeroAdmin.selector);
        new DelegationRegistry(address(0));
    }

    // ─────────────────────────────────────────────────────────────
    // registerRootAgent
    // ─────────────────────────────────────────────────────────────

    function test_registerRootAgent_setsNodeCorrectly() public {
        vm.prank(admin);
        registry.registerRootAgent(agentA);

        DelegationLib.AgentNode memory node = registry.getAgentNode(agentA);
        assertEq(node.parentDelegationId, bytes32(0));
        assertEq(node.depth,              0);
        assertTrue(node.exists);
        assertEq(node.childDelegationIds.length, 0);
    }

    function test_registerRootAgent_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit IDelegationRegistry.RootAgentRegistered(agentA);

        vm.prank(admin);
        registry.registerRootAgent(agentA);
    }

    function test_registerRootAgent_isRegistered() public {
        vm.prank(admin);
        registry.registerRootAgent(agentA);
        assertTrue(registry.isRegistered(agentA));
    }

    function test_registerRootAgent_isRootAgent() public {
        vm.prank(admin);
        registry.registerRootAgent(agentA);
        assertTrue(registry.isRootAgent(agentA));
    }

    function test_registerRootAgent_revertsOnZeroId() public {
        vm.prank(admin);
        vm.expectRevert(IDelegationRegistry.ZeroAgentId.selector);
        registry.registerRootAgent(bytes32(0));
    }

    function test_registerRootAgent_revertsIfAlreadyRegistered() public {
        vm.startPrank(admin);
        registry.registerRootAgent(agentA);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDelegationRegistry.AgentAlreadyRegistered.selector,
                agentA
            )
        );
        registry.registerRootAgent(agentA);
        vm.stopPrank();
    }

    function test_registerRootAgent_revertsWithoutRole() public {
        vm.prank(randos);
        vm.expectRevert();
        registry.registerRootAgent(agentA);
    }

    // ─────────────────────────────────────────────────────────────
    // delegate — success cases
    // ─────────────────────────────────────────────────────────────

    function test_delegate_createsCorrectStruct() public {
        bytes32 delId = _simpleDelegation(agentA, agentB, TWO_HUNDRED);

        DelegationLib.Delegation memory d = registry.getDelegation(delId);
        assertEq(d.parentId,        agentA);
        assertEq(d.childId,         agentB);
        assertEq(d.allocatedBudget, TWO_HUNDRED);
        assertEq(d.spentAmount,     0);
        assertEq(d.expiresAt,       0);
        assertTrue(d.active);
        assertTrue(d.exists);
    }

    function test_delegate_updatesParentChildArray() public {
        bytes32 delId = _simpleDelegation(agentA, agentB, TWO_HUNDRED);

        bytes32[] memory children = registry.getChildDelegations(agentA);
        assertEq(children.length, 1);
        assertEq(children[0],     delId);
    }

    function test_delegate_setsChildParentDelegationId() public {
        bytes32 delId = _simpleDelegation(agentA, agentB, TWO_HUNDRED);

        DelegationLib.AgentNode memory childNode = registry.getAgentNode(agentB);
        assertEq(childNode.parentDelegationId, delId);
    }

    function test_delegate_setsChildDepth() public {
        _simpleDelegation(agentA, agentB, TWO_HUNDRED);

        DelegationLib.AgentNode memory childNode = registry.getAgentNode(agentB);
        assertEq(childNode.depth, 1);
    }

    function test_delegate_childIsNotRootAgent() public {
        _simpleDelegation(agentA, agentB, TWO_HUNDRED);
        assertFalse(registry.isRootAgent(agentB));
    }

    function test_delegate_multipleChildrenFromSameParent() public {
        vm.startPrank(admin);
        registry.registerRootAgent(agentA);
        registry.registerRootAgent(agentB);
        registry.registerRootAgent(agentC);
        bytes32 d1 = registry.delegate(agentA, agentB, HUNDRED_USDC, 0);
        bytes32 d2 = registry.delegate(agentA, agentC, HUNDRED_USDC, 0);
        vm.stopPrank();

        bytes32[] memory children = registry.getChildDelegations(agentA);
        assertEq(children.length, 2);
        assertEq(children[0],     d1);
        assertEq(children[1],     d2);
    }

    function test_delegate_depthIncrementsCorrectly() public {
        vm.startPrank(admin);
        registry.registerRootAgent(agentA);
        registry.registerRootAgent(agentB);
        registry.registerRootAgent(agentD);
        registry.delegate(agentA, agentB, TWO_HUNDRED, 0);
        registry.delegate(agentB, agentD, FIFTY_USDC,  0);
        vm.stopPrank();

        assertEq(registry.getAgentNode(agentA).depth, 0);
        assertEq(registry.getAgentNode(agentB).depth, 1);
        assertEq(registry.getAgentNode(agentD).depth, 2);
    }

    function test_delegate_rootParentCanDelegateFreely() public {
        vm.startPrank(admin);
        registry.registerRootAgent(agentA);
        registry.registerRootAgent(agentB);
        registry.delegate(agentA, agentB, THOUSAND_USDC, 0);
        vm.stopPrank();

        assertEq(registry.getRemainingBudget(agentB), THOUSAND_USDC);
    }

    function test_delegate_withExpiryTimestamp() public {
        uint48 expiry = uint48(block.timestamp + 7 days);

        vm.startPrank(admin);
        registry.registerRootAgent(agentA);
        registry.registerRootAgent(agentB);
        bytes32 delId = registry.delegate(agentA, agentB, HUNDRED_USDC, expiry);
        vm.stopPrank();

        DelegationLib.Delegation memory d = registry.getDelegation(delId);
        assertEq(d.expiresAt, expiry);
    }

    // ─────────────────────────────────────────────────────────────
    // delegate — revert cases
    // ─────────────────────────────────────────────────────────────

    function test_delegate_revertsOnZeroParentId() public {
        vm.prank(admin);
        registry.registerRootAgent(agentB);

        vm.prank(admin);
        vm.expectRevert(IDelegationRegistry.ZeroAgentId.selector);
        registry.delegate(bytes32(0), agentB, HUNDRED_USDC, 0);
    }

    function test_delegate_revertsOnZeroChildId() public {
        vm.prank(admin);
        registry.registerRootAgent(agentA);

        vm.prank(admin);
        vm.expectRevert(IDelegationRegistry.ZeroAgentId.selector);
        registry.delegate(agentA, bytes32(0), HUNDRED_USDC, 0);
    }

    function test_delegate_revertsOnZeroBudget() public {
        vm.startPrank(admin);
        registry.registerRootAgent(agentA);
        registry.registerRootAgent(agentB);

        vm.expectRevert(IDelegationRegistry.ZeroBudget.selector);
        registry.delegate(agentA, agentB, 0, 0);
        vm.stopPrank();
    }

    function test_delegate_revertsOnSelfDelegation() public {
        vm.prank(admin);
        registry.registerRootAgent(agentA);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDelegationRegistry.CannotDelegateToSelf.selector,
                agentA
            )
        );
        registry.delegate(agentA, agentA, HUNDRED_USDC, 0);
    }

    function test_delegate_revertsIfParentNotRegistered() public {
        vm.prank(admin);
        registry.registerRootAgent(agentB);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDelegationRegistry.AgentNotRegistered.selector,
                agentA
            )
        );
        registry.delegate(agentA, agentB, HUNDRED_USDC, 0);
    }

    function test_delegate_revertsIfChildNotRegistered() public {
        vm.prank(admin);
        registry.registerRootAgent(agentA);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDelegationRegistry.AgentNotRegistered.selector,
                agentB
            )
        );
        registry.delegate(agentA, agentB, HUNDRED_USDC, 0);
    }

    function test_delegate_revertsIfChildAlreadyHasParent() public {
        _simpleDelegation(agentA, agentB, HUNDRED_USDC);

        vm.startPrank(admin);
        registry.registerRootAgent(agentC);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDelegationRegistry.ChildAlreadyHasDelegation.selector,
                agentB
            )
        );
        registry.delegate(agentC, agentB, FIFTY_USDC, 0);
        vm.stopPrank();
    }

    function test_delegate_revertsWhenMaxDepthExceeded() public {
        bytes32 agentF = keccak256("agentF");

        vm.startPrank(admin);
        registry.registerRootAgent(agentA);
        registry.registerRootAgent(agentB);
        registry.registerRootAgent(agentC);
        registry.registerRootAgent(agentD);
        registry.registerRootAgent(agentE);
        registry.registerRootAgent(agentF);

        registry.delegate(agentA, agentB, HUNDRED_USDC, 0); // depth 1
        registry.delegate(agentB, agentC, FIFTY_USDC,   0); // depth 2
        registry.delegate(agentC, agentD, TEN_USDC,     0); // depth 3
        registry.delegate(agentD, agentE, FIVE_USDC,    0); // depth 4 = MAX

        vm.expectRevert(
            abi.encodeWithSelector(
                IDelegationRegistry.MaxDepthExceeded.selector,
                agentE,
                DelegationLib.MAX_DEPTH
            )
        );
        registry.delegate(agentE, agentF, ONE_USDC, 0);
        vm.stopPrank();
    }

    function test_delegate_revertsWhenMaxChildrenExceeded() public {
        vm.startPrank(admin);
        registry.registerRootAgent(agentA);

        for (uint256 i = 0; i < 10; i++) {
            bytes32 childId = keccak256(abi.encodePacked("child", i));
            registry.registerRootAgent(childId);
            registry.delegate(agentA, childId, ONE_USDC, 0);
        }

        bytes32 eleventhChild = keccak256("child11");
        registry.registerRootAgent(eleventhChild);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDelegationRegistry.MaxChildrenExceeded.selector,
                agentA,
                DelegationLib.MAX_CHILDREN
            )
        );
        registry.delegate(agentA, eleventhChild, ONE_USDC, 0);
        vm.stopPrank();
    }

    function test_delegate_revertsWithoutRole() public {
        vm.startPrank(admin);
        registry.registerRootAgent(agentA);
        registry.registerRootAgent(agentB);
        vm.stopPrank();

        vm.prank(randos);
        vm.expectRevert();
        registry.delegate(agentA, agentB, HUNDRED_USDC, 0);
    }

    // ─────────────────────────────────────────────────────────────
    // revoke
    // ─────────────────────────────────────────────────────────────

    function test_revoke_setsActiveFalse() public {
        bytes32 delId = _simpleDelegation(agentA, agentB, HUNDRED_USDC);

        registry.revoke(delId);

        assertFalse(registry.getDelegation(delId).active);
    }

    function test_revoke_preservesExistsFlag() public {
        bytes32 delId = _simpleDelegation(agentA, agentB, HUNDRED_USDC);

        registry.revoke(delId);

        assertTrue(registry.getDelegation(delId).exists);
    }

    function test_revoke_preservesSpendHistory() public {
        bytes32 delId = _simpleDelegation(agentA, agentB, HUNDRED_USDC);

        registry.checkAndRecordSpend(agentB, TEN_USDC);
        registry.revoke(delId);

        DelegationLib.Delegation memory d = registry.getDelegation(delId);
        assertEq(d.spentAmount, TEN_USDC);
        assertFalse(d.active);
    }

    function test_revoke_emitsDelegationRevoked() public {
        bytes32 delId = _simpleDelegation(agentA, agentB, HUNDRED_USDC);

        vm.expectEmit(true, true, true, false);
        emit IDelegationRegistry.DelegationRevoked(delId, agentA, agentB);

        registry.revoke(delId);
    }

    function test_revoke_revertsOnUnknownDelegation() public {
        bytes32 ghost = keccak256("ghost");

        vm.expectRevert(
            abi.encodeWithSelector(
                IDelegationRegistry.DelegationNotFound.selector,
                ghost
            )
        );
        registry.revoke(ghost);
    }

    function test_revoke_revertsIfAlreadyRevoked() public {
        bytes32 delId = _simpleDelegation(agentA, agentB, HUNDRED_USDC);

        registry.revoke(delId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDelegationRegistry.DelegationNotActive.selector,
                delId
            )
        );
        registry.revoke(delId);
    }

    function test_revoke_revertsWithoutRole() public {
        bytes32 delId = _simpleDelegation(agentA, agentB, HUNDRED_USDC);

        vm.prank(randos);
        vm.expectRevert();
        registry.revoke(delId);
    }

    // ─────────────────────────────────────────────────────────────
    // checkAndRecordSpend — root agent (no-op)
    // ─────────────────────────────────────────────────────────────

    function test_checkAndRecordSpend_rootAgentIsNoOp() public {
        vm.prank(admin);
        registry.registerRootAgent(agentA);

        registry.checkAndRecordSpend(agentA, HUNDRED_USDC);

        assertEq(registry.getRemainingBudget(agentA), type(uint128).max);
    }

    // ─────────────────────────────────────────────────────────────
    // checkAndRecordSpend — single level (A -> B)
    // ─────────────────────────────────────────────────────────────

    function test_checkAndRecordSpend_singleLevel_recordsSpend() public {
        bytes32 delId = _simpleDelegation(agentA, agentB, HUNDRED_USDC);

        registry.checkAndRecordSpend(agentB, TEN_USDC);

        assertEq(registry.getDelegation(delId).spentAmount, TEN_USDC);
    }

    function test_checkAndRecordSpend_singleLevel_remainingDecreases() public {
        _simpleDelegation(agentA, agentB, HUNDRED_USDC);

        registry.checkAndRecordSpend(agentB, TEN_USDC);

        assertEq(registry.getRemainingBudget(agentB), HUNDRED_USDC - TEN_USDC);
    }

    function test_checkAndRecordSpend_singleLevel_emitsSpendRecorded() public {
        bytes32 delId = _simpleDelegation(agentA, agentB, HUNDRED_USDC);

        vm.expectEmit(true, true, false, true);
        emit IDelegationRegistry.SpendRecorded(delId, agentB, TEN_USDC);

        registry.checkAndRecordSpend(agentB, TEN_USDC);
    }

    function test_checkAndRecordSpend_singleLevel_exactBudget() public {
        _simpleDelegation(agentA, agentB, TEN_USDC);

        registry.checkAndRecordSpend(agentB, TEN_USDC);

        assertEq(registry.getRemainingBudget(agentB), 0);
    }

    function test_checkAndRecordSpend_singleLevel_multipleSpends() public {
        _simpleDelegation(agentA, agentB, HUNDRED_USDC);

        registry.checkAndRecordSpend(agentB, TEN_USDC);
        registry.checkAndRecordSpend(agentB, TEN_USDC);
        registry.checkAndRecordSpend(agentB, TEN_USDC);

        assertEq(registry.getRemainingBudget(agentB), HUNDRED_USDC - TEN_USDC * 3);
    }

    // ─────────────────────────────────────────────────────────────
    // checkAndRecordSpend — cascade (A -> B -> D)
    // ─────────────────────────────────────────────────────────────

    function test_cascade_spendFromDUpdatesB() public {
        (, , bytes32 delBD) = _buildTree();
        bytes32 delAB = registry.getAgentNode(agentB).parentDelegationId;

        registry.checkAndRecordSpend(agentD, TEN_USDC);

        assertEq(registry.getDelegation(delBD).spentAmount, TEN_USDC);
        assertEq(registry.getDelegation(delAB).spentAmount, TEN_USDC);
    }

    function test_cascade_doesNotAffectSibling() public {
        _buildTree();
        bytes32 delAC = registry.getAgentNode(agentC).parentDelegationId;

        registry.checkAndRecordSpend(agentB, TEN_USDC);

        assertEq(registry.getDelegation(delAC).spentAmount, 0);
    }

    function test_cascade_emitsSpendRecordedForEachLevel() public {
        (, , bytes32 delBD) = _buildTree();
        bytes32 delAB = registry.getAgentNode(agentB).parentDelegationId;

        vm.expectEmit(true, true, false, true);
        emit IDelegationRegistry.SpendRecorded(delBD, agentD, TEN_USDC);

        vm.expectEmit(true, true, false, true);
        emit IDelegationRegistry.SpendRecorded(delAB, agentD, TEN_USDC);

        registry.checkAndRecordSpend(agentD, TEN_USDC);
    }

    // ─────────────────────────────────────────────────────────────
    // checkAndRecordSpend — revert cases
    // ─────────────────────────────────────────────────────────────

    function test_checkAndRecordSpend_revertsOnZeroAgentId() public {
        vm.expectRevert(IDelegationRegistry.ZeroAgentId.selector);
        registry.checkAndRecordSpend(bytes32(0), TEN_USDC);
    }

    function test_checkAndRecordSpend_revertsIfAgentNotRegistered() public {
        bytes32 ghost = keccak256("ghost");
        vm.expectRevert(
            abi.encodeWithSelector(
                IDelegationRegistry.AgentNotRegistered.selector,
                ghost
            )
        );
        registry.checkAndRecordSpend(ghost, TEN_USDC);
    }

    function test_checkAndRecordSpend_revertsWhenRevoked() public {
        bytes32 delId = _simpleDelegation(agentA, agentB, HUNDRED_USDC);

        registry.revoke(delId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDelegationRegistry.DelegationNotActive.selector,
                delId
            )
        );
        registry.checkAndRecordSpend(agentB, TEN_USDC);
    }

    function test_checkAndRecordSpend_revertsWhenExpired() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);

        vm.startPrank(admin);
        registry.registerRootAgent(agentA);
        registry.registerRootAgent(agentB);
        bytes32 delId = registry.delegate(agentA, agentB, HUNDRED_USDC, expiry);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDelegationRegistry.DelegationExpired.selector,
                delId
            )
        );
        registry.checkAndRecordSpend(agentB, TEN_USDC);
    }

    function test_checkAndRecordSpend_revertsWhenExceedsOwnBudget() public {
        bytes32 delId = _simpleDelegation(agentA, agentB, TEN_USDC);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDelegationRegistry.InsufficientDelegatedBudget.selector,
                delId,
                TEN_USDC,
                TEN_USDC + ONE_USDC
            )
        );
        registry.checkAndRecordSpend(agentB, TEN_USDC + ONE_USDC);
    }

    function test_checkAndRecordSpend_revertsWhenAncestorExhausted() public {
        _buildTree();
        bytes32 delAB = registry.getAgentNode(agentB).parentDelegationId;

        // Exhaust B (200 USDC) by spending directly
        registry.checkAndRecordSpend(agentB, TWO_HUNDRED - TEN_USDC); // 190 spent, 10 left

        // D tries 20 — D has 50 remaining but B only has 10 left
        vm.expectRevert(
            abi.encodeWithSelector(
                IDelegationRegistry.InsufficientDelegatedBudget.selector,
                delAB,
                TEN_USDC,
                TEN_USDC * 2
            )
        );
        registry.checkAndRecordSpend(agentD, TEN_USDC * 2);
    }

    function test_checkAndRecordSpend_atomicity_noPartialWrite() public {
        (, , bytes32 delBD) = _buildTree();

        // Exhaust B completely
        registry.checkAndRecordSpend(agentB, TWO_HUNDRED);

        // D tries to spend — should revert
        try registry.checkAndRecordSpend(agentD, TEN_USDC) {
            revert("expected revert");
        } catch {
            // D's own delegation was NOT written
            assertEq(registry.getDelegation(delBD).spentAmount, 0);
        }
    }

    function test_checkAndRecordSpend_revertsWithoutSpenderRole() public {
        _simpleDelegation(agentA, agentB, HUNDRED_USDC);

        vm.prank(randos);
        vm.expectRevert();
        registry.checkAndRecordSpend(agentB, TEN_USDC);
    }

    // ─────────────────────────────────────────────────────────────
    // getRemainingBudget
    // ─────────────────────────────────────────────────────────────

    function test_getRemainingBudget_rootReturnsMaxUint() public {
        vm.prank(admin);
        registry.registerRootAgent(agentA);

        assertEq(registry.getRemainingBudget(agentA), type(uint128).max);
    }

    function test_getRemainingBudget_freshDelegationIsFullBudget() public {
        _simpleDelegation(agentA, agentB, HUNDRED_USDC);
        assertEq(registry.getRemainingBudget(agentB), HUNDRED_USDC);
    }

    function test_getRemainingBudget_decreasesAfterSpend() public {
        _simpleDelegation(agentA, agentB, HUNDRED_USDC);

        registry.checkAndRecordSpend(agentB, TEN_USDC);
        assertEq(registry.getRemainingBudget(agentB), HUNDRED_USDC - TEN_USDC);
    }

    function test_getRemainingBudget_zeroAfterFullSpend() public {
        _simpleDelegation(agentA, agentB, TEN_USDC);

        registry.checkAndRecordSpend(agentB, TEN_USDC);
        assertEq(registry.getRemainingBudget(agentB), 0);
    }

    function test_getRemainingBudget_revertsForUnknownAgent() public {
        bytes32 ghost = keccak256("ghost");
        vm.expectRevert(
            abi.encodeWithSelector(
                IDelegationRegistry.AgentNotRegistered.selector,
                ghost
            )
        );
        registry.getRemainingBudget(ghost);
    }

    // ─────────────────────────────────────────────────────────────
    // isRootAgent / isRegistered / getChildDelegations
    // ─────────────────────────────────────────────────────────────

    function test_isRootAgent_trueForRoot() public {
        vm.prank(admin);
        registry.registerRootAgent(agentA);
        assertTrue(registry.isRootAgent(agentA));
    }

    function test_isRootAgent_falseForChild() public {
        _simpleDelegation(agentA, agentB, HUNDRED_USDC);
        assertFalse(registry.isRootAgent(agentB));
    }

    function test_isRootAgent_falseForUnregistered() public view {
        assertFalse(registry.isRootAgent(agentA));
    }

    function test_isRegistered_falseBeforeRegistration() public view {
        assertFalse(registry.isRegistered(agentA));
    }

    function test_isRegistered_trueAfterRegister() public {
        vm.prank(admin);
        registry.registerRootAgent(agentA);
        assertTrue(registry.isRegistered(agentA));
    }

    function test_getChildDelegations_emptyForFreshRoot() public {
        vm.prank(admin);
        registry.registerRootAgent(agentA);
        assertEq(registry.getChildDelegations(agentA).length, 0);
    }

    function test_getChildDelegations_growsWithEachChild() public {
        vm.startPrank(admin);
        registry.registerRootAgent(agentA);
        registry.registerRootAgent(agentB);
        registry.registerRootAgent(agentC);
        registry.registerRootAgent(agentD);
        vm.stopPrank();

        assertEq(registry.getChildDelegations(agentA).length, 0);

        vm.prank(admin); registry.delegate(agentA, agentB, HUNDRED_USDC, 0);
        assertEq(registry.getChildDelegations(agentA).length, 1);

        vm.prank(admin); registry.delegate(agentA, agentC, HUNDRED_USDC, 0);
        assertEq(registry.getChildDelegations(agentA).length, 2);

        vm.prank(admin); registry.delegate(agentA, agentD, HUNDRED_USDC, 0);
        assertEq(registry.getChildDelegations(agentA).length, 3);
    }

    // ─────────────────────────────────────────────────────────────
    // FULL TREE SCENARIO
    // ─────────────────────────────────────────────────────────────

    function test_fullTree_scenario() public {
        (bytes32 delAB, bytes32 delAC, bytes32 delBD) = _buildTree();

        // D spends 30
        registry.checkAndRecordSpend(agentD, TEN_USDC * 3);
        assertEq(registry.getDelegation(delBD).spentAmount, TEN_USDC * 3);
        assertEq(registry.getDelegation(delAB).spentAmount, TEN_USDC * 3);
        assertEq(registry.getDelegation(delAC).spentAmount, 0);

        // B spends 20 directly
        registry.checkAndRecordSpend(agentB, TEN_USDC * 2);
        assertEq(registry.getDelegation(delAB).spentAmount, TEN_USDC * 5);
        assertEq(registry.getDelegation(delBD).spentAmount, TEN_USDC * 3); // unchanged

        // C spends 80
        registry.checkAndRecordSpend(agentC, TEN_USDC * 8);
        assertEq(registry.getDelegation(delAC).spentAmount, TEN_USDC * 8);

        // Remaining budgets
        assertEq(registry.getRemainingBudget(agentB), TWO_HUNDRED  - TEN_USDC * 5);
        assertEq(registry.getRemainingBudget(agentC), HUNDRED_USDC - TEN_USDC * 8);
        assertEq(registry.getRemainingBudget(agentD), FIFTY_USDC   - TEN_USDC * 3);

        // D tries to overspend — only 20 remaining
        vm.expectRevert();
        registry.checkAndRecordSpend(agentD, TEN_USDC * 3);

        // D spends exactly remaining 20 — passes
        registry.checkAndRecordSpend(agentD, TEN_USDC * 2);
        assertEq(registry.getRemainingBudget(agentD), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // FUZZ TESTS
    // ─────────────────────────────────────────────────────────────

    function testFuzz_checkAndRecordSpend_anyValidAmount(uint128 amount) public {
        _simpleDelegation(agentA, agentB, HUNDRED_USDC);

        amount = uint128(bound(amount, 1, HUNDRED_USDC));

        registry.checkAndRecordSpend(agentB, amount);

        assertEq(registry.getRemainingBudget(agentB), HUNDRED_USDC - amount);
    }

    function testFuzz_checkAndRecordSpend_revertsAboveBudget(uint128 excess) public {
        _simpleDelegation(agentA, agentB, HUNDRED_USDC);

        excess = uint128(bound(excess, 1, type(uint128).max - HUNDRED_USDC));

        vm.expectRevert();
        registry.checkAndRecordSpend(agentB, HUNDRED_USDC + excess);
    }
}