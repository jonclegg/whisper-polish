# Turns cloud polishes into fine-tuning examples in the tuned prompt format,
# dropping replies that look broken.
#
# Usage: python prepare_sft.py OUT.jsonl REFERENCE.jsonl [REFERENCE.jsonl ...]

import sys

import common
import prompts


def usable(row):
    output, text = row["output"], row["text"]
    if not output or len(output) > 3 * len(text) + 400 or len(output) < 0.1 * len(text):
        return False
    lowered = output.lower()
    return not lowered.startswith(("here's", "here is", "sure", "<transcript>")) and "</transcript>" not in lowered


def main():
    out, sources = sys.argv[1], sys.argv[2:]
    rows = [row for source in sources for row in common.read_jsonl(source)]
    kept = [{"id": row["id"], "user": prompts.tuned_user(row["text"], common.instruction(row)), "output": row["output"].replace("—", ", ")}
            for row in rows if usable(row)]
    common.write_jsonl(out, kept)
    print(f"kept {len(kept)} of {len(rows)}")


if __name__ == "__main__":
    main()
