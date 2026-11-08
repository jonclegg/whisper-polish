# Cuts the AMI meeting corpus's manual transcripts (CC BY 4.0) into single-speaker
# stretches of real, unedited speech: filler, repeats and false starts kept.
#
# Usage: python real_ami.py AMI_DIR OUT.jsonl

import glob
import json
import random
import re
import sys
import xml.etree.ElementTree as ElementTree

GAP_SECONDS = 2.5


def segments(path):
    words, last_end = [], None
    for element in ElementTree.parse(path).getroot():
        tag = element.tag.split("}")[-1]
        if tag != "w":
            continue
        start = float(element.get("starttime", "nan"))
        if last_end is not None and start == start and start - last_end > GAP_SECONDS and words:
            yield words
            words = []
        words.append((element.text or "", element.get("punc") == "true"))
        end = float(element.get("endtime", "nan"))
        if end == end:
            last_end = end
    if words:
        yield words


def join(words):
    text = ""
    for word, punctuation in words:
        text += word if punctuation or not text else " " + word
    return re.sub(r"\s+", " ", text).strip()


def main():
    directory, out = sys.argv[1], sys.argv[2]
    rows = []
    for path in sorted(glob.glob(f"{directory}/words/*.words.xml")):
        meeting = path.split("/")[-1].split(".words")[0]
        for index, words in enumerate(segments(path)):
            spoken = sum(1 for word, punctuation in words if not punctuation)
            if 25 <= spoken <= 230:
                rows.append({"source": "ami", "license": "CC BY 4.0", "id": f"ami-{meeting}-{index}", "text": join(words)})
    random.Random(0).shuffle(rows)
    with open(out, "w") as sink:
        for row in rows:
            sink.write(json.dumps(row) + "\n")
    print(f"wrote {len(rows)} AMI segments")


if __name__ == "__main__":
    main()
