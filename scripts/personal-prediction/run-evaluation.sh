#!/usr/bin/env bash
# Compares the shipping keyboard predictor with personal n-gram and small-LM
# predictors on your own sent messages. Runs on an Apple silicon Mac with uv
# and Full Disk Access; results-*.json land in the work directory.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
WORK=~/Downloads/keyboard-prediction-eval
mkdir -p "$WORK"
cd "$WORK"

[[ -d .venv ]] || uv venv --python 3.13 .venv
uv pip install --python .venv/bin/python mlx-lm numpy
PYTHON=.venv/bin/python

train() {
  local model=$1 label=$2 rate=$3
  [[ -f "adapters-$label/adapters.safetensors" ]] && return
  "$PYTHON" -m mlx_lm lora --model "$model" --train --data finetune \
    --fine-tune-type full --num-layers -1 --batch-size 32 --iters 3000 --learning-rate "$rate" \
    --max-seq-length 256 --steps-per-report 250 --steps-per-eval 1000 --save-every 3000 \
    --adapter-path "adapters-$label" > "log-train-$label.txt" 2>&1
}

evaluate() {
  local label=$1
  shift
  "$PYTHON" "$SCRIPTS/evaluate_prediction.py" --label "$label" "$@" > "log-$label.txt" 2>&1
}

"$PYTHON" "$SCRIPTS/extract_corpus.py"
"$PYTHON" "$SCRIPTS/evaluate_prediction.py" --write-finetune-data finetune
# Pythia overflows in float16; its training loss is NaN from the first step.
[[ -d pythia31-f32 ]] || "$PYTHON" -m mlx_lm convert --hf-path EleutherAI/pythia-31m --mlx-path pythia31-f32 --dtype float32

train HuggingFaceTB/SmolLM2-135M smol135-personal 3e-5
train pythia31-f32 pythia31-personal 5e-5
evaluate ngram
evaluate smol135 --model HuggingFaceTB/SmolLM2-135M
evaluate smol135-personal --model HuggingFaceTB/SmolLM2-135M --adapter adapters-smol135-personal
evaluate pythia31 --model pythia31-f32
evaluate pythia31-personal --model pythia31-f32 --adapter adapters-pythia31-personal
