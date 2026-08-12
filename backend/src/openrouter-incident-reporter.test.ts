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

  it("sends one low-allowance warning until the allowance recovers", async () => {
    const send = vi.fn().mockResolvedValue(undefined);
    const reporter = new OpenRouterIncidentReporter({ send });

    await reporter.reportAllowance(19.5, 25);
    await reporter.reportAllowance(18, 25);
    await reporter.reportAllowance(30, 25);
    await reporter.reportAllowance(20, 25);

    expect(send).toHaveBeenCalledTimes(2);
    expect(send.mock.calls[0]![0].subject).toBe("[Whisper Polish] OpenRouter key allowance is low");
    expect(send.mock.calls[1]![0].subject).toBe("[Whisper Polish] OpenRouter key allowance is low");
  });

  it("allows a new warning after allowance recovers during email delivery", async () => {
    let releaseWarning!: () => void;
    const pendingWarning = new Promise<void>((resolve) => { releaseWarning = resolve; });
    const send = vi.fn()
      .mockReturnValueOnce(pendingWarning)
      .mockResolvedValueOnce(undefined);
    const reporter = new OpenRouterIncidentReporter({ send });

    const warning = reporter.reportAllowance(20, 25);
    const recovery = reporter.reportAllowance(30, 25);
    releaseWarning();
    await Promise.all([warning, recovery]);
    await reporter.reportAllowance(20, 25);

    expect(send).toHaveBeenCalledTimes(2);
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

  it("coalesces concurrent recovery alerts", async () => {
    let release!: () => void;
    const pending = new Promise<void>((resolve) => { release = resolve; });
    const send = vi.fn()
      .mockResolvedValueOnce(undefined)
      .mockReturnValueOnce(pending);
    const reporter = new OpenRouterIncidentReporter({ send });
    await reporter.reportFailure("chat completions", "HTTP 502");

    const first = reporter.reportRecovery("chat completions");
    const second = reporter.reportRecovery("chat completions");
    expect(send).toHaveBeenCalledTimes(2);

    release();
    await Promise.all([first, second]);
  });

  it("reports a new failure that arrives while recovery is being delivered", async () => {
    let releaseRecovery!: () => void;
    const pendingRecovery = new Promise<void>((resolve) => { releaseRecovery = resolve; });
    const send = vi.fn()
      .mockResolvedValueOnce(undefined)
      .mockReturnValueOnce(pendingRecovery)
      .mockResolvedValueOnce(undefined);
    const reporter = new OpenRouterIncidentReporter({ send });
    await reporter.reportFailure("chat completions", "HTTP 502");

    const recovery = reporter.reportRecovery("chat completions");
    const newFailure = reporter.reportFailure("chat completions", "HTTP 503");
    releaseRecovery();
    await Promise.all([recovery, newFailure]);

    expect(send).toHaveBeenCalledTimes(3);
    expect(send.mock.calls[2]![0].text).toContain("HTTP 503");
  });
});
