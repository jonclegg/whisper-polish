# Builds the keyboard's word list: the most frequent English words, each
# written the way it's usually written mid-sentence ("I", "Monday"), and
# cased-after.txt, the words capitalized only after a particular word
# ("united States", "in May").
# The word model's vocabulary is this list, so changing it means retraining
# the model with scripts/keyboard-model. --recase keeps the list's words and
# order and only redoes how they're written, which needs no retraining.
#
# Usage: python3 scripts/build-keyboard-lexicon.py [--recase] WhisperPolishKeyboard/Lexicon CORPUS.parquet...
#
# Corpora are SODA (allenai/soda) and DailyDialog (roskoN/dailydialog) parquet
# files from Hugging Face. Requires: pyarrow, wordfreq.

import collections
import math
import re
import sys

import pyarrow.parquet
import wordfreq

VOCABULARY_SIZE = 40000
# A word is written capitalized when its uses show, with 95% confidence, that at
# least this share of mid-sentence uses are; fewer uses than this keep the form it has.
CAPITAL_SHARE = 0.8
CAPITAL_USES = 20
# After a particular word, a stricter bar over fewer uses.
CAPITAL_SHARE_AFTER = 0.9
CAPITAL_USES_AFTER = 10
# Not context for a capital: SODA's stage directions ("(laughs) Yeah") put a
# sentence start after them, and greetings come before its made-up names ("hey Blue").
NOT_CONTEXT = {"hey", "hi", "hello", "bye", "goodbye", "thanks", "dear", "oh", "yes", "no", "okay", "ok", "sorry", "well", "please",
    "laughs", "laugh", "sigh", "sighs", "chuckles", "giggles", "smiles", "gasps", "nods", "coughs", "cries", "pauses", "groans", "whispers", "shrugs", "smirks", "grins", "yawns"}
TOKEN = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?|[.!?]+|[,;:\"()\u201c\u201d]+")

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
    """How each word is capitalized after another listed word, away from the start of a sentence,
    overall and by the word before it."""
    forms = collections.defaultdict(collections.Counter)
    after = collections.defaultdict(collections.Counter)
    for path in paths:
        for text in utterances(path):
            starts_sentence = True
            # A comma or quote ends a word's context but not the sentence: "Thank you, Sandy".
            previous = None
            for token in TOKEN.findall(text.replace("’", "'")):
                lower = token.lower()
                if not token[0].isalpha():
                    starts_sentence = starts_sentence or token[0] in ".!?"
                    previous = None
                    continue
                if lower not in known:
                    starts_sentence = True
                    previous = None
                    continue
                if not starts_sentence:
                    forms[lower][token] += 1
                    if previous is not None:
                        after[(previous, lower)][token] += 1
                starts_sentence = False
                previous = lower
    return forms, after

###############################################################################

def lower_bound(hits, total):
    """The Wilson score interval's lower end at 95%: the share `hits` of `total` surely reaches."""
    z = 1.96
    share = hits / total
    center = share + z * z / (2 * total)
    spread = z * math.sqrt(share * (1 - share) / total + z * z / (4 * total * total))
    return (center - spread) / (1 + z * z / total)

###############################################################################

def capitalized_form(word, counts, share, uses, confident):
    """The capitalized way `word` is written, if `counts` show it usually is; None if not;
    `word` itself when there are too few uses to tell."""
    total = sum(counts.values())
    if total < uses:
        return word
    capitalized = [(count, form) for form, count in counts.items() if form != word]
    hits = total - counts[word]
    if capitalized and (lower_bound(hits, total) if confident else hits / total) >= share:
        return max(capitalized)[1]
    return None

###############################################################################

def display_form(word, listed, forms):
    """`listed` is how the list writes it now, kept when the corpora can't tell."""
    if word == "i" or word.startswith("i'"):
        return "I" + word[1:]
    if word not in forms:
        return listed
    form = capitalized_form(word, forms[word], CAPITAL_SHARE, CAPITAL_USES, confident=True)
    if form is None:
        return word
    # Keep the list's own capitals ("LeBron", "IKEA") when it stays capitalized.
    return listed if form == word or listed != word else form

###############################################################################

def cased_after(displays, after):
    """Words written lowercase that are capitalized after a particular word, as "previous Form" lines."""
    lines = []
    for (previous, word), counts in sorted(after.items()):
        if previous in NOT_CONTEXT or displays.get(word) != word:
            continue
        form = capitalized_form(word, counts, CAPITAL_SHARE_AFTER, CAPITAL_USES_AFTER, confident=False)
        if form not in (None, word):
            lines.append(f"{previous} {form}")
    return lines

###############################################################################

def main():
    recase = sys.argv[1] == "--recase"
    output_dir, paths = sys.argv[1 + recase], sys.argv[2 + recase:]
    if recase:
        with open(f"{output_dir}/words.txt") as source:
            listed = [line for line in source.read().split("\n") if line]
    else:
        listed = vocabulary()
    words = [form.lower() for form in listed]
    forms, after = case_forms(paths, set(words))
    displays = {word: display_form(word, form, forms) for word, form in zip(words, listed)}
    with open(f"{output_dir}/words.txt", "w") as out:
        for word in words:
            out.write(displays[word] + "\n")
    with open(f"{output_dir}/cased-after.txt", "w") as out:
        out.write("\n".join(cased_after(displays, after)) + "\n")

###############################################################################

if __name__ == "__main__":
    main()
