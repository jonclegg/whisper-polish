# Tokenizes a public text source into word ids over the keyboard's word list,
# for training the base prediction model.
#
# Usage: python prepare.py WORK_DIR SOURCE
#   SOURCE is dialogue, reddit, tweets, or subtitles; reads its parquet files
#   from WORK_DIR/data and writes WORK_DIR/data/tokens-SOURCE.npy (int32) and
#   base-vocabulary.txt.
#
# Id 0 marks a sentence boundary, 1 a word outside the list.

import array
import os
import re
import sys

import numpy
import pyarrow.parquet

LEXICON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../WhisperPolishKeyboard/Lexicon/words.txt")
TOKEN = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?|[.!?\n]+")
SPLIT_APOSTROPHE = re.compile(r"\s+'\s*(?=[a-z])")
TWEET_NOISE = re.compile(r"https?://\S+|[@#]\w+|\bRT\b")
BOUNDARY = 0
UNKNOWN = 1

###############################################################################

def vocabulary():
    words = []
    seen = set()
    with open(LEXICON) as source:
        for line in source.read().split("\n"):
            word = line.lower()
            if word and word not in seen:
                seen.add(word)
                words.append(word)
    return words

###############################################################################

def column(paths, name):
    for path in paths:
        for batch in pyarrow.parquet.ParquetFile(path).iter_batches(columns=[name], batch_size=65536):
            yield from batch.column(0).to_pylist()

###############################################################################

def dialogue(data):
    for name in ("soda-train.parquet", "dailydialog-train.parquet"):
        table = pyarrow.parquet.read_table(f"{data}/{name}")
        key = "dialogue" if "dialogue" in table.column_names else "utterances"
        for turns in table.column(key).to_pylist():
            yield from turns

###############################################################################

def reddit(data):
    """Comments come lowercased with apostrophes split off: "isn ' t"."""
    for body in column(sorted(f"{data}/{f}" for f in os.listdir(data) if f.startswith("reddit-")), "body"):
        if body and body not in ("[deleted]", "[removed]"):
            yield SPLIT_APOSTROPHE.sub("'", body)

###############################################################################

def tweets(data):
    for tweet in column(sorted(f"{data}/{f}" for f in os.listdir(data) if f.startswith("tweets-")), "tweet"):
        if tweet:
            yield TWEET_NOISE.sub(" ", tweet)

###############################################################################

def subtitles(data):
    """Each row is a whole film, a line per utterance."""
    for text in column(sorted(f"{data}/{f}" for f in os.listdir(data) if f.startswith("subtitles-")), "text"):
        if text:
            yield text

###############################################################################

SOURCES = {"dialogue": dialogue, "reddit": reddit, "tweets": tweets, "subtitles": subtitles}

###############################################################################

def tokenize(texts, index):
    ids = array.array("i", [BOUNDARY])
    for text in texts:
        for token in TOKEN.findall(text.replace("’", "'")):
            if not token[0].isalpha():
                if ids[-1] != BOUNDARY:
                    ids.append(BOUNDARY)
                continue
            ids.append(index.get(token.lower(), UNKNOWN))
        if ids[-1] != BOUNDARY:
            ids.append(BOUNDARY)
    return numpy.frombuffer(ids, dtype=numpy.int32)

###############################################################################

def main():
    work, source = sys.argv[1], sys.argv[2]
    words = vocabulary()
    index = {word: n + 2 for n, word in enumerate(words)}
    tokens = tokenize(SOURCES[source](f"{work}/data"), index)
    numpy.save(f"{work}/data/tokens-{source}.npy", tokens)
    with open(f"{work}/data/base-vocabulary.txt", "w") as out:
        out.write("\n".join(["<s>", "<unk>"] + words) + "\n")
    print(f"{source}: {len(tokens)} tokens, {numpy.mean(tokens == UNKNOWN):.4f} unknown")

###############################################################################

if __name__ == "__main__":
    main()
