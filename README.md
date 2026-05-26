# Agos — Payment OS for AI Agents

> Programmable, auditable, governed payments for autonomous agents.

[![CI](https://github.com/your-org/agos/actions/workflows/ci.yml/badge.svg)](https://github.com/your-org/agos/actions)
[![npm](https://img.shields.io/npm/v/@agos/sdk)](https://npmjs.com/package/@agos/sdk)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## What is Agos?

Agos is a production-grade agent payment OS built on x402 and ERC-4337.
It gives every AI agent a programmable wallet with spend policies, delegation,
human oversight, and on-chain audit trails.

## Quick start (SDK)

```bash
npm install @agos/sdk viem
```

```typescript
import { AgosClient, PolicyBuilder } from "@agos/sdk";

const agos = new AgosClient({
  facilitatorUrl: "https://api.agos.xyz",
  chainId: 8453,
});

const policy = new PolicyBuilder()
  .maxPerTransaction(0.05)   // USDC
  .maxPerDay(5.00)
  .allowPayees(["api.openai.com", "api.anthropic.com"])
  .requireApprovalAbove(1.00)
  .build();

const agent = await agos.createAgent({ policy });
await agent.pay("https://api.openai.com/v1/chat/completions", 0.01);
```

## Monorepo structure

| Package / App              | Description                            |
|----------------------------|----------------------------------------|
| `packages/sdk`             | `@agos/sdk` — publishable npm package  |
| `packages/sdk-python`      | `agos` — Python SDK mirror             |
| `packages/contracts`       | Solidity contracts (Foundry)           |
| `packages/protocol`        | Shared ABIs, constants, chain configs  |
| `apps/facilitator`         | Payment verification API (Fastify)     |
| `apps/indexer`             | On-chain event indexer                 |
| `apps/dashboard`           | Human oversight UI (Next.js)           |
| `apps/docs`                | Documentation site (Docusaurus)        |
| `apps/examples`            | Example agents using the SDK           |

## Development

```bash
bash scripts/setup.sh
pnpm dev          # all apps in parallel
pnpm test         # all tests
pnpm contracts:test  # Foundry tests only
```

## Deploying

```bash
# Deploy contracts to Base Sepolia
bash scripts/deploy-testnet.sh

# Start services
docker compose -f infra/docker/docker-compose.yml up
```

## Publishing the SDK

Tag a release: `git tag sdk-v0.1.0 && git push --tags`

The `publish-sdk` GitHub Action handles the rest.
