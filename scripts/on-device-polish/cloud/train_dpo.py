# Preference-trains a tuned polish model on its own faithful and unfaithful
# polishes (runs on the GPU box): each pair is one prompt, a polish the fact
# checker passed, and one it rejected. A little ordinary loss on the passed
# polish keeps the writing from drifting. Writes a GGUF like train.py.
#
# Usage: python train_dpo.py MODEL_DIR PAIRS.jsonl OUT_DIR [--beta 0.1] [--lr 1e-6]

import argparse
import json
import pathlib
import random
import subprocess

import torch
from datasets import Dataset
from transformers import AutoModelForCausalLM, AutoTokenizer
from trl import DPOConfig, DPOTrainer

from train import prompt_text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model")
    parser.add_argument("pairs")
    parser.add_argument("out")
    parser.add_argument("--beta", type=float, default=0.1)
    parser.add_argument("--lr", type=float, default=1e-6)
    parser.add_argument("--epochs", type=float, default=1)
    parser.add_argument("--sft-weight", type=float, default=0.2)
    arguments = parser.parse_args()
    out = pathlib.Path(arguments.out)

    tokenizer = AutoTokenizer.from_pretrained(arguments.model)
    rows = [json.loads(line) for line in open(arguments.pairs)]
    random.Random(0).shuffle(rows)
    examples = [{"prompt": prompt_text(tokenizer, row["user"]), "chosen": row["chosen"], "rejected": row["rejected"]}
                for row in rows]
    validation, train = Dataset.from_list(examples[:200]), Dataset.from_list(examples[200:])
    print(f"{len(train)} train pairs, {len(validation)} validation", flush=True)

    model = AutoModelForCausalLM.from_pretrained(arguments.model, dtype=torch.bfloat16, attn_implementation="sdpa")
    config = DPOConfig(
        output_dir=str(out / "checkpoints"),
        beta=arguments.beta,
        loss_type=["sigmoid", "sft"],
        loss_weights=[1.0, arguments.sft_weight],
        num_train_epochs=arguments.epochs,
        learning_rate=arguments.lr,
        lr_scheduler_type="cosine",
        warmup_steps=20,
        per_device_train_batch_size=4,
        gradient_accumulation_steps=8,
        per_device_eval_batch_size=4,
        bf16=True,
        gradient_checkpointing=True,
        max_length=1536,
        eval_strategy="steps",
        eval_steps=50,
        logging_steps=10,
        save_strategy="no",
        report_to=[],
    )
    trainer = DPOTrainer(model=model, args=config, train_dataset=train, eval_dataset=validation,
                         processing_class=tokenizer)
    trainer.train()
    print("final eval", trainer.evaluate(), flush=True)
    merged = out / "merged"
    trainer.model.save_pretrained(merged, safe_serialization=True)
    tokenizer.save_pretrained(merged)
    subprocess.run(["python", str(pathlib.Path.home() / "llama.cpp/convert_hf_to_gguf.py"), str(merged),
                    "--outtype", "q8_0", "--outfile", str(out / "model-q8_0.gguf")], check=True)
    print("done", out)


if __name__ == "__main__":
    main()
