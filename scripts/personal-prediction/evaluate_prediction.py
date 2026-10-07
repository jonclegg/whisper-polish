# Replays your most recent sent messages word by word and measures how often
# each predictor puts the word you actually typed in the suggestion bar.
# scripts/keyboard-model/bench.py scores the keyboard's shipping word model the same way.
# Trains on everything older; the last two blocks of messages are dev and test.
#
# Usage (on the Mac, after extract_corpus.py; see run-evaluation.sh):
#   python evaluate_prediction.py --label ngram
#   python evaluate_prediction.py --label smol135 --model HuggingFaceTB/SmolLM2-135M [--adapter DIR]
#   python evaluate_prediction.py --write-finetune-data DIR
#
# Bar model: with nothing typed it shows 3 predictions; once letters are typed
# it shows the literal letters plus 2 completions. Tapping a suggestion costs
# one tap and inserts the word and a space.

import argparse
import bisect
import collections
import json
import os
import re

import mlx.core
import mlx_lm
import numpy

import extract_corpus

LEXICON_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../WhisperPolishKeyboard/Lexicon")
SPLIT_MESSAGES = 1500
MIN_PERSONAL_COUNT = 2
DISCOUNT = 0.75
UNIFORM_SHARE = 0.01
FOLLOWER_SHARE = 0.5
LAMBDAS = [0.1, 0.3, 0.5, 0.7, 0.8, 0.9, 0.95, 0.98]
MAX_MESSAGE_TOKENS = 256
MAX_WORD_TOKENS = 8
TABLE_BATCH = 256
SENTENCE_START = "<s>"
DOCUMENT_START = "<|endoftext|>"
TOKEN = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?|[.!?\n]+")
WORD = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?")
PASTED = re.compile(r"https?://\S+|www\.\S+|\S+@\S+\.\S+")

###############################################################################

def load_splits():
    with open(extract_corpus.CORPUS) as source:
        corpus = json.load(source)
    messages = sorted(corpus["messages"], key=lambda m: m["date"])
    test = messages[-SPLIT_MESSAGES:]
    dev = messages[-2 * SPLIT_MESSAGES:-SPLIT_MESSAGES]
    train = messages[:-2 * SPLIT_MESSAGES]
    cutoff = dev[0]["date"]
    notes = [note["text"] for note in corpus["notes"] if note["date"] < cutoff]
    texts = lambda items: [normalized(item["text"]) for item in items]
    return texts(train), [normalized(n) for n in notes], corpus["contacts"], texts(dev), texts(test)

###############################################################################

def normalized(text):
    """Links and addresses get pasted, not typed, so they're left out."""
    return PASTED.sub(" ", text.replace("\u2019", "'"))

###############################################################################

def words_with_context(text):
    previous = []
    for match in TOKEN.finditer(text):
        token = match.group()
        if not token[0].isalpha():
            previous = []
            continue
        yield token, match.start(), previous[-2:]
        previous.append(token.lower())

###############################################################################

def sentences(text):
    sentence = []
    for token in TOKEN.findall(text):
        if token[0].isalpha():
            sentence.append(token.lower())
            continue
        if sentence:
            yield sentence
        sentence = []
    if sentence:
        yield sentence

###############################################################################

def unique(words):
    seen = set()
    return [w for w in words if not (w in seen or seen.add(w))]

###############################################################################

class GenericLexicon:
    """The keyboard's words.txt, by frequency."""

    def __init__(self):
        with open(f"{LEXICON_DIR}/words.txt") as source:
            display = [line for line in source.read().split("\n") if line]
        self.rank = {}
        self.display = {}
        for rank, word in enumerate(display):
            if word.lower() not in self.rank:
                self.rank[word.lower()] = rank
                self.display[word.lower()] = word

###############################################################################

class Vocabulary:
    def __init__(self, words):
        self.words = sorted(words)
        self.index = {w: i for i, w in enumerate(self.words)}

    def prefix_range(self, prefix):
        return bisect.bisect_left(self.words, prefix), bisect.bisect_left(self.words, prefix + "{")

###############################################################################

