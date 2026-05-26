import { pgTable, text, bigint, timestamp, jsonb, index, uuid } from "drizzle-orm/pg-core";

export const agents = pgTable("agents", {
  id:           uuid("id").primaryKey().defaultRandom(),
  agentId:      text("agent_id").unique().notNull(),
  ownerAddress: text("owner_address").notNull(),
  walletAddress:text("wallet_address").notNull(),
  chainId:      bigint("chain_id", { mode: "number" }).notNull(),
  createdAt:    timestamp("created_at").defaultNow(),
}, t => ({ ownerIdx: index("agents_owner_idx").on(t.ownerAddress) }));

export const policies = pgTable("policies", {
  id:             uuid("id").primaryKey().defaultRandom(),
  agentId:        text("agent_id").notNull().references(() => agents.agentId),
  maxPerTx:       text("max_per_tx").notNull(),     // stored as string (bigint)
  maxPerDay:      text("max_per_day").notNull(),
  maxPerHour:     text("max_per_hour").notNull(),
  requireApproval:text("require_approval").notNull(),
  allowedPayees:  jsonb("allowed_payees").$type<string[]>().default([]),
  expiresAt:      timestamp("expires_at"),
  updatedAt:      timestamp("updated_at").defaultNow(),
});

export const receipts = pgTable("receipts", {
  id:          uuid("id").primaryKey().defaultRandom(),
  txHash:      text("tx_hash").unique().notNull(),
  agentId:     text("agent_id").notNull(),
  payee:       text("payee").notNull(),
  amount:      text("amount").notNull(),
  resource:    text("resource").notNull(),
  chainId:     bigint("chain_id", { mode: "number" }).notNull(),
  blockNumber: bigint("block_number", { mode: "bigint" }),
  createdAt:   timestamp("created_at").defaultNow(),
}, t => ({
  agentIdx:    index("receipts_agent_idx").on(t.agentId),
  createdIdx:  index("receipts_created_idx").on(t.createdAt),
}));

export const delegations = pgTable("delegations", {
  id:              uuid("id").primaryKey().defaultRandom(),
  parentAgentId:   text("parent_agent_id").notNull(),
  childAgentId:    text("child_agent_id").notNull(),
  budgetAllocation:text("budget_allocation").notNull(),
  createdAt:       timestamp("created_at").defaultNow(),
});
