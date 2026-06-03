// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IAgentWallet.sol";
import "../interfaces/IPolicyEngine.sol";

/// @title  AgentWallet
/// @notice One smart account per AI agent.
///         Holds USDC. Before every payment, asks PolicyEngine
///         for permission. If PolicyEngine reverts, no money moves.
///
/// @dev    Deployed by AgentWalletFactory via CREATE2.
///         Initialised once — constructor is empty because CREATE2
///         minimal proxies can't take constructor args.
///         Call initialise() right after deployment.
contract AgentWallet is IAgentWallet, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── State ────────────────────────────────────────────────────
    bytes32 private _agentId;
    address private _owner;
    address private _policyEngine;
    address private _usdcToken;
    bool    private _initialised;

    // ─── Modifiers ────────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner();
        _;
    }

    modifier initialised() {
        if (!_initialised) revert NotInitialised();
        _;
    }

    // ─── Initialisation ───────────────────────────────────────────

    /// @notice Called once by AgentWalletFactory after CREATE2 deploy.
    ///         Sets the agent's identity and connects it to PolicyEngine.
    /// @param  agentId_      keccak256(abi.encodePacked(address(this), chainId))
    /// @param  owner_        human who controls this agent
    /// @param  policyEngine_ deployed PolicyEngine address
    /// @param  usdcToken_    USDC contract address on this chain
    function initialise(
        bytes32 agentId_,
        address owner_,
        address policyEngine_,
        address usdcToken_
    ) external {
        // Can only be called once
        if (_initialised) revert NotInitialised();
        if (owner_        == address(0)) revert NotOwner();
        if (policyEngine_ == address(0)) revert PolicyBlocked();
        if (usdcToken_    == address(0)) revert TransferFailed();

        _agentId       = agentId_;
        _owner         = owner_;
        _policyEngine  = policyEngine_;
        _usdcToken     = usdcToken_;
        _initialised   = true;

        emit AgentIdSet(agentId_);
    }

    // ─── Core: execute payment ────────────────────────────────────

    /// @notice Pay `amount` USDC to `payee`.
    ///         Step 1: ask PolicyEngine if this is allowed.
    ///         Step 2: transfer USDC if yes.
    ///         Step 3: emit receipt.
    /// @dev    Only owner (or in future: authorised agent runner) calls this.
    ///         nonReentrant guards against re-entry on the USDC transfer.
    function execute(
        address payee,
        uint128 amount
    )
        external
        override
        onlyOwner
        initialised
        nonReentrant
        returns (bool approvalRequired)
    {
        if (amount  == 0)          revert ZeroAmount();
        if (payee   == address(0)) revert ZeroPayee();

        uint128 bal = balance();
        if (bal < amount) revert InsufficientBalance(bal, amount);

        // ── Step 1: policy check ──────────────────────────────────
        // enforce() reverts if any rule is violated.
        // If it reverts, this whole transaction reverts — no money moves.
        try IPolicyEngine(_policyEngine).enforce(_agentId, amount, payee)
            returns (bool _approvalRequired)
        {
            approvalRequired = _approvalRequired;
        } catch {
            revert PolicyBlocked();
        }

        // ── Step 2: move USDC ─────────────────────────────────────
        // SafeERC20 handles tokens that return false instead of reverting
        IERC20(_usdcToken).safeTransfer(payee, uint256(amount));

        // ── Step 3: emit receipt ──────────────────────────────────
        emit PaymentExecuted(payee, amount, _agentId, approvalRequired);
    }

    // ─── Funding ──────────────────────────────────────────────────

    /// @notice Anyone can deposit USDC to fund this agent.
    ///         Caller must have approved this contract first.
    function deposit(uint128 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(_usdcToken).safeTransferFrom(msg.sender, address(this), uint256(amount));
        emit FundsDeposited(msg.sender, amount);
    }

    /// @notice Owner withdraws USDC back to any address.
    function withdraw(
        address to,
        uint128 amount
    ) external override onlyOwner nonReentrant {
        if (amount == 0)       revert ZeroAmount();
        if (to == address(0))  revert ZeroPayee();
        uint128 bal = balance();
        if (bal < amount) revert InsufficientBalance(bal, amount);
        IERC20(_usdcToken).safeTransfer(to, uint256(amount));
        emit FundsWithdrawn(to, amount);
    }

    // ─── Views ────────────────────────────────────────────────────

    function agentId()      external view override returns (bytes32) { return _agentId;      }
    function owner()        external view override returns (address) { return _owner;        }
    function policyEngine() external view override returns (address) { return _policyEngine; }
    function usdcToken()    external view override returns (address) { return _usdcToken;    }

    function balance() public view override returns (uint128) {
        return uint128(IERC20(_usdcToken).balanceOf(address(this)));
    }
}