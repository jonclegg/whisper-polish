# Builds round two's rough inputs: real dictation (AMI meetings, YODAS YouTube
# captions) and synthetic casual messages, with a share of each roughed up as
# sloppy phone typing, and a polish style assigned to each (40% custom styles).
#
# Usage: python assemble_round2.py OUT.jsonl SYNTHETIC.jsonl

import json
import random
import sys

import common
import typing_noise

AMI_COUNT = 8000
TYPED_SHARE = {"ami": 0.15, "yodas": 0.2, "synthetic": 0.3}
CUSTOM_SHARE = 0.4


def main():
    out, synthetic_path = sys.argv[1], sys.argv[2]
    rng = random.Random(2)
    ami = common.read_jsonl(common.DATA / "real-ami.jsonl")[:AMI_COUNT]
    yodas = common.read_jsonl(common.DATA / "real-yodas.jsonl")
    synthetic = [{**row, "source": "synthetic"} for row in common.read_jsonl(synthetic_path)]
    custom_styles = json.load(open(common.DATA / "custom-styles.json"))[:170]
    styles = list(common.STYLES)
    rows = []
    for row in ami + yodas + synthetic:
        text = row["text"]
        typed = rng.random() < TYPED_SHARE[row["source"]]
        if typed:
            text = typing_noise.rough_up(text, rng)
        style = "custom" if rng.random() < CUSTOM_SHARE else rng.choice(styles)
        instruction = rng.choice(custom_styles) if style == "custom" else common.STYLES[style]
        rows.append({"id": f"r2-{row['source']}-{len(rows):05d}", "source": row["source"], "typed": typed,
                     "text": text, "style": style, "instruction": instruction})
    rng.shuffle(rows)
    common.write_jsonl(out, rows)
    counts = {source: sum(row["source"] == source for row in rows) for source in TYPED_SHARE}
    print(f"wrote {len(rows)} round-two inputs: {counts}, typed {sum(row['typed'] for row in rows)}, "
          f"custom {sum(row['style'] == 'custom' for row in rows)}")


if __name__ == "__main__":
    main()
