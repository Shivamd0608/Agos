// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/core/AgentWallet.sol";
import "../src/interfaces/IAgentWallet.sol";

// ────────────────────────────────────────────────────────────────
// MOCK CONTRACTS
// These live in the test file so the test is fully self-contained.
// ────────────────────────────────────────────────────────────────

/// @dev Minimal ERC-20 for USDC. Mint freely in tests.
contract MockUSDC {
    string  public name     = "USD Coin";
    string  public symbol   = "USDC";
    uint8   public decimals = 6;

    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        external returns (bool)
    {
        require(balanceOf[from]           >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "allowance");
        balanceOf[from]               -= amount;
        balanceOf[to]                 += amount;
        allowance[from][msg.sender]   -= amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Mock PolicyEngine — controllable from tests.
///      Toggle shouldBlock to simulate policy violations.
///      Toggle shouldRequireApproval to simulate approval threshold.
contract MockPolicyEngine {
    bool public shouldBlock          = false;
    bool public shouldRequireApproval = false;

    // Track calls so we can assert enforce() was actually called
    uint256 public enforceCallCount  = 0;
    bytes32 public lastAgentId;
    uint128 public lastAmount;
    address public lastPayee;

    // Simulates IPolicyEngine.enforce() signature
    function enforce(
        bytes32 agentId,
        uint128 amount,
        address payee
    ) external returns (bool requiresApproval) {
        enforceCallCount++;
        lastAgentId = agentId;
        lastAmount  = amount;
        lastPayee   = payee;

        if (shouldBlock) revert("PolicyEngine: blocked");

        return shouldRequireApproval;
    }

    // Test helpers to control behaviour
    function blockNextCall()     external { shouldBlock           = true;  }
    function unblock()           external { shouldBlock           = false; }
    function setRequiresApproval(bool v) external { shouldRequireApproval = v; }
}

// ────────────────────────────────────────────────────────────────
// TEST CONTRACT
// ────────────────────────────────────────────────────────────────

contract AgentWalletTest is Test {

    AgentWallet       public wallet;
    MockUSDC          public usdc;
    MockPolicyEngine  public policyEngine;

    address public owner   = makeAddr("owner");
    address public payee   = makeAddr("payee");
    address public randos  = makeAddr("randos");

    bytes32 public agentId;

    // 10 USDC in base units
    uint128 constant TEN_USDC     = 10_000_000;
    uint128 constant FIVE_USDC    = 5_000_000;
    uint128 constant HUNDRED_USDC = 100_000_000;

    // ── Setup ─────────────────────────────────────────────────────

    function setUp() public {
        // 1. Deploy mocks
        usdc         = new MockUSDC();
        policyEngine = new MockPolicyEngine();

        // 2. Deploy wallet
        wallet = new AgentWallet();

        // 3. Derive agentId the same way factory would
        agentId = keccak256(
            abi.encodePacked(owner, bytes32("salt1"), block.chainid)
        );

        // 4. Initialise wallet (factory does this after CREATE2 deploy)
        wallet.initialise(
            agentId,
            owner,
            address(policyEngine),
            address(usdc)
        );

        // 5. Fund the wallet with 100 USDC
        usdc.mint(address(wallet), HUNDRED_USDC);
    }

    // ── initialise() ─────────────────────────────────────────────

    function test_initialise_setsFieldsCorrectly() public view {
        assertEq(wallet.agentId(),      agentId);
        assertEq(wallet.owner(),        owner);
        assertEq(wallet.policyEngine(), address(policyEngine));
        assertEq(wallet.usdcToken(),    address(usdc));
    }

    function test_initialise_revertsIfCalledTwice() public {
        // Already initialised in setUp — calling again must revert
        vm.expectRevert();
        wallet.initialise(agentId, owner, address(policyEngine), address(usdc));
    }

    function test_initialise_revertsIfZeroOwner() public {
        AgentWallet fresh = new AgentWallet();
        vm.expectRevert();
        fresh.initialise(agentId, address(0), address(policyEngine), address(usdc));
    }

    // ── balance() ────────────────────────────────────────────────

    function test_balance_reflectsUSDCBalance() public view {
        assertEq(wallet.balance(), HUNDRED_USDC);
    }

    // ── deposit() ────────────────────────────────────────────────

    function test_deposit_increasesBalance() public {
        usdc.mint(randos, TEN_USDC);

        vm.startPrank(randos);
        usdc.approve(address(wallet), TEN_USDC);
        wallet.deposit(TEN_USDC);
        vm.stopPrank();

        // 100 (setUp) + 10 = 110 USDC
        assertEq(wallet.balance(), HUNDRED_USDC + TEN_USDC);
    }

    function test_deposit_emitsEvent() public {
        usdc.mint(randos, TEN_USDC);
        vm.startPrank(randos);
        usdc.approve(address(wallet), TEN_USDC);

        vm.expectEmit(true, false, false, true);
        emit IAgentWallet.FundsDeposited(randos, TEN_USDC);

        wallet.deposit(TEN_USDC);
        vm.stopPrank();
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.expectRevert(IAgentWallet.ZeroAmount.selector);
        wallet.deposit(0);
    }

    // ── execute() ────────────────────────────────────────────────

    function test_execute_transfersUSDCToPayee() public {
        vm.prank(owner);
        wallet.execute(payee, TEN_USDC);

        // Payee received the USDC
        assertEq(usdc.balanceOf(payee), TEN_USDC);
        // Wallet balance decreased
        assertEq(wallet.balance(), HUNDRED_USDC - TEN_USDC);
    }

    function test_execute_callsPolicyEnforce() public {
        vm.prank(owner);
        wallet.execute(payee, TEN_USDC);

        // enforce() must have been called exactly once
        assertEq(policyEngine.enforceCallCount(), 1);

        // With the correct arguments
        assertEq(policyEngine.lastAgentId(), agentId);
        assertEq(policyEngine.lastAmount(),  TEN_USDC);
        assertEq(policyEngine.lastPayee(),   payee);
    }

    function test_execute_emitsPaymentExecuted() public {
        vm.expectEmit(true, true, false, true);
        emit IAgentWallet.PaymentExecuted(payee, TEN_USDC, agentId, false);

        vm.prank(owner);
        wallet.execute(payee, TEN_USDC);
    }

    function test_execute_returnsFalseWhenNoApprovalNeeded() public {
        policyEngine.setRequiresApproval(false);

        vm.prank(owner);
        bool needsApproval = wallet.execute(payee, TEN_USDC);

        assertFalse(needsApproval);
    }

    function test_execute_returnsTrueWhenApprovalNeeded() public {
        policyEngine.setRequiresApproval(true);

        vm.prank(owner);
        bool needsApproval = wallet.execute(payee, TEN_USDC);

        assertTrue(needsApproval);
    }

    // ── execute() — policy blocks ─────────────────────────────────

    function test_execute_revertsWhenPolicyBlocks() public {
        policyEngine.blockNextCall();

        vm.prank(owner);
        // PolicyBlocked is the wallet-level error wrapping the engine revert
        vm.expectRevert(IAgentWallet.PolicyBlocked.selector);
        wallet.execute(payee, TEN_USDC);
    }

    function test_execute_doesNotTransferWhenPolicyBlocks() public {
        policyEngine.blockNextCall();

        vm.prank(owner);
        try wallet.execute(payee, TEN_USDC) {} catch {}

        // Payee received NOTHING — atomic revert
        assertEq(usdc.balanceOf(payee), 0);
        // Wallet balance unchanged
        assertEq(wallet.balance(), HUNDRED_USDC);
    }

    // ── execute() — access control ────────────────────────────────

    function test_execute_revertsIfCallerIsNotOwner() public {
        vm.prank(randos);
        vm.expectRevert(IAgentWallet.NotOwner.selector);
        wallet.execute(payee, TEN_USDC);
    }

    // ── execute() — input validation ──────────────────────────────

    function test_execute_revertsOnZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(IAgentWallet.ZeroAmount.selector);
        wallet.execute(payee, 0);
    }

    function test_execute_revertsOnZeroPayee() public {
        vm.prank(owner);
        vm.expectRevert(IAgentWallet.ZeroPayee.selector);
        wallet.execute(address(0), TEN_USDC);
    }

    function test_execute_revertsWhenInsufficientBalance() public {
        // Try to send more than the wallet holds
        uint128 tooMuch = HUNDRED_USDC + TEN_USDC;

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentWallet.InsufficientBalance.selector,
                HUNDRED_USDC,   // available
                tooMuch         // requested
            )
        );
        wallet.execute(payee, tooMuch);
    }

    // ── withdraw() ────────────────────────────────────────────────

    function test_withdraw_movesUSDCToRecipient() public {
        vm.prank(owner);
        wallet.withdraw(owner, FIVE_USDC);

        assertEq(usdc.balanceOf(owner), FIVE_USDC);
        assertEq(wallet.balance(), HUNDRED_USDC - FIVE_USDC);
    }

    function test_withdraw_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IAgentWallet.FundsWithdrawn(owner, FIVE_USDC);

        vm.prank(owner);
        wallet.withdraw(owner, FIVE_USDC);
    }

    function test_withdraw_revertsIfCallerIsNotOwner() public {
        vm.prank(randos);
        vm.expectRevert(IAgentWallet.NotOwner.selector);
        wallet.withdraw(randos, FIVE_USDC);
    }

    function test_withdraw_revertsOnZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(IAgentWallet.ZeroAmount.selector);
        wallet.withdraw(owner, 0);
    }

    function test_withdraw_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IAgentWallet.ZeroPayee.selector);
        wallet.withdraw(address(0), FIVE_USDC);
    }

    function test_withdraw_revertsWhenInsufficientBalance() public {
        uint128 tooMuch = HUNDRED_USDC + TEN_USDC;

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAgentWallet.InsufficientBalance.selector,
                HUNDRED_USDC,
                tooMuch
            )
        );
        wallet.withdraw(owner, tooMuch);
    }

    // ── Full flow ─────────────────────────────────────────────────

    function test_fullFlow_depositThenExecute() public {
        // 1. Randos funds the wallet
        usdc.mint(randos, TEN_USDC);
        vm.startPrank(randos);
        usdc.approve(address(wallet), TEN_USDC);
        wallet.deposit(TEN_USDC);
        vm.stopPrank();

        assertEq(wallet.balance(), HUNDRED_USDC + TEN_USDC);

        // 2. Owner executes payment
        vm.prank(owner);
        wallet.execute(payee, TEN_USDC);

        assertEq(usdc.balanceOf(payee), TEN_USDC);
        assertEq(wallet.balance(), HUNDRED_USDC); // back to original
    }

    function test_fullFlow_multiplePayments_accumulateCorrectly() public {
        // Three payments of 5 USDC each = 15 USDC total
        vm.startPrank(owner);
        wallet.execute(payee, FIVE_USDC);
        wallet.execute(payee, FIVE_USDC);
        wallet.execute(payee, FIVE_USDC);
        vm.stopPrank();

        assertEq(usdc.balanceOf(payee), FIVE_USDC * 3);
        assertEq(wallet.balance(), HUNDRED_USDC - (FIVE_USDC * 3));

        // enforce() called 3 times
        assertEq(policyEngine.enforceCallCount(), 3);
    }

    // ── Fuzz: any valid amount ────────────────────────────────────

    /// @dev Fuzz test: any amount between 1 and wallet balance should succeed
    ///      as long as policyEngine doesn't block.
    function testFuzz_execute_anyValidAmount(uint128 amount) public {
        // Bound to realistic range: 1 to wallet's balance
        amount = uint128(bound(amount, 1, HUNDRED_USDC));

        vm.prank(owner);
        wallet.execute(payee, amount);

        assertEq(usdc.balanceOf(payee), amount);
        assertEq(wallet.balance(), HUNDRED_USDC - amount);
    }
}