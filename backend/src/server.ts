import Fastify from "fastify";
import rateLimit from "@fastify/rate-limit";
import { Pool } from "pg";
import { z } from "zod";
import { AppleEntitlementVerifier } from "./apple-entitlement-verifier.js";
import { OpenRouterPolisher } from "./openrouter-polisher.js";
import {
  AllowanceExhaustedError,
  InputTooLongError,
  InvalidProductError,
  PolishApplication,
  RequestInProgressError,
} from "./polish-application.js";
import { initializeSchema, PostgresUsageLedger } from "./postgres-usage-ledger.js";

const environmentSchema = z.object({
  DATABASE_URL: z.string().min(1),
  OPENROUTER_API_KEY: z.string().min(1),
  APP_BUNDLE_ID: z.string().default("com.jonclegg.WhisperPolish"),
  APP_APPLE_ID: z.coerce.number().int().positive(),
  APPLE_ROOT_CERTIFICATES_DIR: z.string().min(1),
  PORT: z.coerce.number().int().positive().default(8080),
});

const polishBodySchema = z.object({
  text: z.string().min(1).max(8_000),
  style: z.object({
    name: z.string().min(1).max(80),
    instruction: z.string().min(1).max(1_000),
  }),
});

const env = environmentSchema.parse(process.env);
const pool = new Pool({ connectionString: env.DATABASE_URL });
await initializeSchema(pool);

const application = new PolishApplication(
  new AppleEntitlementVerifier({
    bundleId: env.APP_BUNDLE_ID,
    appAppleId: env.APP_APPLE_ID,
    rootCertificatesDirectory: env.APPLE_ROOT_CERTIFICATES_DIR,
  }),
  new PostgresUsageLedger(pool),
  new OpenRouterPolisher(env.OPENROUTER_API_KEY),
);

const server = Fastify({
  trustProxy: ["loopback", "linklocal", "uniquelocal"],
  logger: {
    level: "info",
    redact: ["req.headers.authorization"],
  },
  bodyLimit: 32 * 1024,
});

await server.register(rateLimit, { global: false });

server.get("/health", async () => ({ ok: true }));

server.post("/v1/polish", {
  config: {
    rateLimit: {
      max: 30,
      timeWindow: "1 minute",
    },
  },
}, async (request, reply) => {
  const authorization = request.headers.authorization;
  const transactionJWS = authorization?.startsWith("Bearer ")
    ? authorization.slice("Bearer ".length)
    : "";
  const idempotencyKey = request.headers["idempotency-key"];
  if (!transactionJWS) {
    return reply.code(401).send(errorBody("missing_entitlement", "A current subscription is required."));
  }
  if (typeof idempotencyKey !== "string" || !z.uuid().safeParse(idempotencyKey).success) {
    return reply.code(400).send(errorBody("invalid_idempotency_key", "A valid Idempotency-Key is required."));
  }

  const body = polishBodySchema.parse(request.body);
  const response = await application.polish({
    ...body,
    transactionJWS,
    idempotencyKey,
  });
  return reply.send(response);
});

server.setErrorHandler((error, _request, reply) => {
  if (error instanceof AllowanceExhaustedError) {
    return reply.code(402).send(errorBody(error.code, error.message));
  }
  if (error instanceof InputTooLongError || error instanceof InvalidProductError) {
    return reply.code(400).send(errorBody(error.code, error.message));
  }
  if (error instanceof RequestInProgressError) {
    return reply.code(409).send(errorBody(error.code, error.message));
  }
  if (error instanceof z.ZodError) {
    return reply.code(400).send(errorBody("invalid_request", "The request is invalid."));
  }
  server.log.error(error);
  return reply.code(502).send(errorBody("cloud_unavailable", "Cloud polish is temporarily unavailable."));
});

server.addHook("onClose", async () => {
  await pool.end();
});

await server.listen({ port: env.PORT, host: "0.0.0.0" });

function errorBody(code: string, message: string) {
  return { error: { code, message } };
}
