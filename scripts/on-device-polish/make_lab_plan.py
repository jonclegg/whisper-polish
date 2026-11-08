# Writes the plan the keyboard lab runs on the phone (see OnDeviceLab.swift).
#
# Usage: python make_lab_plan.py OUT_DIR STEPSET   (STEPSET: survey | tuned:<model.gguf>[,<model.gguf>])

import json
import pathlib
import sys

import common
import prompts


def inputs():
    rows = common.read_jsonl(common.DATA / "eval-inputs.jsonl")
    by_length = sorted(rows, key=lambda row: len(row["text"]))
    picks = [by_length[len(rows) // 5], by_length[len(rows) // 2], by_length[-6]]
    return [{"id": row["id"], "style": row["style"], "text": row["text"]} for row in picks]


def survey():
    llama = lambda model, gpu: {"id": f"llama-{'gpu' if gpu else 'cpu'}-{model.split('.gguf')[0]}", "kind": "llama",
                                "model": model, "gpuLayers": 99 if gpu else 0, "prompt": "compact", "contextTokens": 1536}
    return [
        {"id": "probe", "kind": "probe"},
        {"id": "writing-tools", "kind": "writingTools"},
        {"id": "mmap-s1-mini", "kind": "mmapTouch", "model": "s1-mini-q4_k_m.gguf"},
        {"id": "foundation-app", "kind": "foundation", "prompt": "app"},
        {"id": "foundation-compact", "kind": "foundation", "prompt": "compact"},
        {"id": "foundation-burst", "kind": "foundationBurst"},
        llama("gemma-3-270m-it-Q8_0.gguf", False),
        llama("Qwen3-0.6B-Q8_0.gguf", False),
        llama("s1-mini-q4_k_m.gguf", False),
        llama("Qwen3-1.7B-Q4_K_M.gguf", False),
        llama("gemma-3-270m-it-Q8_0.gguf", True),
        llama("Qwen3-0.6B-Q8_0.gguf", True),
        {"id": "dirty", "kind": "dirty"},
        {"id": "probe-end", "kind": "probe"},
    ]


def main():
    out, stepset = pathlib.Path(sys.argv[1]), sys.argv[2]
    if stepset == "survey":
        steps = survey()
    elif stepset.startswith("coreai:"):
        steps = [{"id": "probe", "kind": "probe"}]
        for model in stepset.split(":", 1)[1].split(","):
            steps.append({"id": f"coreai-first-load-{model}", "kind": "coreai", "model": model, "inputCount": 3})
            steps.append({"id": f"coreai-cached-{model}", "kind": "coreai", "model": model, "inputCount": 3})
    elif stepset.startswith("lookup:"):
        steps = [{"id": "probe", "kind": "probe"}]
        for model in stepset.split(":", 1)[1].split(","):
            for draft in (0, 3, 6):
                steps.append({"id": f"gpu-draft{draft}-{model}", "kind": "llama", "model": model, "gpuLayers": 99,
                              "prompt": "tuned", "contextTokens": 1024, "cacheBits": 8, "extraBuffers": False,
                              "microBatch": 256, "threads": 4, "inputCount": 3, "draftLength": draft})
    elif stepset.startswith("gpu:"):
        steps = [{"id": "probe", "kind": "probe"}]
        for model in stepset.split(":", 1)[1].split(","):
            for micro in (64, 256):
                steps.append({"id": f"gpu-ub{micro}-{model}", "kind": "llama", "model": model, "gpuLayers": 99,
                              "prompt": "tuned", "contextTokens": 1024, "cacheBits": 8, "extraBuffers": False,
                              "microBatch": micro, "threads": 4, "inputCount": 3})
    elif stepset.startswith("threads:"):
        steps = [{"id": "probe", "kind": "probe"}]
        model = stepset.split(":", 1)[1]
        for threads in (2, 4, 6):
            steps.append({"id": f"threads{threads}-{model}", "kind": "llama", "model": model, "gpuLayers": 0, "cpuOnly": True,
                          "prompt": "tuned", "contextTokens": 1024, "cacheBits": 8, "extraBuffers": False,
                          "microBatch": 16, "threads": threads, "inputCount": 3})
    elif stepset == "memory":
        steps = [{"id": "probe", "kind": "probe"}]
        for model in ["Qwen3-0.6B-Q8_0.gguf", "Qwen3-1.7B-Q4_K_M.gguf"]:
            for context, bits, micro in ((1024, 4, 32), (768, 8, 32), (1024, 4, 128)):
                steps.append({"id": f"ctx{context}-kv{bits}-ub{micro}-{model}", "kind": "llama", "model": model, "gpuLayers": 0,
                              "cpuOnly": True, "prompt": "compact", "contextTokens": context, "cacheBits": bits,
                              "extraBuffers": False, "microBatch": micro})
    else:
        steps = [{"id": "probe", "kind": "probe"}]
        for model in stepset.split(":", 1)[1].split(","):
            for micro in (16, 32):
                steps.append({"id": f"tuned-cpu-ub{micro}-{model}", "kind": "llama", "model": model, "gpuLayers": 0,
                              "cpuOnly": True, "prompt": "tuned", "contextTokens": 1024, "cacheBits": 8,
                              "extraBuffers": False, "microBatch": micro, "inputCount": 3})
    plan = {
        "steps": steps,
        "inputs": inputs(),
        "prompts": {
            "app": {style: common.system_prompt(text) for style, text in common.STYLES.items()},
            "compact": {style: prompts.COMPACT.format(style=text) for style, text in common.STYLES.items()},
            "instruction": dict(common.STYLES),
        },
    }
    out.mkdir(parents=True, exist_ok=True)
    (out / "plan.json").write_text(json.dumps(plan, indent=1))
    print(f"wrote {len(steps)} steps to {out / 'plan.json'}")


if __name__ == "__main__":
    main()
