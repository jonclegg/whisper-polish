import { describe, expect, it, vi } from "vitest";
import { OpenRouterIncidentReporter } from "./openrouter-incident-reporter.js";

describe("OpenRouterIncidentReporter", () => {
  it("sends one outage alert, suppresses repeats, and sends one recovery", async () => {
    const send = vi.fn().mockResolvedValue(undefined);
    const reporter = new OpenRouterIncidentReporter({ send });

    await reporter.reportFailure("chat completions", "HTTP 502");
    await reporter.reportFailure("chat completions", "HTTP 502");
    await reporter.reportRecovery("chat completions");
    await reporter.reportRecovery("chat completions");

    expect(send).toHaveBeenCalledTimes(2);
    expect(send.mock.calls[0]![0]).toMatchObject({
      subject: "[Whisper Polish] OpenRouter needs attention",
    });
    expect(send.mock.calls[1]![0]).toMatchObject({
      subject: "[Whisper Polish] OpenRouter recovered",
    });
  });

  it("sends one low-balance warning until the balance recovers", async () => {
    const send = vi.fn().mockResolvedValue(undefined);
    const reporter = new OpenRouterIncidentReporter({ send });

    await reporter.reportBalance(19.5, 25);
    await reporter.reportBalance(18, 25);
    await reporter.reportBalance(30, 25);
    await reporter.reportBalance(20, 25);

    expect(send).toHaveBeenCalledTimes(2);
    expect(send.mock.calls[0]![0].subject).toBe("[Whisper Polish] OpenRouter key allowance is low");
    expect(send.mock.calls[1]![0].subject).toBe("[Whisper Polish] OpenRouter key allowance is low");
  });

  it("retries an alert later if email delivery fails", async () => {
    const send = vi.fn()
      .mockRejectedValueOnce(new Error("SES unavailable"))
      .mockResolvedValueOnce(undefined);
    const reporter = new OpenRouterIncidentReporter({ send });

    await expect(reporter.reportFailure("chat completions", "HTTP 402 insufficient credits"))
      .rejects.toThrow("SES unavailable");
    await reporter.reportFailure("chat completions", "HTTP 402 insufficient credits");

    expect(send).toHaveBeenCalledTimes(2);
  });

  it("tracks health-check and chat outages independently", async () => {
    const send = vi.fn().mockResolvedValue(undefined);
    const reporter = new OpenRouterIncidentReporter({ send });

    await reporter.reportFailure("chat completions", "HTTP 502");
    await reporter.reportFailure("key health check", "HTTP 401");
    await reporter.reportRecovery("key health check");

    expect(send).toHaveBeenCalledTimes(3);
    expect(send.mock.calls[2]![0].text).toContain("key health check");
  });

  it("coalesces concurrent outage alerts", async () => {
    let release!: () => void;
    const pending = new Promise<void>((resolve) => { release = resolve; });
    const send = vi.fn().mockReturnValue(pending);
    const reporter = new OpenRouterIncidentReporter({ send });

    const first = reporter.reportFailure("chat completions", "HTTP 502");
    const second = reporter.reportFailure("chat completions", "HTTP 502");
    expect(send).toHaveBeenCalledTimes(1);

    release();
    await Promise.all([first, second]);
  });
});
