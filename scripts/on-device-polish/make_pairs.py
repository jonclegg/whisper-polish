# Turns sampled polishes into preference pairs. First, with --expand, it writes
# each sample as its own row for check_references.py. Then it pairs a sample the
# checker passed with one it rejected, for the same prompt. When every sample
# failed, the cloud polish (already fact-checked) stands in as the good one.
#
# Usage: python make_pairs.py --expand PROMPTS.jsonl SAMPLES.jsonl ROWS.jsonl
#        python make_pairs.py PROMPTS.jsonl SAMPLES.jsonl KEPT.jsonl OUT.jsonl

import difflib
import random
import sys

import common

# Styles where a much shorter polish would mean dropped content. Bullets, social
# and custom styles can rightly cut a lot, so length says nothing there.
LENGTH_CHECKED = {common.STYLES[style] for style in ("cleanup", "message", "slack", "email", "reddit", "blog", "marketing", "formal")}


def parse(user):
    style_line, text = user.split("\n\nText:\n", 1)
    return style_line.removeprefix("Style: "), text


def usable_good(sample, bad, text, instruction):
    # Guards against winning by copying the input or by cutting content.
    if difflib.SequenceMatcher(None, sample, text).ratio() > 0.97:
        return False
    return instruction not in LENGTH_CHECKED or len(sample) >= 0.7 * len(bad)


def main():
    if sys.argv[1] == "--expand":
        prompts, samples, out = sys.argv[2:5]
        users = {row["id"]: row["user"] for row in common.read_jsonl(prompts)}
        rows = []
        for row in common.read_jsonl(samples):
            instruction, text = parse(users[row["id"]])
            for index, sample in enumerate(row["samples"]):
                rows.append({"id": f"{row['id']}#{index}", "text": text, "instruction": instruction, "output": sample})
        common.write_jsonl(out, rows)
        print(f"wrote {len(rows)} samples to check")
        return
    prompts, samples, kept_path, out = sys.argv[1:5]
    rng = random.Random(6)
    by_id = {row["id"]: row for row in common.read_jsonl(prompts)}
    kept = {row["id"] for row in common.read_jsonl(kept_path)}
    pairs, from_reference, skipped = [], 0, 0
    for row in common.read_jsonl(samples):
        prompt = by_id[row["id"]]
        instruction, text = parse(prompt["user"])
        good = [s for index, s in enumerate(row["samples"]) if f"{row['id']}#{index}" in kept]
        bad = [s for index, s in enumerate(row["samples"]) if f"{row['id']}#{index}" not in kept]
        if not bad:
            skipped += 1
            continue
        rejected = rng.choice(bad)
        candidates = [s for s in good if usable_good(s, rejected, text, instruction)]
        if candidates:
            chosen = rng.choice(candidates)
        else:
            chosen = prompt["output"]
            from_reference += 1
        pairs.append({"id": row["id"], "user": prompt["user"], "chosen": chosen, "rejected": rejected})
    common.write_jsonl(out, pairs)
    print(f"{len(pairs)} pairs ({from_reference} with the cloud polish as the good one); "
          f"{skipped} prompts had no bad sample")


if __name__ == "__main__":
    main()
