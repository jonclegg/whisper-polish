#!/usr/bin/env bash
# Samples several polishes per prompt from a tuned model on the GPU box with
# vLLM (cloud/sample.py), brings them back, and shuts the box down. For
# preference pairs: the fact checker then sorts the samples (make_pairs.py).
#
#     cloud/run-sampling.sh MODEL_HF_DIR PROMPTS.jsonl SAMPLES.jsonl
set -euo pipefail
cd "$(dirname "$0")/.."
model="$1" prompts="$2" out="$3"
export HOURS="${HOURS:-3}"
box=cloud/train-box.sh
ip="$($box up)"
ssh_options=(-i "$HOME/.ssh/whisper-polish-train" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
$box ssh 'test -x ~/vllm-env/bin/python || { python3 -m venv ~/vllm-env && ~/vllm-env/bin/pip install -q vllm; }' > /dev/null 2>&1
rsync -a -e "ssh ${ssh_options[*]}" "$model/" "ubuntu@$ip:~/sample-model/"
rsync -a -e "ssh ${ssh_options[*]}" cloud/sample.py "$prompts" "ubuntu@$ip:~/"
$box ssh "cd ~ && ~/vllm-env/bin/python sample.py sample-model $(basename "$prompts") samples.jsonl > sampling.log 2>&1; echo EXIT=\$? >> sampling.log"
$box ssh "tail -3 sampling.log"
$box ssh "grep -q EXIT=0 sampling.log" || { $box down; exit 1; }
rsync -a -e "ssh ${ssh_options[*]}" "ubuntu@$ip:~/samples.jsonl" "$out"
$box down
echo "wrote $(wc -l < "$out") prompts' samples to $out"
