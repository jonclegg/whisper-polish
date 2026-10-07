# Builds the keyboard's word list: the most frequent English words, each
# written the way it's usually written mid-sentence ("I", "Monday").
# The word model's vocabulary is this list, so changing it means retraining
# the model with scripts/keyboard-model.
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

def case_forms(paths, known):
    """How each word is capitalized after another listed word, away from the start of a sentence."""
    forms = collections.defaultdict(collections.Counter)
    for path in paths:
        for text in utterances(path):
            starts_sentence = True
            for token in TOKEN.findall(text.replace("’", "'")):
                if token[0] in ".!?" or token.lower() not in known:
                    starts_sentence = True
                    continue
                if not starts_sentence:
                    forms[token.lower()][token] += 1
                starts_sentence = False
    return forms

###############################################################################

def display_form(word, forms):
    if word == "i" or word.startswith("i'"):
        return "I" + word[1:]
    if word not in forms:
        return word
    return forms[word].most_common(1)[0][0]

###############################################################################

def main():
    output_dir, paths = sys.argv[1], sys.argv[2:]
    words = vocabulary()
    forms = case_forms(paths, set(words))
    with open(f"{output_dir}/words.txt", "w") as out:
        for word in words:
            out.write(display_form(word, forms) + "\n")

###############################################################################

if __name__ == "__main__":
    main()
