#!/usr/bin/env bash
# Round three's data: fact-check round two's references, write new inputs full of
# misheard words and typos, polish them and the rejects with the stricter
# reference prompt, fact-check those, and build the training set. Stops when
# OpenRouter spend passes the budget.
#
#     ./run_round3.sh BASELINE_USD BUDGET_USD
set -euo pipefail
cd "$(dirname "$0")"
baseline="$1" budget="$2"
guard() { python3 spend_guard.py "$baseline" "$budget"; }
d=data/r3
python3 check_references.py $d/r2-all-reference.jsonl $d/r2-all-kept.jsonl; guard
FOCUS_SHARE=0.8 FOCUS_COUNT=2 CUSTOM_SHARE=0.3 python3 make_inputs.py $d/synthetic.jsonl 6000 6 anthropic/claude-haiku-5.5; guard
python3 assemble_round3.py $d/inputs.jsonl $d/synthetic.jsonl $d/r2-all-kept.rejected.jsonl
python3 polish_remote.py $d/inputs.jsonl $d/reference.jsonl; guard
python3 check_references.py $d/reference.jsonl $d/kept.jsonl; guard
python3 prepare_sft.py data/sft-r3.jsonl $d/r2-all-kept.jsonl $d/kept.jsonl
