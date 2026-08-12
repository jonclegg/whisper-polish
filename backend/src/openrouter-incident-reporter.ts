export type AlertMessage = {
  subject: string;
  text: string;
};

export type AlertSender = {
  send(message: AlertMessage): Promise<void>;
};

export interface OpenRouterIncidentSink {
  reportFailure(incident: string, detail: string): Promise<void>;
  reportRecovery(incident: string): Promise<void>;
  reportBalance(remainingDollars: number, thresholdDollars: number): Promise<void>;
}

export class OpenRouterIncidentReporter implements OpenRouterIncidentSink {
  private readonly activeOutages = new Set<string>();
  private readonly outageTransitions = new Map<string, Promise<void>>();
  private lowBalanceActive = false;
  private balanceTransition?: Promise<void>;

  constructor(private readonly sender: AlertSender) {}

  async reportFailure(incident: string, detail: string): Promise<void> {
    if (this.activeOutages.has(incident)) return;
    const existing = this.outageTransitions.get(incident);
    if (existing) return existing;
    const transition = this.sender.send({
        subject: "[Whisper Polish] OpenRouter needs attention",
        text: [
          "Whisper Polish Cloud cannot currently use OpenRouter.",
          "",
          `Component: ${incident}`,
          `Reason: ${detail}`,
          `Detected: ${new Date().toISOString()}`,
          "",
          "Check the OpenRouter balance, API key, model availability, and status page.",
        ].join("\n"),
      })
      .then(() => { this.activeOutages.add(incident); })
      .finally(() => { this.outageTransitions.delete(incident); });
    this.outageTransitions.set(incident, transition);
    return transition;
  }

  async reportRecovery(incident: string): Promise<void> {
    if (!this.activeOutages.has(incident)) return;
    await this.sender.send({
      subject: "[Whisper Polish] OpenRouter recovered",
      text: [
        `Whisper Polish Cloud successfully reached OpenRouter again for ${incident}.`,
        "",
        `Recovered: ${new Date().toISOString()}`,
      ].join("\n"),
    });
    this.activeOutages.delete(incident);
  }

  async reportBalance(remainingDollars: number, thresholdDollars: number): Promise<void> {
    if (remainingDollars >= thresholdDollars) {
      this.lowBalanceActive = false;
      return;
    }
    if (this.lowBalanceActive) return;
    if (this.balanceTransition) return this.balanceTransition;
    this.balanceTransition = this.sender.send({
        subject: "[Whisper Polish] OpenRouter key allowance is low",
        text: [
          `The Whisper Polish OpenRouter key has $${remainingDollars.toFixed(2)} of its spend allowance remaining.`,
          `The configured alert threshold is $${thresholdDollars.toFixed(2)}.`,
          "",
          "Review the key limit and account credits in OpenRouter to avoid interrupting cloud polish requests.",
        ].join("\n"),
      })
      .then(() => { this.lowBalanceActive = true; })
      .finally(() => { this.balanceTransition = undefined; });
    return this.balanceTransition;
  }
}
