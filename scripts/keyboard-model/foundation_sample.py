# Samples word positions from the dev block with the n-gram predictors' top
# three for each, so the system model's guesses can be scored on the same spots.
#
# Usage: python foundation_sample.py WORK_DIR COUNT  -> WORK_DIR/foundation-sample.json
#        python foundation_sample.py WORK_DIR score  (after the Swift probe fills in "system")

import json
import random
import sys

import numpy

import bench
import evaluate_prediction as evaluation

###############################################################################

def top3(probabilities, vocab):
    return [vocab.words[i] for i in numpy.argsort(-probabilities)[:3]]

###############################################################################

def sample(work, count):
    setup = bench.Setup()
    with open(f"{work}/data/base-vocabulary.txt") as source:
        base_words = source.read().split("\n")[:-1]
    base = bench.BaseModel(bench.load_base(work, 4, {}), base_words, setup.vocab)
    positions = [(text, start, word, previous) for text in setup.dev for word, start, previous in evaluation.words_with_context(text)]
    random.Random(0).shuffle(positions)
    rows = []
    for text, start, word, previous in positions[:count]:
        personal = setup.personal.distribution(previous)
        kn4 = base.distribution(previous)
        rows.append({
            "before": text[:start],
            "word": word.lower(),
            "shipping": setup.lexicon.shipping_slots(previous, ""),
            "personal": top3(personal, setup.vocab),
            "kn4": top3(kn4, setup.vocab),
            "personal+kn4": top3(0.8 * personal + 0.2 * kn4, setup.vocab),
        })
    with open(f"{work}/foundation-sample.json", "w") as out:
        json.dump(rows, out, indent=1)

###############################################################################

def score(work):
    with open(f"{work}/foundation-sample.json") as source:
        rows = json.load(source)
    rows = [row for row in rows if "system" in row]
    names = [name for name in rows[0] if name not in ("before", "word", "latency")]
    for name in names:
        hits = sum(row["word"] in [w.lower() for w in row[name]] for row in rows)
        print(f"{name:14} bar {hits / len(rows):.3f}  ({hits}/{len(rows)})")
    union = sum(row["word"] in [w.lower() for w in row["system"] + row["personal+kn4"]] for row in rows)
    print(f"{'either (6)':14} bar {union / len(rows):.3f}")
    latencies = sorted(row["latency"] for row in rows)
    print(f"latency median {latencies[len(latencies) // 2]:.0f}ms  p90 {latencies[int(len(latencies) * 0.9)]:.0f}ms")

###############################################################################

if __name__ == "__main__":
    if sys.argv[2] == "score":
        score(sys.argv[1])
    else:
        sample(sys.argv[1], int(sys.argv[2]))
