# Roughs up text the way fast thumb-typing on a phone does: neighbouring-key
# slips, dropped and doubled letters, missing apostrophes and capitals, words
# run together, and texting shorthand.

import random
import re

ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
NEIGHBOURS = {}
for row_index, row in enumerate(ROWS):
    for column, letter in enumerate(row):
        near = set()
        for other_row in (row_index - 1, row_index, row_index + 1):
            if 0 <= other_row < len(ROWS):
                for other_column in (column - 1, column, column + 1):
                    if 0 <= other_column < len(ROWS[other_row]):
                        near.add(ROWS[other_row][other_column])
        near.discard(letter)
        NEIGHBOURS[letter] = sorted(near)

SHORTHAND = {"you": "u", "your": "ur", "you're": "ur", "tomorrow": "tmrw", "because": "bc", "though": "tho",
             "please": "pls", "thanks": "thx", "probably": "prob", "really": "rly", "don't know": "idk",
             "to be honest": "tbh", "with": "w", "people": "ppl", "okay": "ok", "minutes": "mins"}


def slip(word, rng):
    letters = [index for index, character in enumerate(word) if character.lower() in NEIGHBOURS]
    if not letters:
        return word
    index = rng.choice(letters)
    kind = rng.random()
    if kind < 0.45:
        replacement = rng.choice(NEIGHBOURS[word[index].lower()])
        return word[:index] + replacement + word[index + 1:]
    if kind < 0.7:
        return word[:index] + word[index + 1:]
    if kind < 0.85:
        return word[:index] + word[index] + word[index:]
    if index + 1 < len(word):
        return word[:index] + word[index + 1] + word[index] + word[index + 2:]
    return word


def rough_up(text, rng, intensity=None):
    """A sloppily typed version of `text`; intensity is the chance a word gets a slip."""
    intensity = intensity if intensity is not None else rng.choice([0.02, 0.05, 0.09])
    if rng.random() < 0.6:
        text = text.lower()
    if rng.random() < 0.7:
        text = text.replace("'", "").replace("’", "")
    if rng.random() < 0.5:
        for phrase, short in SHORTHAND.items():
            if rng.random() < 0.6:
                text = re.sub(rf"\b{re.escape(phrase)}\b", short, text, flags=re.IGNORECASE)
    if rng.random() < 0.5:
        text = re.sub(r"[,;]", "", text) if rng.random() < 0.5 else re.sub(r"\.(\s)", r"\1", text)
    words = text.split(" ")
    out = []
    for word in words:
        if len(word) > 2 and rng.random() < intensity:
            word = slip(word, rng)
        out.append(word)
        if out and rng.random() < intensity / 4 and len(out) > 1:
            out[-2:] = [out[-2] + out[-1]]
    return " ".join(out)


if __name__ == "__main__":
    rng = random.Random(1)
    sample = "Hey Dana, it's Marco. I can't make Friday because the dentist moved my appointment. Can you push our call to Monday at 10? Thanks!"
    for _ in range(4):
        print(rough_up(sample, rng))
