export const CLOUD_PRODUCT_ID = "com.jonclegg.WhisperPolish.cloud.monthly";
export const MONTHLY_POLISH_LIMIT = 300;

export type Entitlement = {
  originalTransactionId: string;
  transactionId: string;
  productId: string;
  expiresAt: Date;
};

export type PolishInput = {
  transactionJWS: string;
  idempotencyKey: string;
  text: string;
  style: { name: string; instruction: string };
};

export type PolishOutput = {
  text: string;
  model: string;
  usage: {
    used: number;
    limit: number;
    remaining: number;
    resetsAt: string;
  };
};

export interface EntitlementVerifier {
  verify(transactionJWS: string): Promise<Entitlement>;
}

export interface CloudPolisher {
  polish(input: { text: string; style: { name: string; instruction: string } }): Promise<{
    text: string;
    model: string;
    providerCostMicros: number;
  }>;
}

type Reservation =
  | { kind: "cached"; response: PolishOutput }
  | { kind: "reserved"; used: number; limit: number };

export interface UsageLedger {
  reserve(entitlement: Entitlement, idempotencyKey: string): Promise<Reservation>;
  complete(
    entitlement: Entitlement,
    idempotencyKey: string,
    response: PolishOutput,
    providerCostMicros: number,
  ): Promise<void>;
  release(entitlement: Entitlement, idempotencyKey: string): Promise<void>;
}

export class AllowanceExhaustedError extends Error {
  readonly code = "allowance_exhausted";
  constructor() {
    super("Monthly cloud polish allowance used.");
  }
}

export class InputTooLongError extends Error {
  readonly code = "input_too_long";
  constructor(readonly maxBytes: number) {
    super(`This note is too long for cloud polish. The UTF-8 size limit is ${maxBytes.toLocaleString()} bytes.`);
  }
}

export class InvalidProductError extends Error {
  readonly code = "invalid_subscription";
  constructor() {
    super("This subscription does not unlock Whisper Polish Cloud.");
  }
}

export class RequestInProgressError extends Error {
  readonly code = "request_in_progress";
  constructor() {
    super("This polish request is already in progress.");
  }
}

export class PolishApplication {
  private readonly maxInputBytes: number;

  constructor(
    private readonly verifier: EntitlementVerifier,
    private readonly ledger: UsageLedger,
    private readonly polisher: CloudPolisher,
    options: { maxInputBytes?: number } = {},
  ) {
    this.maxInputBytes = options.maxInputBytes ?? 8_000;
  }

  async polish(input: PolishInput): Promise<PolishOutput> {
    if (Buffer.byteLength(input.text, "utf8") > this.maxInputBytes) {
      throw new InputTooLongError(this.maxInputBytes);
    }

    const entitlement = await this.verifier.verify(input.transactionJWS);
    if (entitlement.productId !== CLOUD_PRODUCT_ID || entitlement.expiresAt <= new Date()) {
      throw new InvalidProductError();
    }

    const reservation = await this.ledger.reserve(entitlement, input.idempotencyKey);
    if (reservation.kind === "cached") return reservation.response;

    let polished: Awaited<ReturnType<CloudPolisher["polish"]>>;
    try {
      polished = await this.polisher.polish({ text: input.text, style: input.style });
    } catch (error) {
      await this.ledger.release(entitlement, input.idempotencyKey);
      throw error;
    }

    const response: PolishOutput = {
      text: polished.text,
      model: polished.model,
      usage: {
        used: reservation.used,
        limit: reservation.limit,
        remaining: reservation.limit - reservation.used,
        resetsAt: entitlement.expiresAt.toISOString(),
      },
    };
    // If persistence fails after the provider billed the call, keep the
    // reservation pending. Releasing it would let a retry spend twice.
    await this.ledger.complete(
      entitlement,
      input.idempotencyKey,
      response,
      polished.providerCostMicros,
    );
    return response;
  }
}

type MemoryPeriod = {
  used: number;
  providerCostMicros: number;
  requests: Map<string, { state: "pending" } | { state: "completed"; response: PolishOutput }>;
};

export class InMemoryUsageLedger implements UsageLedger {
  private readonly periods = new Map<string, MemoryPeriod>();

  constructor(private readonly limit = MONTHLY_POLISH_LIMIT) {}

  async reserve(entitlement: Entitlement, idempotencyKey: string): Promise<Reservation> {
    const period = this.period(entitlement);
    const existing = period.requests.get(idempotencyKey);
    if (existing?.state === "completed") return { kind: "cached", response: existing.response };
    if (existing?.state === "pending") throw new RequestInProgressError();
    if (period.used >= this.limit) throw new AllowanceExhaustedError();

    period.used += 1;
    period.requests.set(idempotencyKey, { state: "pending" });
    return { kind: "reserved", used: period.used, limit: this.limit };
  }

  async complete(
    entitlement: Entitlement,
    idempotencyKey: string,
    response: PolishOutput,
    providerCostMicros: number,
  ): Promise<void> {
    const period = this.period(entitlement);
    period.providerCostMicros += providerCostMicros;
    period.requests.set(idempotencyKey, { state: "completed", response });
  }

  async release(entitlement: Entitlement, idempotencyKey: string): Promise<void> {
    const period = this.period(entitlement);
    if (period.requests.get(idempotencyKey)?.state === "pending") {
      period.requests.delete(idempotencyKey);
      period.used = Math.max(0, period.used - 1);
    }
  }

  private period(entitlement: Entitlement): MemoryPeriod {
    const key = `${entitlement.originalTransactionId}:${entitlement.transactionId}`;
    let value = this.periods.get(key);
    if (!value) {
      value = { used: 0, providerCostMicros: 0, requests: new Map() };
      this.periods.set(key, value);
    }
    return value;
  }
}
