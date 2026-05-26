export interface SpendPolicy {
  maxPerTransaction: bigint;      // in USDC base units (6 decimals)
  maxPerDay:         bigint;
  maxPerHour:        bigint;
  allowedPayees:     string[];    // domain names or wallet addresses
  allowedChainIds:   number[];
  requireApprovalAbove: bigint;   // triggers human-in-loop webhook
  expiresAt:         bigint;      // unix timestamp, 0 = no expiry
}

export interface PolicyConfig {
  agentId:  string;
  policy:   SpendPolicy;
  metadata: Record<string, string>;
}