class PersonalStats:
    """Word counts, preferred capitalization, and sentences from your own text."""

    def __init__(self, texts, contacts):
        self.sentences = [s for text in texts for s in sentences(text)]
        self.counts = collections.Counter(w for s in self.sentences for w in s)
        cases = collections.defaultdict(collections.Counter)
        for text in texts:
            for token, _, previous in words_with_context(text):
                if previous:
                    cases[token.lower()][token] += 1
        self.contact_words = {name.lower() for name in contacts if WORD.fullmatch(name)}
        for name in contacts:
            if WORD.fullmatch(name):
                cases[name.lower()][name] += 1
        self.surface = {word: forms.most_common(1)[0][0] for word, forms in cases.items()}

    def vocabulary_words(self):
        typed = {w for w, c in self.counts.items() if c >= MIN_PERSONAL_COUNT}
        return typed | self.contact_words

###############################################################################

def sparse_table(counter, vocab):
    pairs = [(vocab.index[w], c) for w, c in counter.items() if w in vocab.index]
    if not pairs:
        return None
    indexes, counts = zip(*pairs)
    counts = numpy.array(counts, dtype=numpy.float64)
    return numpy.array(indexes), counts, counts.sum()

###############################################################################

def interpolate(table, lower):
    indexes, counts, total = table
    result = lower * (DISCOUNT * len(indexes) / total)
    result[indexes] += numpy.maximum(counts - DISCOUNT, 0) / total
    return result

###############################################################################

class PersonalNgram:
    """Interpolated absolute-discount trigram with a Kneser-Ney unigram, over your text."""

    def __init__(self, stats, vocab):
        bigrams = collections.defaultdict(collections.Counter)
        trigrams = collections.defaultdict(collections.Counter)
        predecessors = collections.defaultdict(set)
        for sentence in stats.sentences:
            tokens = [SENTENCE_START] + sentence
            for i in range(1, len(tokens)):
                bigrams[tokens[i - 1]][tokens[i]] += 1
                predecessors[tokens[i]].add(tokens[i - 1])
                if i >= 2:
                    trigrams[f"{tokens[i - 2]} {tokens[i - 1]}"][tokens[i]] += 1
        for word in stats.contact_words:
            predecessors[word].add(SENTENCE_START)
        continuation = numpy.array([len(predecessors.get(w, ())) for w in vocab.words], dtype=numpy.float64)
        self.unigram = (1 - UNIFORM_SHARE) * continuation / continuation.sum() + UNIFORM_SHARE / len(vocab.words)
        self.bigrams = {k: t for k, c in bigrams.items() if (t := sparse_table(c, vocab))}
        self.trigrams = {k: t for k, c in trigrams.items() if (t := sparse_table(c, vocab))}

    def distribution(self, previous):
        context = [SENTENCE_START] + previous[-2:]
        result = self.unigram
        if context[-1] in self.bigrams:
            result = interpolate(self.bigrams[context[-1]], result)
        key = " ".join(context[-2:])
        if len(context) >= 2 and key in self.trigrams:
            result = interpolate(self.trigrams[key], result)
        return result

###############################################################################

class GenericDistribution:
    """The word list as probabilities: a Zipf unigram by rank."""

    def __init__(self, lexicon, vocab):
        ranks = numpy.array([lexicon.rank.get(w, len(lexicon.rank)) for w in vocab.words], dtype=numpy.float64)
        weights = 1 / (ranks + 100)
        self.unigram = weights / weights.sum()

    def distribution(self, previous):
        return self.unigram

###############################################################################

class WordEntries:
    """Every surface spelling of every vocabulary word as tokens, for one leading-space mode."""

    def __init__(self, word_indexes, first, continuation):
        order = numpy.argsort(word_indexes, kind="stable")
        self.word_indexes = numpy.array(word_indexes)[order]
        self.first = numpy.array(first)[order]
        self.continuation = numpy.array(continuation, dtype=numpy.float32)[order]
        self.starts = numpy.flatnonzero(numpy.r_[True, self.word_indexes[1:] != self.word_indexes[:-1]])

###############################################################################

