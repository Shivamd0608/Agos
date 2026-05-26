export interface AgentIdentity {
  agentId:       string;
  walletAddress: string;
  did:           string;          // ERC-8004 decentralized identifier
  ownerAddress:  string;          // human who deployed this agent
  parentAgentId: string | null;   // for delegated sub-agents
  createdAt:     number;
}

export interface AgentConfig {
  identity:   AgentIdentity;
  policy:     import("./policy.js").SpendPolicy;
  facilitatorUrl: string;
  chainId:    number;
}
