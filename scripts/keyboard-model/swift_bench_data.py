# Writes the text the Swift prediction benchmark replays: your text from one
# stage's window (to learn first), contact names, and the dev messages to score.
#
# Usage: python swift_bench_data.py WORK_DIR STAGE LIMIT OUTPUT.json [dev|test]

import json
import sys

import bench
import evaluate_prediction as evaluation

###############################################################################

def main():
    work, stage, limit, output = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    train, notes, contacts, cutoff, dev, test = bench.load_splits()
    scored = test if len(sys.argv) > 5 and sys.argv[5] == "test" else dev
    days = bench.STAGES[stage]
    start = cutoff - days * bench.DAY if days is not None else float("-inf")
    personal = [evaluation.normalized(item["text"]) for item in train + notes if item["date"] >= start]
    with open(output, "w") as out:
        json.dump({"personal": personal, "contacts": [c for c in contacts if evaluation.WORD.fullmatch(c)], "scored": scored[:limit]}, out)

###############################################################################

if __name__ == "__main__":
    main()
