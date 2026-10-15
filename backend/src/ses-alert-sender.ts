import { SendEmailCommand, SESv2Client } from "@aws-sdk/client-sesv2";
import type { AlertMessage, AlertSender } from "./openrouter-incident-reporter.js";

export class SESAlertSender implements AlertSender {
  private readonly client: SESv2Client;

  constructor(
    region: string,
    private readonly from: string,
    private readonly to: string,
  ) {
    this.client = new SESv2Client({ region });
  }

  async send(message: AlertMessage): Promise<void> {
    await this.client.send(new SendEmailCommand({
      FromEmailAddress: this.from,
      Destination: { ToAddresses: [this.to] },
      Content: {
        Simple: {
          Subject: { Data: message.subject, Charset: "UTF-8" },
          Body: { Text: { Data: message.text, Charset: "UTF-8" } },
        },
      },
    }));
  }
}
