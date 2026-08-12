import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { AppleEntitlementVerifier } from "./apple-entitlement-verifier.js";

describe("AppleEntitlementVerifier", () => {
  it("ignores hidden AppleDouble files beside root certificates", () => {
    const directory = mkdtempSync(join(tmpdir(), "apple-roots-"));
    const root = new URL("../certs/AppleRootCA-G3.cer", import.meta.url);
    writeFileSync(join(directory, "AppleRootCA-G3.cer"), readFileSync(root));
    writeFileSync(join(directory, "._AppleRootCA-G3.cer"), "not a certificate");

    expect(() => new AppleEntitlementVerifier({
      bundleId: "com.example.App",
      appAppleId: 123,
      rootCertificatesDirectory: directory,
      enableOnlineChecks: false,
    })).not.toThrow();
  });
});
