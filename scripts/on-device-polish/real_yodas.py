# Cuts YODAS automatic YouTube captions (CC BY 3.0, Creative Commons videos only)
# into stretches of real, unpunctuated speech-recognition text, at most three per video.
#
# Usage: python real_yodas.py OUT.jsonl CAPTION_FILE [CAPTION_FILE ...]

import itertools
import json
import random
import sys


def videos(path):
    rows = []
    for line in open(path, encoding="utf-8", errors="replace"):
        key, _, text = line.rstrip("\n").partition(" ")
        if text.strip():
            rows.append((key.rsplit("-", 3)[0], text.strip()))
    for video, lines in itertools.groupby(rows, key=lambda row: row[0]):
        yield video, [text for _, text in lines]


def main():
    out, paths = sys.argv[1], sys.argv[2:]
    rng = random.Random(0)
    rows = []
    for path in paths:
        for video, lines in videos(path):
            position, taken = rng.randrange(0, 20), 0
            while position < len(lines) and taken < 3:
                target = rng.choice([40, 70, 120, 190])
                words, end = 0, position
                while end < len(lines) and words < target:
                    words += len(lines[end].split())
                    end += 1
                text = " ".join(lines[position:end])
                # Captions tag music and sound effects in brackets; those stretches are lyrics or noise.
                if 25 <= words <= 230 and "[" not in text:
                    rows.append({"source": "yodas", "license": "CC BY 3.0", "id": f"yodas-{video}-{position}",
                                 "text": text})
                    taken += 1
                position = end + rng.randrange(20, 80)
    rng.shuffle(rows)
    with open(out, "w") as sink:
        for row in rows:
            sink.write(json.dumps(row) + "\n")
    print(f"wrote {len(rows)} YODAS segments from {len(paths)} files")


if __name__ == "__main__":
    main()
