import { defineConfig } from "tsup";

export default defineConfig({
  entry: {
    index:            "src/index.ts",
    "policy/index":   "src/policy/types.ts",
    "delegation/index":"src/delegation/DelegationManager.ts",
    "adapters/langchain": "src/adapters/langchain.ts",
    "adapters/mcp":   "src/adapters/mcp.ts",
  },
  format: ["esm", "cjs"],
  dts: true,
  sourcemap: true,
  clean: true,
  splitting: false,
  treeshake: true,
  external: ["viem"],
});
