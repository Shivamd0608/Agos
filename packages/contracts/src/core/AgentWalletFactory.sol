// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./AgentWallet.sol";
import "../interfaces/IPolicyEngine.sol";

/// @title  AgentWalletFactory
/// @notice Deploys one AgentWallet per agent using CREATE2.
///         CREATE2 gives a deterministic address — you can predict
///         where the wallet will live before it is deployed.
///
///         After deploying the wallet, the factory:
///         1. Calls wallet.initialise() to wire up owner + policy engine
///         2. Grants the wallet ENFORCER_ROLE on PolicyEngine
///            so it is the only address allowed to call enforce()
contract AgentWalletFactory is Ownable {

    // ─── State ────────────────────────────────────────────────────
    address public immutable policyEngine;
    address public immutable usdcToken;

    // agentId => wallet address (registry)
    mapping(bytes32 => address) public wallets;

    // ─── Events ───────────────────────────────────────────────────
    event AgentCreated(
        bytes32 indexed agentId,
        address indexed wallet,
        address indexed owner
    );

    // ─── Errors ───────────────────────────────────────────────────
    error AgentAlreadyExists(bytes32 agentId);
    error ZeroAddress();
    error DeployFailed();

    // ─── Constructor ──────────────────────────────────────────────
    constructor(
        address policyEngine_,
        address usdcToken_,
        address factoryOwner_
    ) Ownable(factoryOwner_) {
        if (policyEngine_ == address(0)) revert ZeroAddress();
        if (usdcToken_    == address(0)) revert ZeroAddress();
        if (factoryOwner_ == address(0)) revert ZeroAddress();

        policyEngine = policyEngine_;
        usdcToken    = usdcToken_;
    }

    // ─── Core: create agent ───────────────────────────────────────

    /// @notice Deploy a new AgentWallet for `agentOwner`.
    ///         The agentId is deterministic: keccak256(owner + salt).
    ///         Anyone can create an agent for any owner address.
    ///
    /// @param  agentOwner  human who will control the agent
    /// @param  salt        unique value — use a counter or UUID hash
    /// @return wallet      address of the deployed AgentWallet
    /// @return agentId     the agent's unique bytes32 identifier
    function createAgent(
        address agentOwner,
        bytes32 salt
    ) external returns (address wallet, bytes32 agentId) {
        if (agentOwner == address(0)) revert ZeroAddress();

        // ── Derive agentId ────────────────────────────────────────
        // Ties agent identity to: owner + salt + this chain
        agentId = keccak256(
            abi.encodePacked(agentOwner, salt, block.chainid)
        );

        if (wallets[agentId] != address(0))
            revert AgentAlreadyExists(agentId);

        // ── Deploy with CREATE2 ───────────────────────────────────
        // CREATE2 address is determined by:
        // keccak256(0xff ++ factory_address ++ salt ++ keccak256(bytecode))
        // This means you can predict the wallet address BEFORE deploying.
        bytes32 create2Salt = keccak256(abi.encodePacked(agentId));

        wallet = _deploy(create2Salt);
        if (wallet == address(0)) revert DeployFailed();

        // ── Initialise the wallet ─────────────────────────────────
        AgentWallet(wallet).initialise(
            agentId,
            agentOwner,
            policyEngine,
            usdcToken
        );

        // ── Grant wallet ENFORCER_ROLE on PolicyEngine ────────────
        // This is the access control that means ONLY this wallet
        // can call policyEngine.enforce(). No other address can.
        AccessControl(policyEngine).grantRole(
            keccak256("ENFORCER_ROLE"),
            wallet
        );

        // ── Register in our local registry ───────────────────────
        wallets[agentId] = wallet;

        emit AgentCreated(agentId, wallet, agentOwner);
    }

    // ─── Predict address ─────────────────────────────────────────

    /// @notice Returns the address where an AgentWallet WOULD be deployed
    ///         for these inputs, without actually deploying it.
    ///         Useful for pre-funding a wallet before it exists.
    function predictAddress(
        address agentOwner,
        bytes32 salt
    ) external view returns (address) {
        bytes32 agentId = keccak256(
            abi.encodePacked(agentOwner, salt, block.chainid)
        );
        bytes32 create2Salt = keccak256(abi.encodePacked(agentId));

        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            create2Salt,
            keccak256(type(AgentWallet).creationCode)
        )))));
    }

    /// @notice Returns true if an agent exists for this agentId
    function agentExists(bytes32 agentId) external view returns (bool) {
        return wallets[agentId] != address(0);
    }

    // ─── Internal: CREATE2 deploy ─────────────────────────────────
    function _deploy(bytes32 salt) internal returns (address addr) {
        bytes memory bytecode = type(AgentWallet).creationCode;
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
    }
}