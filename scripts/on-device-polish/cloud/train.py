# Fine-tunes a small causal LM to polish like the cloud model (runs on the GPU box).
# Each example is the tuned prompt ("Style: ...\n\nText:\n...") and the cloud output;
# loss is on the output only. Writes a merged Hugging Face model and a GGUF.
#
# Usage: python train.py BASE_MODEL DATA.jsonl OUT_DIR [--epochs N] [--lr LR] [--lora RANK]

import argparse
import json
import pathlib
import random
import subprocess

import torch
from datasets import Dataset
from transformers import AutoModelForCausalLM, AutoTokenizer
from trl import SFTConfig, SFTTrainer


def prompt_text(tokenizer, user):
    messages = [{"role": "user", "content": user}]
    try:
        return tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True, enable_thinking=False)
    except TypeError:
        return tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("base")
    parser.add_argument("data")
    parser.add_argument("out")
    parser.add_argument("--epochs", type=float, default=2)
    parser.add_argument("--lr", type=float, default=2e-5)
    parser.add_argument("--lora", type=int, default=0)
    parser.add_argument("--batch", type=int, default=16)
    arguments = parser.parse_args()
    out = pathlib.Path(arguments.out)

    tokenizer = AutoTokenizer.from_pretrained(arguments.base)
    rows = [json.loads(line) for line in open(arguments.data)]
    random.Random(0).shuffle(rows)
    examples = [{"prompt": prompt_text(tokenizer, row["user"]), "completion": row["output"]} for row in rows]
    validation = Dataset.from_list(examples[:200])
    train = Dataset.from_list(examples[200:])
    print(f"{len(train)} train, {len(validation)} validation; eos {tokenizer.eos_token!r}")
    print(examples[0]["prompt"][-300:] + examples[0]["completion"][:100])

    model = AutoModelForCausalLM.from_pretrained(arguments.base, dtype=torch.bfloat16, attn_implementation="sdpa")
    peft_config = None
    if arguments.lora:
        from peft import LoraConfig
        peft_config = LoraConfig(r=arguments.lora, lora_alpha=arguments.lora * 2, lora_dropout=0.05,
                                 target_modules="all-linear", task_type="CAUSAL_LM")
    config = SFTConfig(
        output_dir=str(out / "checkpoints"),
        num_train_epochs=arguments.epochs,
        learning_rate=arguments.lr,
        lr_scheduler_type="cosine",
        warmup_steps=30,
        per_device_train_batch_size=arguments.batch,
        gradient_accumulation_steps=max(1, 32 // arguments.batch),
        per_device_eval_batch_size=arguments.batch,
        bf16=True,
        gradient_checkpointing=True,
        max_length=1536,
        completion_only_loss=True,
        eval_strategy="steps",
        eval_steps=100,
        logging_steps=20,
        save_strategy="no",
        report_to=[],
    )
    trainer = SFTTrainer(model=model, args=config, train_dataset=train, eval_dataset=validation,
                         processing_class=tokenizer, peft_config=peft_config)
    trainer.train()
    print("final eval", trainer.evaluate())
    model = trainer.model
    if arguments.lora:
        model = model.merge_and_unload()
    merged = out / "merged"
    model.save_pretrained(merged, safe_serialization=True)
    tokenizer.save_pretrained(merged)
    subprocess.run(["python", str(pathlib.Path.home() / "llama.cpp/convert_hf_to_gguf.py"), str(merged),
                    "--outtype", "q8_0", "--outfile", str(out / "model-q8_0.gguf")], check=True)
    print("done", out)


if __name__ == "__main__":
    main()
