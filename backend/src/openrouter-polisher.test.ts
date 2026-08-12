import { describe, expect, it, vi } from "vitest";
import { OpenRouterPolisher } from "./openrouter-polisher.js";
import type { OpenRouterIncidentSink } from "./openrouter-incident-reporter.js";

const input = {
  text: "rough words",
  style: { name: "Email", instruction: "Write an email." },
};

describe("OpenRouterPolisher", () => {
  it("accepts the approved GLM 5.2 launch price", async () => {
    const fetcher = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(json({
        data: [{
          id: "z-ai/glm-5.2",
          pricing: { prompt: "0.0000005586", completion: "0.0000017556" },
        }],
      }))
      .mockResolvedValueOnce(json({
        choices: [{ message: { content: "Finished" } }],
        usage: { cost: 0.0042 },
      }));

    await expect(new OpenRouterPolisher("secret", "z-ai/glm-5.2", fetcher).polish(input))
      .resolves.toMatchObject({ text: "Finished" });
  });

  it("returns metered cost and applies bounded privacy-conscious parameters", async () => {
    const fetcher = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(json({
        data: [{ id: "z-ai/glm-5.2", pricing: { prompt: "0.0000004", completion: "0.0000012" } }],
      }))
      .mockResolvedValueOnce(json({
        choices: [{ message: { content: "Finished" } }],
        usage: { cost: 0.0042 },
      }));

    const result = await new OpenRouterPolisher("secret", "z-ai/glm-5.2", fetcher).polish(input);

    expect(result.providerCostMicros).toBe(4_200);
    const request = fetcher.mock.calls[1]![1]!;
    const body = JSON.parse(request.body as string);
    expect(body.max_tokens).toBe(2_000);
    expect(body.reasoning).toEqual({ enabled: false });
    expect(body.provider).toEqual({ data_collection: "deny" });
  });

  it("refuses to spend when model pricing exceeds the approved ceiling", async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(json({
      data: [{ id: "z-ai/glm-5.2", pricing: { prompt: "0.00000061", completion: "0.0000012" } }],
    }));

    await expect(new OpenRouterPolisher("secret", "z-ai/glm-5.2", fetcher).polish(input))
      .rejects.toThrow("provider pricing changed");
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it("refuses to spend when model pricing is malformed", async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(json({
      data: [{ id: "z-ai/glm-5.2", pricing: { prompt: "unknown", completion: "0.0000012" } }],
    }));

    await expect(new OpenRouterPolisher("secret", "z-ai/glm-5.2", fetcher).polish(input))
      .rejects.toThrow("pricing is invalid");
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it("refuses an invalid reported provider cost", async () => {
    const fetcher = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(json({
        data: [{ id: "z-ai/glm-5.2", pricing: { prompt: "0.0000004", completion: "0.0000012" } }],
      }))
      .mockResolvedValueOnce(json({
        choices: [{ message: { content: "Finished" } }],
        usage: { cost: -1 },
      }));

    await expect(new OpenRouterPolisher("secret", "z-ai/glm-5.2", fetcher).polish(input))
      .rejects.toThrow("valid usage cost");
  });

  it("alerts on insufficient credits without including the provider response body", async () => {
    const incidents = incidentSink();
    const fetcher = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(json({
        data: [{ id: "z-ai/glm-5.2", pricing: { prompt: "0.0000004", completion: "0.0000012" } }],
      }))
      .mockResolvedValueOnce(new Response("private provider detail", { status: 402 }));

    await expect(new OpenRouterPolisher(
      "secret",
      "z-ai/glm-5.2",
      fetcher,
      undefined,
      incidents,
    ).polish(input)).rejects.toThrow("OpenRouter error 402");

    expect(incidents.reportFailure).toHaveBeenCalledWith(
      "chat completions",
      "HTTP 402: the OpenRouter account or API key has insufficient credits.",
    );
    expect(incidents.reportFailure).not.toHaveBeenCalledWith(
      expect.anything(),
      expect.stringContaining("private provider detail"),
    );
  });

  it("returns a successful polish even when recovery email delivery fails", async () => {
    const incidents = incidentSink();
    incidents.reportRecovery.mockRejectedValue(new Error("SES unavailable"));
    const fetcher = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(json({
        data: [{ id: "z-ai/glm-5.2", pricing: { prompt: "0.0000004", completion: "0.0000012" } }],
      }))
      .mockResolvedValueOnce(json({
        choices: [{ message: { content: "Finished" } }],
        usage: { cost: 0.0042 },
      }));

    await expect(new OpenRouterPolisher(
      "secret",
      "z-ai/glm-5.2",
      fetcher,
      undefined,
      incidents,
    ).polish(input)).resolves.toMatchObject({ text: "Finished" });
  });
});

function incidentSink(): OpenRouterIncidentSink & {
  reportFailure: ReturnType<typeof vi.fn>;
  reportRecovery: ReturnType<typeof vi.fn>;
  reportBalance: ReturnType<typeof vi.fn>;
} {
  return {
    reportFailure: vi.fn().mockResolvedValue(undefined),
    reportRecovery: vi.fn().mockResolvedValue(undefined),
    reportBalance: vi.fn().mockResolvedValue(undefined),
  };
}

function json(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}
