// ─────────────────────────────────────────────
// @agos/sdk — public surface
// ─────────────────────────────────────────────

// Core
export { AgosClient }        from "./core/AgosClient.js";
export { AgentWallet }       from "./core/AgentWallet.js";
export { PaymentSession }    from "./core/PaymentSession.js";
export { X402Client }        from "./core/x402Client.js";

// Policy
export { PolicyBuilder }     from "./policy/PolicyBuilder.js";
export { PolicyEncoder }     from "./policy/PolicyEncoder.js";

// Delegation
export { DelegationManager } from "./delegation/DelegationManager.js";
export { BudgetTree }        from "./delegation/BudgetTree.js";

// Session
export { SessionManager }    from "./session/SessionManager.js";

// Utils
export { signPaymentAuth }   from "./utils/eip712.js";
export { AgosError }         from "./utils/errors.js";

// Types (re-exported)
export type * from "./types/index.js";
