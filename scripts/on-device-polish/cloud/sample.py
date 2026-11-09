# Writes several sampled polishes per prompt with a tuned model through vLLM
# (runs on the GPU box, in its own environment), for preference pairs: the fact
# checker later sorts them into faithful and unfaithful. Prompts use the same
# chat template as training. Chunks land as they finish, so a stopped run resumes.
#
# Usage: ~/vllm-env/bin/python sample.py MODEL_DIR PROMPTS.jsonl OUT.jsonl [--samples 4]

import argparse
import json
import pathlib

from transformers import AutoTokenizer
from vllm import LLM, SamplingParams

CHUNK = 500


def prompt_text(tokenizer, user):
    messages = [{"role": "user", "content": user}]
    return tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True, enable_thinking=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model")
    parser.add_argument("prompts")
    parser.add_argument("out")
    parser.add_argument("--samples", type=int, default=4)
    parser.add_argument("--temperature", type=float, default=0.8)
    arguments = parser.parse_args()

    tokenizer = AutoTokenizer.from_pretrained(arguments.model)
    rows = [json.loads(line) for line in open(arguments.prompts)]
    out = pathlib.Path(arguments.out)
    done = {json.loads(line)["id"] for line in out.open()} if out.exists() else set()
    todo = [row for row in rows if row["id"] not in done]
    print(f"{len(done)} done, {len(todo)} to go", flush=True)
    llm = LLM(arguments.model, dtype="bfloat16", max_model_len=4096, gpu_memory_utilization=0.85,
              limit_mm_per_prompt={"image": 0, "video": 0})
    for start in range(0, len(todo), CHUNK):
        chunk = todo[start:start + CHUNK]
        prompts = [prompt_text(tokenizer, row["user"]) for row in chunk]
        parameters = [SamplingParams(n=arguments.samples, temperature=arguments.temperature, top_p=0.95,
                                     max_tokens=min(2 * len(tokenizer(row["output"]).input_ids) + 64, 1536))
                      for row in chunk]
        results = llm.generate(prompts, parameters, use_tqdm=False)
        with out.open("a") as sink:
            for row, result in zip(chunk, results):
                samples = [completion.text.strip() for completion in result.outputs]
                sink.write(json.dumps({"id": row["id"], "samples": samples}, ensure_ascii=False) + "\n")
        print(f"  {start + len(chunk)}/{len(todo)}", flush=True)
    print("done", flush=True)


if __name__ == "__main__":
    main()
