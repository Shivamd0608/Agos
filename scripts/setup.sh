#!/bin/bash
set -e
echo "Setting up Agos monorepo..."

# Check dependencies
command -v node  >/dev/null || { echo "node required"; exit 1; }
command -v pnpm  >/dev/null || { echo "pnpm required: npm i -g pnpm"; exit 1; }
command -v forge >/dev/null || { echo "foundry required: https://getfoundry.sh"; exit 1; }

pnpm install
cd packages/contracts && forge install
cp .env.example .env 2>/dev/null || true
echo "Setup complete. Copy .env.example to .env and fill in values."
