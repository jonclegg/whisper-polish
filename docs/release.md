# Release log

## 2026-11-17: round four Polish training, cutting words like "really"

- **For users:** nothing yet. The round-four model (`qwen3.5-0.8b-r4dpo-Q8_0.gguf`) is trained and tested but not shipped; the app still downloads round three.
- **What changed:** `clean_fillers.py` cuts filler hedges from training answers, `run_round4.sh` trains on them, the training box launches in whichever us-east-1 zone has a free L4 and converts with llama.cpp b11869 (the app's release), and `check_references.py` fact-checks through `claude -p` with Haiku instead of OpenRouter.
- **Operator:** to ship it, upload the GGUF to the model bucket under `polish/` and change `OnDevicePolishModel.fileName` and `byteCount`.
- **Cost:** about $6.45 of GPU time (g6.xlarge, 8 hours at $0.80/h). Cleaning, judging and fact-checking ran on the Claude subscription.
