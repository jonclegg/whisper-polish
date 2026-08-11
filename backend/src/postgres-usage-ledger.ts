import type { Pool, PoolClient } from "pg";
import {
  AllowanceExhaustedError,
  type Entitlement,
  MONTHLY_POLISH_LIMIT,
  type PolishOutput,
  RequestInProgressError,
  type UsageLedger,
} from "./polish-application.js";

export async function initializeSchema(pool: Pool): Promise<void> {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS usage_periods (
      original_transaction_id TEXT NOT NULL,
      period_transaction_id TEXT NOT NULL,
      expires_at TIMESTAMPTZ NOT NULL,
      used INTEGER NOT NULL DEFAULT 0 CHECK (used >= 0),
      provider_cost_micros BIGINT NOT NULL DEFAULT 0 CHECK (provider_cost_micros >= 0),
      PRIMARY KEY (original_transaction_id, period_transaction_id)
    );

    CREATE TABLE IF NOT EXISTS polish_requests (
      original_transaction_id TEXT NOT NULL,
      period_transaction_id TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      state TEXT NOT NULL CHECK (state IN ('pending', 'completed')),
      response JSONB,
      provider_cost_micros BIGINT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (original_transaction_id, period_transaction_id, idempotency_key),
      FOREIGN KEY (original_transaction_id, period_transaction_id)
        REFERENCES usage_periods (original_transaction_id, period_transaction_id)
        ON DELETE CASCADE
    );
  `);
}

export class PostgresUsageLedger implements UsageLedger {
  constructor(
    private readonly pool: Pool,
    private readonly limit = MONTHLY_POLISH_LIMIT,
    private readonly maximumProviderCostMicros = 2_200_000,
  ) {}

  async reserve(entitlement: Entitlement, idempotencyKey: string) {
    return this.transaction(async (client) => {
      const period = await this.lockPeriod(client, entitlement);
      const existing = await client.query<{ state: string; response: PolishOutput | null }>(
        `SELECT state, response FROM polish_requests
         WHERE original_transaction_id = $1 AND period_transaction_id = $2 AND idempotency_key = $3`,
        [entitlement.originalTransactionId, entitlement.transactionId, idempotencyKey],
      );
      if (existing.rows[0]?.state === "completed" && existing.rows[0].response) {
        return { kind: "cached" as const, response: existing.rows[0].response };
      }
      if (existing.rows[0]?.state === "pending") throw new RequestInProgressError();
      if (Number(period.provider_cost_micros) >= this.maximumProviderCostMicros) {
        throw new AllowanceExhaustedError();
      }

      const usage = await client.query<{ used: number }>(
        `UPDATE usage_periods SET used = used + 1
         WHERE original_transaction_id = $1 AND period_transaction_id = $2 AND used < $3
         RETURNING used`,
        [entitlement.originalTransactionId, entitlement.transactionId, this.limit],
      );
      if (!usage.rows[0]) throw new AllowanceExhaustedError();

      await client.query(
        `INSERT INTO polish_requests
          (original_transaction_id, period_transaction_id, idempotency_key, state)
         VALUES ($1, $2, $3, 'pending')`,
        [entitlement.originalTransactionId, entitlement.transactionId, idempotencyKey],
      );
      return { kind: "reserved" as const, used: usage.rows[0].used, limit: this.limit };
    });
  }

  async complete(
    entitlement: Entitlement,
    idempotencyKey: string,
    response: PolishOutput,
    providerCostMicros: number,
  ): Promise<void> {
    await this.transaction(async (client) => {
      await this.lockPeriod(client, entitlement);
      await client.query(
        `UPDATE polish_requests SET state = 'completed', response = $4, provider_cost_micros = $5
         WHERE original_transaction_id = $1 AND period_transaction_id = $2 AND idempotency_key = $3`,
        [entitlement.originalTransactionId, entitlement.transactionId, idempotencyKey, response, providerCostMicros],
      );
      await client.query(
        `UPDATE usage_periods SET provider_cost_micros = provider_cost_micros + $3
         WHERE original_transaction_id = $1 AND period_transaction_id = $2`,
        [entitlement.originalTransactionId, entitlement.transactionId, providerCostMicros],
      );
    });
  }

  async release(entitlement: Entitlement, idempotencyKey: string): Promise<void> {
    await this.transaction(async (client) => {
      await this.lockPeriod(client, entitlement);
      const deleted = await client.query(
        `DELETE FROM polish_requests
         WHERE original_transaction_id = $1 AND period_transaction_id = $2
           AND idempotency_key = $3 AND state = 'pending'
         RETURNING idempotency_key`,
        [entitlement.originalTransactionId, entitlement.transactionId, idempotencyKey],
      );
      if (deleted.rowCount) {
        await client.query(
          `UPDATE usage_periods SET used = GREATEST(0, used - 1)
           WHERE original_transaction_id = $1 AND period_transaction_id = $2`,
          [entitlement.originalTransactionId, entitlement.transactionId],
        );
      }
    });
  }

  private async lockPeriod(
    client: PoolClient,
    entitlement: Entitlement,
  ): Promise<{ used: number; provider_cost_micros: string }> {
    await client.query(
      `INSERT INTO usage_periods (original_transaction_id, period_transaction_id, expires_at)
       VALUES ($1, $2, $3)
       ON CONFLICT (original_transaction_id, period_transaction_id)
       DO UPDATE SET expires_at = EXCLUDED.expires_at`,
      [entitlement.originalTransactionId, entitlement.transactionId, entitlement.expiresAt],
    );
    const result = await client.query<{ used: number; provider_cost_micros: string }>(
      `SELECT used, provider_cost_micros FROM usage_periods
       WHERE original_transaction_id = $1 AND period_transaction_id = $2 FOR UPDATE`,
      [entitlement.originalTransactionId, entitlement.transactionId],
    );
    return result.rows[0]!;
  }

  private async transaction<T>(work: (client: PoolClient) => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const result = await work(client);
      await client.query("COMMIT");
      return result;
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }
}
