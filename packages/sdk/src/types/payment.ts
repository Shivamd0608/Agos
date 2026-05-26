export interface PaymentRequest {
  payee:     string;   // wallet address
  amount:    bigint;   // USDC base units
  resource:  string;   // URI or service identifier
  chainId:   number;
  nonce:     bigint;
  deadline:  bigint;
}

export interface PaymentReceipt {
  txHash:       string;
  blockNumber:  bigint;
  agentId:      string;
  payee:        string;
  amount:       bigint;
  timestamp:    number;
  sessionToken: string;
}

export interface PaymentSession {
  sessionId:      string;
  agentId:        string;
  facilitatorUrl: string;
  resource:       string;
  expiresAt:      number;
  token:          string;
}
