# Trains the keyboard's word LSTM on a CUDA machine from public text only.
# Embeddings are tied to the output layer through a projection, so the model
# stays small enough for a keyboard extension.
#
# Usage: python train.py DATA_DIR NAME --corpora dialogue,reddit --embedding 192 --hidden 512 --layers 1 --tokens 300000000
#   reads DATA_DIR/tokens-CORPUS.npy for each corpus and base-vocabulary.txt
#   writes DATA_DIR/models/NAME/{weights.npz,config.json,log.txt}

import argparse
import json
import math
import os
import time

import numpy
import torch

###############################################################################

class WordModel(torch.nn.Module):
    def __init__(self, vocabulary_size, embedding, hidden, layers, dropout):
        super().__init__()
        self.embedding = torch.nn.Embedding(vocabulary_size, embedding)
        self.lstm = torch.nn.LSTM(embedding, hidden, num_layers=layers, batch_first=True, dropout=dropout if layers > 1 else 0)
        self.dropout = torch.nn.Dropout(dropout)
        self.projection = torch.nn.Linear(hidden, embedding)
        self.bias = torch.nn.Parameter(torch.zeros(vocabulary_size))
        torch.nn.init.normal_(self.embedding.weight, std=0.05)

    def forward(self, ids):
        hidden, _ = self.lstm(self.dropout(self.embedding(ids)))
        return self.projection(self.dropout(hidden)) @ self.embedding.weight.T + self.bias

###############################################################################

def batch(tokens, size, length, generator):
    starts = torch.randint(0, len(tokens) - length - 1, (size,), device=tokens.device, generator=generator)
    rows = tokens[starts[:, None] + torch.arange(length + 1, device=tokens.device)].long()
    return rows[:, :-1], rows[:, 1:]

###############################################################################

def perplexity(model, tokens, length):
    model.eval()
    rows = len(tokens) // (length + 1)
    data = tokens[:rows * (length + 1)].view(rows, length + 1)[:4096].long()
    total = 0.0
    with torch.no_grad(), torch.autocast("cuda", dtype=torch.bfloat16):
        for start in range(0, len(data), 256):
            chunk = data[start:start + 256]
            logits = model(chunk[:, :-1]).float()
            total += torch.nn.functional.cross_entropy(logits.reshape(-1, logits.shape[-1]), chunk[:, 1:].reshape(-1), reduction="sum").item()
    model.train()
    return math.exp(total / (len(data) * length))

###############################################################################

def export(model, directory, config):
    """Weights as float32 numpy arrays in PyTorch's gate order (input, forget, cell, output)."""
    os.makedirs(directory, exist_ok=True)
    arrays = {name: parameter.detach().float().cpu().numpy() for name, parameter in model.named_parameters()}
    numpy.savez(f"{directory}/weights.npz", **arrays)
    with open(f"{directory}/config.json", "w") as out:
        json.dump(config, out)

###############################################################################

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("data")
    parser.add_argument("name")
    parser.add_argument("--corpora", default="dialogue", help="comma-separated token files to train on, sampled by size")
    parser.add_argument("--embedding", type=int, default=192)
    parser.add_argument("--hidden", type=int, default=512)
    parser.add_argument("--layers", type=int, default=1)
    parser.add_argument("--dropout", type=float, default=0.1)
    parser.add_argument("--tokens", type=int, default=300_000_000, help="training tokens to see in total")
    parser.add_argument("--batch", type=int, default=256)
    parser.add_argument("--length", type=int, default=64)
    parser.add_argument("--rate", type=float, default=2e-3)
    args = parser.parse_args()

    torch.manual_seed(0)
    corpora = [numpy.load(f"{args.data}/tokens-{name}.npy") for name in args.corpora.split(",")]
    held_out = [len(tokens) // 200 for tokens in corpora]
    training = torch.from_numpy(numpy.concatenate([t[:-h] for t, h in zip(corpora, held_out)])).cuda()
    validation = torch.from_numpy(numpy.concatenate([t[-h:] for t, h in zip(corpora, held_out)])).cuda()
    with open(f"{args.data}/base-vocabulary.txt") as source:
        size = len(source.read().split("\n")) - 1
    model = WordModel(size, args.embedding, args.hidden, args.layers, args.dropout).cuda()
    steps = args.tokens // (args.batch * args.length)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.rate, weight_decay=0.01)
    schedule = torch.optim.lr_scheduler.OneCycleLR(optimizer, max_lr=args.rate, total_steps=steps, pct_start=0.02, final_div_factor=50)
    generator = torch.Generator(device="cuda").manual_seed(0)
    directory = f"{args.data}/models/{args.name}"
    os.makedirs(directory, exist_ok=True)
    log = open(f"{directory}/log.txt", "w")
    config = {"corpora": args.corpora, "embedding": args.embedding, "hidden": args.hidden, "layers": args.layers, "vocabulary_size": size}
    parameters = sum(p.numel() for p in model.parameters())
    print(f"{args.name}: {parameters / 1e6:.1f}M parameters, {steps} steps", file=log, flush=True)
    started = time.time()
    for step in range(1, steps + 1):
        inputs, targets = batch(training, args.batch, args.length, generator)
        with torch.autocast("cuda", dtype=torch.bfloat16):
            logits = model(inputs)
        loss = torch.nn.functional.cross_entropy(logits.float().reshape(-1, size), targets.reshape(-1))
        optimizer.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        optimizer.step()
        schedule.step()
        if step % 500 == 0:
            rate = step * args.batch * args.length / (time.time() - started)
            print(f"step {step}/{steps} loss {loss.item():.3f} {rate:.0f} tokens/s", file=log, flush=True)
        if step % 5000 == 0 or step == steps:
            print(f"step {step} validation perplexity {perplexity(model, validation, args.length):.2f}", file=log, flush=True)
            export(model, directory, config)
    print(f"done in {time.time() - started:.0f}s", file=log, flush=True)

###############################################################################

if __name__ == "__main__":
    main()
