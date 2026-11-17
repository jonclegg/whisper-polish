#!/usr/bin/env bash
# Round four: round three's training, on answers with the filler hedges cut
# (clean_fillers.py). Trains Qwen3.5-0.8B on the cleaned answers, preference-
# trains it on the cleaned pairs on the same box, brings back the 8-bit GGUF,
# and tests it on the 110 test notes and the 500 hard notes.
#
#     ./run_round4.sh    # after clean_fillers.py has written data/sft-r4.jsonl and data/r4/dpo-pairs.jsonl
set -euo pipefail
cd "$(dirname "$0")"
# The box idles while run-training.sh tests the first model here, so allow for that.
export AWS_PROFILE=jclegg HOURS=12
name=qwen3.5-0.8b-r4
box=cloud/train-box.sh
ssh_options=(-i "$HOME/.ssh/whisper-polish-train" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
cloud/run-training.sh $name Qwen/Qwen3.5-0.8B data/sft-r4.jsonl --epochs 2 --lr 3e-5
ip="$($box up)"
rsync -a -e "ssh ${ssh_options[*]}" cloud/train_dpo.py data/r4/dpo-pairs.jsonl "ubuntu@$ip:~/"
$box ssh "source /opt/pytorch/bin/activate && cd ~ && python train_dpo.py runs/$name/merged dpo-pairs.jsonl runs/${name}dpo --lr 5e-6 > runs-${name}dpo.log 2>&1; echo EXIT=\$? >> runs-${name}dpo.log"
$box ssh "grep -E \"final eval|EXIT=\" runs-${name}dpo.log | tail -3"
$box ssh "grep -q EXIT=0 runs-${name}dpo.log" || { $box down; exit 1; }
rsync -a -e "ssh ${ssh_options[*]}" "ubuntu@$ip:~/runs/${name}dpo/model-q8_0.gguf" ~/dev/ondevice-models/tuned/${name}dpo-Q8_0.gguf
$box down
model=~/dev/ondevice-models/tuned/${name}dpo-Q8_0.gguf
python3 polish_local.py $model data/eval2-inputs.jsonl data/cand2-tuned-${name}dpo-Q8_0.jsonl --prompt tuned --temperature 0
python3 judge.py data/eval2-reference.jsonl data/cand2-tuned-${name}dpo-Q8_0.jsonl
python3 polish_local.py $model data/r3/holdout-inputs.jsonl data/r4/holdout-${name}dpo.jsonl --prompt tuned --temperature 0
python3 check_references.py data/r4/holdout-${name}dpo.jsonl data/r4/holdout-${name}dpo-kept.jsonl
echo "== all done"
