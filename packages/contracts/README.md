AgentWallet.execute(payee, amount)
  │
  ├── 1. PolicyEngine.enforce(agentId, amount, payee)
  │         checks per-tx, hourly, daily limits
  │         reverts if violated
  │
  ├── 2. DelegationRegistry.checkAndRecordSpend(agentId, amount)
  │         checks delegation budget up the whole tree
  │         reverts if any ancestor is over-budget
  │         no-op if this is a root agent
  │
  └── 3. USDC.transfer(payee, amount)
            money only moves if both checks passed