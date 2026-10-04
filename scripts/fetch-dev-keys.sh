#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"
aws_region="us-east-1" # pragma: allowlist secret

openrouter_key="$(aws secretsmanager get-secret-value \
    --profile jclegg \
    --region "$aws_region" \
    --secret-id roger-archive/openrouter \
    --query SecretString \
    --output text \
    --no-cli-pager)"

if [[ "$openrouter_key" != sk-or-* ]]; then
    echo "fetch-dev-keys: roger-archive/openrouter is not an OpenRouter key" >&2
    exit 1
fi

mkdir -p Config
umask 077
printf 'OPENROUTER_API_KEY = %s\n' "$openrouter_key" > Config/DevKeys.xcconfig
echo "fetch-dev-keys: wrote Config/DevKeys.xcconfig"
