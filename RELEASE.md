# Release log

## 2026-11-25 - OpenRouter dev key moves from Secrets Manager to SSM Parameter Store

- PR: this branch (`ssm-params`).
- What changed: `scripts/fetch-dev-keys.sh` reads SSM SecureString `/roger-archive/openrouter` (`aws ssm get-parameter --with-decryption`) instead of Secrets Manager `roger-archive/openrouter`. `deploy/README.md` names the new source.
- Operator action: none for the app. Developers running the script need `ssm:GetParameter` on that parameter under the `jclegg` profile. Delete the old secret separately.
- Cost: saves $0.40/month; standard SSM parameters are free.
