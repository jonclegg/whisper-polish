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
  reportAllowance(remainingDollars: number, thresholdDollars: number): Promise<void>;
}

export class OpenRouterIncidentReporter implements OpenRouterIncidentSink {
  private readonly activeOutages = new Set<string>();
  private readonly outageTransitions = new Map<string, Promise<void>>();
  private lowAllowanceActive = false;
  private allowanceTransition?: Promise<void>;

  constructor(private readonly sender: AlertSender) {}

  async reportFailure(incident: string, detail: string): Promise<void> {
    const existing = this.outageTransitions.get(incident);
    if (existing) {
      try {
        await existing;
      } catch {
        return;
      }
      return this.reportFailure(incident, detail);
    }
    if (this.activeOutages.has(incident)) return;
    this.activeOutages.add(incident);
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
      .catch((error) => {
        this.activeOutages.delete(incident);
        throw error;
      })
      .finally(() => { this.outageTransitions.delete(incident); });
    this.outageTransitions.set(incident, transition);
    return transition;
  }

  async reportRecovery(incident: string): Promise<void> {
    const existing = this.outageTransitions.get(incident);
    if (existing) {
      try {
        await existing;
      } catch {
        return;
      }
      return this.reportRecovery(incident);
    }
    if (!this.activeOutages.has(incident)) return;
    const transition = this.sender.send({
        subject: "[Whisper Polish] OpenRouter recovered",
        text: [
          `Whisper Polish Cloud successfully reached OpenRouter again for ${incident}.`,
          "",
          `Recovered: ${new Date().toISOString()}`,
        ].join("\n"),
      })
      .then(() => { this.activeOutages.delete(incident); })
      .finally(() => { this.outageTransitions.delete(incident); });
    this.outageTransitions.set(incident, transition);
    return transition;
  }

  async reportAllowance(remainingDollars: number, thresholdDollars: number): Promise<void> {
    if (this.allowanceTransition) {
      try {
        await this.allowanceTransition;
      } catch {
        return;
      }
      return this.reportAllowance(remainingDollars, thresholdDollars);
    }
    if (remainingDollars >= thresholdDollars) {
      this.lowAllowanceActive = false;
      return;
    }
    if (this.lowAllowanceActive) return;
    this.allowanceTransition = this.sender.send({
        subject: "[Whisper Polish] OpenRouter key allowance is low",
        text: [
          `The Whisper Polish OpenRouter key has $${remainingDollars.toFixed(2)} of its spend allowance remaining.`,
          `The configured alert threshold is $${thresholdDollars.toFixed(2)}.`,
          "",
          "Review the key limit and account credits in OpenRouter to avoid interrupting cloud polish requests.",
        ].join("\n"),
      })
      .then(() => { this.lowAllowanceActive = true; })
      .finally(() => { this.allowanceTransition = undefined; });
    return this.allowanceTransition;
  }
}
