import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import {
  Environment,
  SignedDataVerifier,
} from "@apple/app-store-server-library";
import type { Entitlement, EntitlementVerifier } from "./polish-application.js";

export class AppleEntitlementVerifier implements EntitlementVerifier {
  private readonly production: SignedDataVerifier;
  private readonly sandbox: SignedDataVerifier;

  constructor(options: {
    bundleId: string;
    appAppleId: number;
    rootCertificatesDirectory: string;
    enableOnlineChecks?: boolean;
  }) {
    const roots = readdirSync(options.rootCertificatesDirectory)
      .filter((name) => !name.startsWith(".") && name.endsWith(".cer"))
      .map((name) => readFileSync(join(options.rootCertificatesDirectory, name)));
    if (!roots.length) throw new Error("No Apple root certificates found.");
    const online = options.enableOnlineChecks ?? true;
    this.production = new SignedDataVerifier(
      roots,
      online,
      Environment.PRODUCTION,
      options.bundleId,
      options.appAppleId,
    );
    this.sandbox = new SignedDataVerifier(
      roots,
      online,
      Environment.SANDBOX,
      options.bundleId,
      undefined,
    );
  }

  async verify(transactionJWS: string): Promise<Entitlement> {
    const hintedEnvironment = decodeUntrustedEnvironment(transactionJWS);
    const verifier = hintedEnvironment === "Production" ? this.production : this.sandbox;
    const transaction = await verifier.verifyAndDecodeTransaction(transactionJWS);
    if (
      !transaction.originalTransactionId
      || !transaction.transactionId
      || !transaction.productId
      || !transaction.expiresDate
      || transaction.revocationDate
    ) {
      throw new Error("The App Store transaction is not an active subscription entitlement.");
    }
    return {
      originalTransactionId: transaction.originalTransactionId,
      transactionId: transaction.transactionId,
      productId: transaction.productId,
      expiresAt: new Date(transaction.expiresDate),
    };
  }
}

function decodeUntrustedEnvironment(jws: string): string | undefined {
  const payload = jws.split(".")[1];
  if (!payload) return undefined;
  try {
    return JSON.parse(Buffer.from(payload, "base64url").toString("utf8")).environment;
  } catch {
    return undefined;
  }
}
