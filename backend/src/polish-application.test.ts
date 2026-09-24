import { describe, expect, it } from "vitest";
import {
  AllowanceExhaustedError,
  type CloudPolisher,
  type Entitlement,
  type EntitlementVerifier,
  InMemoryUsageLedger,
  InputTooLongError,
  PolishApplication,
  type PolishOutput,
  type UsageLedger,
} from "./polish-application.js";

const entitlement: Entitlement = {
  originalTransactionId: "original-1",
  transactionId: "renewal-1",
  productId: "com.jonclegg.WhisperPolish.cloud.monthly",
  expiresAt: new Date(Date.now() + 365 * 24 * 60 * 60 * 1000),
};

class StubVerifier implements EntitlementVerifier {
  async verify(): Promise<Entitlement> {
    return entitlement;
  }
}

class StubPolisher implements CloudPolisher {
  calls = 0;
  shouldFail = false;
  lastInput: {
    text: string;
    style: { name: string; instruction: string };
    revisionNotes?: string[];
  } | undefined;

  async polish(input: {
    text: string;
    style: { name: string; instruction: string };
    revisionNotes?: string[];
  }) {
    this.calls += 1;
    this.lastInput = input;
    if (this.shouldFail) throw new Error("provider failed");
    return { text: "Finished", model: "z-ai/glm-5.2", providerCostMicros: 3_000 };
  }
}

const request = {
  transactionJWS: "signed-transaction",
  idempotencyKey: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
  text: "rough words",
  style: { name: "Email", instruction: "Write an email." },
};

describe("PolishApplication", () => {
  it("returns a cached result without charging or calling the provider twice", async () => {
    const ledger = new InMemoryUsageLedger(300);
    const polisher = new StubPolisher();
    const app = new PolishApplication(new StubVerifier(), ledger, polisher);

    const first = await app.polish(request);
    const second = await app.polish(request);

    expect(first).toEqual(second);
    expect(first.usage).toMatchObject({ used: 1, limit: 300, remaining: 299 });
    expect(polisher.calls).toBe(1);
  });

  it("enforces the monthly allowance before calling the provider", async () => {
    const ledger = new InMemoryUsageLedger(1);
    const polisher = new StubPolisher();
    const app = new PolishApplication(new StubVerifier(), ledger, polisher);
    await app.polish(request);

    await expect(app.polish({ ...request, idempotencyKey: "second" }))
      .rejects.toBeInstanceOf(AllowanceExhaustedError);
    expect(polisher.calls).toBe(1);
  });

  it("releases a reservation when the provider fails", async () => {
    const ledger = new InMemoryUsageLedger(1);
    const polisher = new StubPolisher();
    const app = new PolishApplication(new StubVerifier(), ledger, polisher);
    polisher.shouldFail = true;
    await expect(app.polish(request)).rejects.toThrow("provider failed");

    polisher.shouldFail = false;
    const result = await app.polish({ ...request, idempotencyKey: "retry" });
    expect(result.usage.used).toBe(1);
  });

  it("does not release a billed provider call when persisting its result fails", async () => {
    const ledger = new FailingCompleteLedger();
    const app = new PolishApplication(new StubVerifier(), ledger, new StubPolisher());

    await expect(app.polish(request)).rejects.toThrow("database unavailable");

    expect(ledger.releaseCalls).toBe(0);
  });

  it("rejects oversized text before calling the provider", async () => {
    const polisher = new StubPolisher();
    const app = new PolishApplication(
      new StubVerifier(),
      new InMemoryUsageLedger(300),
      polisher,
      { maxInputBytes: 10 },
    );

    await expect(app.polish({ ...request, text: "12345678901" }))
      .rejects.toBeInstanceOf(InputTooLongError);
    expect(polisher.calls).toBe(0);
  });

  it("sends the polished draft and revision notes to the polisher", async () => {
    const polisher = new StubPolisher();
    const app = new PolishApplication(new StubVerifier(), new InMemoryUsageLedger(300), polisher);

    await app.polish({
      ...request,
      text: "Thanks for the update. Let's ship Friday.",
      revisionNotes: ["Drop the thanks"],
    });

    expect(polisher.lastInput).toEqual({
      text: "Thanks for the update. Let's ship Friday.",
      style: request.style,
      revisionNotes: ["Drop the thanks"],
    });
  });

  it("counts revision notes toward the input size limit", async () => {
    const polisher = new StubPolisher();
    const app = new PolishApplication(
      new StubVerifier(),
      new InMemoryUsageLedger(300),
      polisher,
      { maxInputBytes: 10 },
    );

    await expect(app.polish({
      ...request,
      text: "12345",
      revisionNotes: ["123456"],
    })).rejects.toBeInstanceOf(InputTooLongError);
    expect(polisher.calls).toBe(0);
  });
});

class FailingCompleteLedger implements UsageLedger {
  releaseCalls = 0;

  async reserve() {
    return { kind: "reserved" as const, used: 1, limit: 300 };
  }

  async complete(
    _entitlement: Entitlement,
    _idempotencyKey: string,
    _response: PolishOutput,
    _providerCostMicros: number,
  ): Promise<void> {
    throw new Error("database unavailable");
  }

  async release(): Promise<void> {
    this.releaseCalls += 1;
  }
}
