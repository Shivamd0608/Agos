import Fastify from "fastify";
import cors from "@fastify/cors";
import rateLimit from "@fastify/rate-limit";
import { paymentsRouter }   from "./routes/payments.js";
import { agentsRouter }     from "./routes/agents.js";
import { policiesRouter }   from "./routes/policies.js";
import { delegationsRouter }from "./routes/delegations.js";
import { webhooksRouter }   from "./routes/webhooks.js";
import { healthRouter }     from "./routes/health.js";
import { authMiddleware }   from "./middleware/auth.js";
import { circuitBreaker }   from "./middleware/circuitBreaker.js";
import { logger }           from "./middleware/logger.js";

export function buildApp() {
  const app = Fastify({ logger: true });

  // ── Plugins ───────────────────────────────────
  app.register(cors, { origin: process.env.CORS_ORIGIN ?? "*" });
  app.register(rateLimit, { max: 200, timeWindow: "1 minute" });

  // ── Hooks ────────────────────────────────────
  app.addHook("onRequest", authMiddleware);
  app.addHook("onRequest", circuitBreaker);
  app.addHook("onResponse", logger);

  // ── Routes ───────────────────────────────────
  app.register(healthRouter,      { prefix: "/health" });
  app.register(paymentsRouter,    { prefix: "/v1/payments" });
  app.register(agentsRouter,      { prefix: "/v1/agents" });
  app.register(policiesRouter,    { prefix: "/v1/policies" });
  app.register(delegationsRouter, { prefix: "/v1/delegations" });
  app.register(webhooksRouter,    { prefix: "/v1/webhooks" });

  return app;
}
