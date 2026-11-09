# Builds round three's inputs to polish with the stricter reference prompt: new
# synthetic messages full of misheard words and typos (a share roughed up further
# as sloppy phone typing), plus round two's inputs whose references failed the
# fact check, to polish again.
#
# Usage: python assemble_round3.py OUT.jsonl SYNTHETIC.jsonl REJECTED.jsonl

import random
import sys

import common
import typing_noise

TYPED_SHARE = 0.35


def main():
    out, synthetic_path, rejected_path = sys.argv[1:4]
    rng = random.Random(3)
    rows = []
    for index, row in enumerate(common.read_jsonl(synthetic_path)):
        typed = rng.random() < TYPED_SHARE
        text = typing_noise.rough_up(row["text"], rng) if typed else row["text"]
        rows.append({"id": f"r3-synthetic-{index:05d}", "source": "synthetic", "typed": typed, "text": text,
                     "style": row["style"], "instruction": row["instruction"]})
    retry = [{key: row[key] for key in ("id", "text", "style", "instruction") if key in row}
             for row in common.read_jsonl(rejected_path)]
    common.write_jsonl(out, rows + retry)
    print(f"wrote {len(rows)} new and {len(retry)} to polish again")


if __name__ == "__main__":
    main()
