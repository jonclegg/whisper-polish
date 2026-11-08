#!/usr/bin/env bash
# Trains one polish model on the GPU box, brings back its GGUF, quantizes it here,
# and scores it against the cloud reference.
#
#     cloud/run-training.sh NAME BASE_MODEL SFT.jsonl [train.py options...]
#     cloud/run-training.sh qwen3-0.6b-full Qwen/Qwen3-0.6B data/sft-a.jsonl --epochs 2 --lr 2e-5
set -euo pipefail
cd "$(dirname "$0")/.."
name="$1" base="$2" data="$3"; shift 3
box=cloud/train-box.sh
ip="$($box up)"
ssh_options=(-i "$HOME/.ssh/whisper-polish-train" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
# A fresh box needs the training stack and llama.cpp's GGUF converter.
$box ssh 'test -d ~/llama.cpp || { source /opt/pytorch/bin/activate && pip install -q trl peft datasets accelerate "transformers>=4.57" sentencepiece && git clone -q --depth 1 https://github.com/ggml-org/llama.cpp ~/llama.cpp && pip install -q -e ~/llama.cpp/gguf-py; }' > /dev/null 2>&1
rsync -a -e "ssh ${ssh_options[*]}" cloud/train.py "$data" "ubuntu@$ip:~/"
$box ssh "source /opt/pytorch/bin/activate && cd ~ && python train.py $base $(basename "$data") runs/$name $* > runs-$name.log 2>&1; echo EXIT=\$? >> runs-$name.log"
$box ssh "grep -E \"eval_loss|final eval|EXIT=\" runs-$name.log | tail -5"
mkdir -p ~/dev/ondevice-models/tuned
# The box exports 8-bit to halve the download; 4-bit is made from that here.
remote="$($box ssh "ls ~/runs/$name/model-*.gguf | head -1")"
rsync -a -e "ssh ${ssh_options[*]}" "ubuntu@$ip:$remote" ~/dev/ondevice-models/tuned/$name-download.gguf
for quant in Q8_0 Q4_K_M; do
  llama-quantize --allow-requantize ~/dev/ondevice-models/tuned/$name-download.gguf ~/dev/ondevice-models/tuned/$name-$quant.gguf $quant > /dev/null 2>&1
done
rm ~/dev/ondevice-models/tuned/$name-download.gguf
for quant in Q8_0 Q4_K_M; do
  out=data/cand-tuned-$name-$quant.jsonl
  python3 polish_local.py ~/dev/ondevice-models/tuned/$name-$quant.gguf data/eval-inputs.jsonl $out --prompt tuned --temperature 0
  python3 judge.py data/eval-reference.jsonl $out
  python3 polish_local.py ~/dev/ondevice-models/tuned/$name-$quant.gguf data/eval-custom-inputs.jsonl ${out%.jsonl}-custom.jsonl --prompt tuned --temperature 0
  python3 judge.py data/eval-custom-reference.jsonl ${out%.jsonl}-custom.jsonl
done
