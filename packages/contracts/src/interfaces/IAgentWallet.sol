// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  IAgentWallet
/// @notice Interface for a single agent's smart account.
///         Holds USDC, enforces policy before every payment.
interface IAgentWallet {

    // ─── Events ───────────────────────────────────────────────────
    event PaymentExecuted(
        address indexed payee,
        uint128         amount,
        bytes32         indexed agentId,
        bool            approvalRequired
    );
    event FundsDeposited(address indexed from, uint128 amount);
    event FundsWithdrawn(address indexed to,   uint128 amount);
    event AgentIdSet(bytes32 indexed agentId);

    // ─── Errors ───────────────────────────────────────────────────
    error NotOwner();
    error ZeroAmount();
    error ZeroPayee();
    error PolicyBlocked();          // enforce() reverted upstream
    error InsufficientBalance(uint128 available, uint128 requested);
    error TransferFailed();
    error NotInitialised();

    // ─── Core functions ───────────────────────────────────────────

    /// @notice Execute a USDC payment to payee.
    ///         Calls PolicyEngine.enforce() first.
    ///         Reverts if policy blocks it.
    function execute(
        address payee,
        uint128 amount
    ) external returns (bool approvalRequired);

    /// @notice Deposit USDC into this wallet.
    ///         Anyone can fund an agent, only owner withdraws.
    function deposit(uint128 amount) external;

    /// @notice Owner withdraws USDC from this wallet.
    function withdraw(address to, uint128 amount) external;

    // ─── View functions ───────────────────────────────────────────

    function agentId()       external view returns (bytes32);
    function owner()         external view returns (address);
    function policyEngine()  external view returns (address);
    function usdcToken()     external view returns (address);
    function balance()       external view returns (uint128);
}