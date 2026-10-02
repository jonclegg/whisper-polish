# Builds the keyboard's word list and next-word tables.
#
# Usage: python3 scripts/build-keyboard-lexicon.py WhisperPolishKeyboard/Lexicon CORPUS.parquet...
#
# Corpora are SODA (allenai/soda) and DailyDialog (roskoN/dailydialog) parquet
# files from Hugging Face. Requires: pyarrow, wordfreq.

import collections
import re
import sys

import pyarrow.parquet
import wordfreq

VOCABULARY_SIZE = 40000
UNIGRAM_CONTEXTS = 15000
BIGRAM_MIN_COUNT = 40
FOLLOWERS = 8
SENTENCE_START = "<s>"
TOKEN = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?|[.!?]+")

###############################################################################

def utterances(path):
    table = pyarrow.parquet.read_table(path)
    column = "dialogue" if "dialogue" in table.column_names else "utterances"
    for dialogue in table.column(column).to_pylist():
        yield from dialogue

###############################################################################

def vocabulary():
    words = []
    for word in wordfreq.top_n_list("en", VOCABULARY_SIZE * 2):
        if re.fullmatch(r"[a-z]+(?:'[a-z]+)?", word):
            words.append(word)
        if len(words) == VOCABULARY_SIZE:
            return words
    return words

###############################################################################

def count(paths, known):
    bigrams = collections.defaultdict(collections.Counter)
    trigrams = collections.defaultdict(collections.Counter)
    case_forms = collections.defaultdict(collections.Counter)
    for path in paths:
        for text in utterances(path):
            previous = [SENTENCE_START]
            for token in TOKEN.findall(text.replace("\u2019", "'")):
                if token[0] in ".!?":
                    previous = [SENTENCE_START]
                    continue
                word = token.lower()
                if word not in known:
                    previous = [SENTENCE_START]
                    continue
                if previous[-1] != SENTENCE_START:
                    case_forms[word][token] += 1
                bigrams[previous[-1]][word] += 1
                if len(previous) == 2:
                    trigrams[" ".join(previous)][word] += 1
                previous = (previous + [word])[-2:]
    return bigrams, trigrams, case_forms

###############################################################################

def display_form(word, case_forms):
    if word == "i" or word.startswith("i'"):
        return "I" + word[1:]
    forms = case_forms.get(word)
    if not forms:
        return word
    return forms.most_common(1)[0][0]

###############################################################################

def followers(counter, case_forms):
    return [display_form(w, case_forms) for w, _ in counter.most_common(FOLLOWERS)]

###############################################################################

def main():
    output_dir, paths = sys.argv[1], sys.argv[2:]
    words = vocabulary()
    bigrams, trigrams, case_forms = count(paths, set(words))

    with open(f"{output_dir}/words.txt", "w") as out:
        for word in words:
            out.write(display_form(word, case_forms) + "\n")

    contexts = sorted(bigrams, key=lambda c: -sum(bigrams[c].values()))[:UNIGRAM_CONTEXTS]
    with open(f"{output_dir}/next-words.txt", "w") as out:
        for context in contexts:
            out.write(f"{context}\t{' '.join(followers(bigrams[context], case_forms))}\n")
        for context, counter in trigrams.items():
            if sum(counter.values()) >= BIGRAM_MIN_COUNT:
                out.write(f"{context}\t{' '.join(followers(counter, case_forms))}\n")

###############################################################################

if __name__ == "__main__":
    main()