class LanguageModel:
    """Word probabilities from a token LM: P(first token | context) * P(rest | first token)."""

    def __init__(self, path, adapter, vocab, lexicon, stats):
        self.model, wrapper = mlx_lm.load(path, adapter_path=adapter)
        self.tokenizer = wrapper._tokenizer
        self.bos = self.tokenizer.bos_token_id if self.tokenizer.bos_token_id is not None else self.tokenizer.eos_token_id
        self.vocab = vocab
        spellings = [(i, s) for i, w in enumerate(vocab.words) for s in self.spellings(w, lexicon, stats)]
        self.entries = {space: self.word_entries(spellings, space) for space in (True, False)}

    @staticmethod
    def spellings(word, lexicon, stats):
        return unique([word, word[:1].upper() + word[1:], lexicon.display.get(word, word), stats.surface.get(word, word)])

    def encode(self, text):
        return self.tokenizer.encode(text, add_special_tokens=False)

    def word_entries(self, spellings, space):
        encoded = [(i, self.encode((" " if space else "") + s)[:MAX_WORD_TOKENS]) for i, s in spellings]
        continuation = numpy.zeros(len(encoded), dtype=numpy.float32)
        longer = sorted((n for n, (_, ids) in enumerate(encoded) if len(ids) > 1), key=lambda n: len(encoded[n][1]))
        for start in range(0, len(longer), TABLE_BATCH):
            batch = longer[start:start + TABLE_BATCH]
            picked = self.next_token_logprobs([[self.bos] + encoded[n][1] for n in batch])
            for row, n in enumerate(batch):
                continuation[n] = picked[row, 1:len(encoded[n][1])].sum()
        return WordEntries([i for i, _ in encoded], [ids[0] for _, ids in encoded], continuation)

    def logprobs(self, sequence):
        logits = self.model(mlx.core.array([sequence])).astype(mlx.core.float32)
        return logits - mlx.core.logsumexp(logits, axis=-1, keepdims=True)

    def next_token_logprobs(self, sequences):
        """`[row, m]` is the logprob of `sequences[row][m + 1]` given the tokens before it."""
        width = max(len(s) for s in sequences)
        padded = mlx.core.array([s + [0] * (width - len(s)) for s in sequences])
        logits = self.model(padded).astype(mlx.core.float32)
        logprobs = logits - mlx.core.logsumexp(logits, axis=-1, keepdims=True)
        return numpy.array(mlx.core.take_along_axis(logprobs[:, :-1], padded[:, 1:, None], axis=-1)[..., 0])

    def positions(self, text):
        """(word, previous words, next-token logprobs before the word, whether a space precedes it)."""
        encoding = self.tokenizer(text, return_offsets_mapping=True, add_special_tokens=False)
        ids = encoding["input_ids"][:MAX_MESSAGE_TOKENS]
        ends = [end for _, end in encoding["offset_mapping"][:MAX_MESSAGE_TOKENS]]
        logprobs = numpy.array(self.logprobs([self.bos] + ids)[0])
        for word, start, previous in words_with_context(text):
            token = bisect.bisect_right(ends, start)
            if token >= len(ids):
                return
            yield word, previous, (logprobs[token], start > 0 and text[start - 1] == " ")

    def distribution(self, state):
        logprobs, space = state
        entries = self.entries[space]
        scores = logprobs[entries.first] + entries.continuation
        words = numpy.logaddexp.reduceat(scores, entries.starts).astype(numpy.float64)
        words = numpy.exp(words - words.max())
        return words / words.sum()

###############################################################################

def offered_at(probabilities, word, vocab):
    """Letters typed before `word` shows in the bar, or None if it never does."""
    target = vocab.index.get(word)
    if target is None:
        return None
    score = probabilities[target]
    for typed in range(len(word)):
        if typed == 0:
            if numpy.count_nonzero(probabilities > score) < 3:
                return 0
            continue
        prefix = word[:typed]
        low, high = vocab.prefix_range(prefix)
        better = numpy.count_nonzero(probabilities[low:high] > score)
        literal = vocab.index.get(prefix)
        if literal is not None and probabilities[literal] > score:
            better -= 1
        if better < 2:
            return typed
    return None

###############################################################################

###############################################################################

class Tally:
    def __init__(self):
        self.words = 0
        self.keystrokes = 0
        self.saved = 0
        self.offered_by = [0, 0, 0]

    def add(self, word, typed):
        self.words += 1
        self.keystrokes += len(word) + 1
        if typed is None:
            return
        self.saved += len(word) - typed
        for limit in range(3):
            if typed <= limit:
                self.offered_by[limit] += 1

    def summary(self):
        return {
            "words": self.words,
            "keystroke_savings": self.saved / self.keystrokes,
            "next_word_top3": self.offered_by[0] / self.words,
            "offered_by_1_letter": self.offered_by[1] / self.words,
            "offered_by_2_letters": self.offered_by[2] / self.words,
        }

