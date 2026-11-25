#!/usr/bin/env bash
# Preference-trains a tuned model on the GPU box (cloud/train_dpo.py), brings
# back its 8-bit GGUF, and shuts the box down.
#
#     cloud/run-dpo.sh NAME MODEL_HF_DIR PAIRS.jsonl [train_dpo.py options...]
#     cloud/run-dpo.sh qwen3.5-0.8b-r4dpo2 ~/dev/ondevice-models/tuned/qwen3.5-0.8b-r4-hf data/r4/dpo-pairs-own.jsonl --lr 5e-6
set -euo pipefail
cd "$(dirname "$0")/.."
name="$1" model="$2" pairs="$3"; shift 3
export HOURS="${HOURS:-3}"
box=cloud/train-box.sh
ip="$($box up)"
ssh_options=(-i "$HOME/.ssh/whisper-polish-train" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
$box setup
rsync -a -e "ssh ${ssh_options[*]}" "$model/" "ubuntu@$ip:~/dpo-base/"
rsync -a -e "ssh ${ssh_options[*]}" cloud/train.py cloud/train_dpo.py "$pairs" "ubuntu@$ip:~/"
$box ssh "source /opt/pytorch/bin/activate && cd ~ && python train_dpo.py dpo-base $(basename "$pairs") runs/$name $* > runs-$name.log 2>&1; echo EXIT=\$? >> runs-$name.log"
$box ssh "grep -E \"final eval|EXIT=\" runs-$name.log | tail -2"
$box ssh "grep -q EXIT=0 runs-$name.log" || { $box down; exit 1; }
rsync -a -e "ssh ${ssh_options[*]}" "ubuntu@$ip:~/runs/$name/model-q8_0.gguf" ~/dev/ondevice-models/tuned/$name-Q8_0.gguf
$box down
echo "wrote ~/dev/ondevice-models/tuned/$name-Q8_0.gguf"
