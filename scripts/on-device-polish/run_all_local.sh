#!/bin/bash
# Polishes and judges the eval set with every downloaded GGUF model and both prompts.
set -e
cd "$(dirname "$0")"
for model in ~/dev/ondevice-models/*.gguf; do
  name=$(basename "$model" .gguf | sed 's/.*--//' | tr 'A-Z' 'a-z')
  for prompt in ${PROMPTS:-app compact}; do
    out=data/cand-$name-$prompt.jsonl
    [ -f "$out" ] || python3 polish_local.py "$model" data/eval-inputs.jsonl "$out" --prompt $prompt
    [ -f "${out%.jsonl}.judged.jsonl" ] || python3 judge.py data/eval-reference.jsonl "$out" &
  done
done
wait