###############################################################################

def mixtures(name, first, second):
    return {f"{name}@{weight}": weight * first + (1 - weight) * second for weight in LAMBDAS}

###############################################################################

def evaluate(texts, lexicon, vocab, personal, generic, model, label):
    tallies = collections.defaultdict(Tally)
    for text in texts:
        positions = model.positions(text) if model else ((w, p, None) for w, _, p in words_with_context(text))
        for word, previous, state in positions:
            word = word.lower()
            groups = ["all", "outside_generic_lexicon" if word not in lexicon.rank else "in_generic_lexicon"]
            offered = {}
            personal_now = personal.distribution(previous)
            distributions = mixtures("personal_ngram+frequency", personal_now, generic.distribution(previous))
            if model:
                lm_now = model.distribution(state)
                distributions[label] = lm_now
                distributions.update(mixtures(f"personal_ngram+{label}", personal_now, lm_now))
            for name, probabilities in distributions.items():
                offered[name] = offered_at(probabilities, word, vocab)
            for name, typed in offered.items():
                for group in groups:
                    tallies[(name, group)].add(word, typed)
    return {f"{name}|{group}": tally.summary() for (name, group), tally in tallies.items()}

###############################################################################

def best_weights(dev):
    best = {}
    for key, summary in dev.items():
        name, group = key.split("|")
        if group != "all" or "@" not in name:
            continue
        family = name.split("@")[0]
        if family not in best or summary["keystroke_savings"] > dev[f"{best[family]}|all"]["keystroke_savings"]:
            best[family] = name
    return best

###############################################################################

def coverage(texts, lexicon, stats, vocab):
    words = [w.lower() for text in texts for w, _, _ in words_with_context(text)]
    outside = [w for w in words if w not in lexicon.rank]
    return {
        "test_words": len(words),
        "outside_generic_lexicon": len(outside) / len(words),
        "outside_generic_but_known_personally": sum(w in vocab.index for w in outside) / max(1, len(outside)),
        "contact_names_outside_generic_lexicon": sum(w in stats.contact_words for w in outside) / len(words),
        "personal_vocabulary_size": len(stats.vocabulary_words() - set(lexicon.rank)),
    }

###############################################################################

def write_finetune_data(directory, train, notes, dev):
    """Each example starts with the document marker the evaluation feeds before a message."""
    os.makedirs(directory, exist_ok=True)
    with open(f"{directory}/train.jsonl", "w") as out:
        for text in train + [chunk for note in notes for chunk in note.split("\n\n") if chunk.strip()]:
            out.write(json.dumps({"text": DOCUMENT_START + text}) + "\n")
    with open(f"{directory}/valid.jsonl", "w") as out:
        for text in dev[:500]:
            out.write(json.dumps({"text": DOCUMENT_START + text}) + "\n")

###############################################################################

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", default="ngram")
    parser.add_argument("--model")
    parser.add_argument("--adapter")
    parser.add_argument("--write-finetune-data")
    args = parser.parse_args()

    train, notes, contacts, dev, test = load_splits()
    if args.write_finetune_data:
        write_finetune_data(args.write_finetune_data, train, notes, dev)
        return
    lexicon = GenericLexicon()
    stats = PersonalStats(train + notes, contacts)
    vocab = Vocabulary(set(lexicon.rank) | stats.vocabulary_words())
    personal = PersonalNgram(stats, vocab)
    generic = GenericDistribution(lexicon, vocab)
    model = LanguageModel(args.model, args.adapter, vocab, lexicon, stats) if args.model else None

    dev_results = evaluate(dev, lexicon, vocab, personal, generic, model, args.label)
    test_results = evaluate(test, lexicon, vocab, personal, generic, model, args.label)
    chosen = best_weights(dev_results)
    report = {
        "coverage": coverage(test, lexicon, stats, vocab),
        "chosen_weights": chosen,
        "test": {k: v for k, v in test_results.items() if "@" not in k or k.split("|")[0] in chosen.values()},
    }
    with open(f"{extract_corpus.WORK_DIR}/results-{args.label}.json", "w") as out:
        json.dump(report, out, indent=2)
    print(json.dumps(report, indent=2))

###############################################################################

if __name__ == "__main__":
    main()
