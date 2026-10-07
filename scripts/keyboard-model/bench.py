# Scores word predictors on your messages with the evaluation's own metrics:
# keystroke savings and how often the next word is in the bar before typing.
# Personal learning only sees text from before the dev block, in windows that
# stand in for a keyboard used for a day, a month, or a year. Tunes on the dev
# block; the test block is only for the final check.
#
# Usage: python bench.py WORK_DIR [--split dev|test] [--limit MESSAGES] [--neural NAME,...] [--kneser-ney 4]

import argparse
import collections
import json
import os
import pickle
import sys

import numpy

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "../personal-prediction"))
import evaluate_prediction as evaluation  # noqa: E402

import model as word_model  # noqa: E402
import ngram  # noqa: E402

DAY = 86400
STAGES = {"day-one": 0, "one-month": 30, "one-year": 365, "all-history": None}

###############################################################################

def load_splits():
    """Like the evaluation's splits, but keeping dates so personal text can be windowed."""
    with open(evaluation.extract_corpus.CORPUS) as source:
        corpus = json.load(source)
    messages = sorted(corpus["messages"], key=lambda m: m["date"])
    test = messages[-evaluation.SPLIT_MESSAGES:]
    dev = messages[-2 * evaluation.SPLIT_MESSAGES:-evaluation.SPLIT_MESSAGES]
    train = messages[:-2 * evaluation.SPLIT_MESSAGES]
    cutoff = dev[0]["date"]
    notes = [note for note in corpus["notes"] if note["date"] < cutoff]
    texts = lambda items: [evaluation.normalized(item["text"]) for item in items]
    return train, notes, corpus["contacts"], cutoff, texts(dev), texts(test)

###############################################################################

class Stage:
    """What the keyboard knows after `days` of use: your text from then, its vocabulary, its models."""

    def __init__(self, name, days, train, notes, contacts, cutoff, lexicon, scored, online):
        start = cutoff - days * DAY if days is not None else float("-inf")
        texts = [evaluation.normalized(item["text"]) for item in train + notes if item["date"] >= start]
        self.name = name
        self.words = sum(len(evaluation.WORD.findall(text)) for text in texts)
        self.stats = evaluation.PersonalStats(texts, contacts)
        self.online = online
        if online:
            # Words typed during scoring can be learned, so they need a place in the vocabulary.
            later = {w.lower() for text in scored for w in evaluation.WORD.findall(text)}
            self.vocab = evaluation.Vocabulary(set(lexicon.rank) | self.stats.vocabulary_words() | later)
            self.known = numpy.zeros(len(self.vocab.words), dtype=bool)
            for word in set(lexicon.rank) | self.stats.contact_words:
                self.known[self.vocab.index[word]] = True
            self.personal = OnlinePersonal(self.vocab, texts, contacts, self.known)
        else:
            self.vocab = evaluation.Vocabulary(set(lexicon.rank) | self.stats.vocabulary_words())
            self.personal = evaluation.PersonalNgram(self.stats, self.vocab) if texts else None

###############################################################################

class OnlinePersonal:
    """Your own trigrams, absolute discounting over a Kneser-Ney unigram like the evaluation's
    personal model, but learning each message as soon as it's sent, the way the keyboard would."""

    def __init__(self, vocab, texts, contacts, known):
        self.index = vocab.index
        self.size = len(vocab.words)
        # Words become suggestions once typed twice, like the evaluation's personal vocabulary.
        self.known = known
        self.typed = collections.Counter()
        self.continuation = numpy.zeros(self.size)
        self.predecessors = collections.defaultdict(set)
        self.bigrams = collections.defaultdict(collections.Counter)
        self.trigrams = collections.defaultdict(collections.Counter)
        for name in contacts:
            if evaluation.WORD.fullmatch(name):
                self.see(evaluation.SENTENCE_START, name.lower())
        for text in texts:
            self.add(text)

    def see(self, previous, word):
        if word in self.index and previous not in self.predecessors[word]:
            self.predecessors[word].add(previous)
            self.continuation[self.index[word]] += 1

    def add(self, text):
        for sentence in evaluation.sentences(text):
            tokens = [evaluation.SENTENCE_START] + sentence
            for i in range(1, len(tokens)):
                self.typed[tokens[i]] += 1
                if self.typed[tokens[i]] >= evaluation.MIN_PERSONAL_COUNT and tokens[i] in self.index:
                    self.known[self.index[tokens[i]]] = True
                self.see(tokens[i - 1], tokens[i])
                self.bigrams[tokens[i - 1]][tokens[i]] += 1
                if i >= 2:
                    self.trigrams[f"{tokens[i - 2]} {tokens[i - 1]}"][tokens[i]] += 1

    def interpolate(self, counter, lower):
        pairs = [(self.index[w], c) for w, c in counter.items() if w in self.index]
        if not pairs:
            return lower
        indexes, counts = zip(*pairs)
        counts = numpy.array(counts, dtype=numpy.float64)
        total = counts.sum()
        result = lower * (evaluation.DISCOUNT * len(indexes) / total)
        result[list(indexes)] += numpy.maximum(counts - evaluation.DISCOUNT, 0) / total
        return result

    def distribution(self, previous):
        total = self.continuation.sum()
        result = numpy.full(self.size, 1 / self.size)
        if total:
            result = (1 - evaluation.UNIFORM_SHARE) * self.continuation / total + evaluation.UNIFORM_SHARE / self.size
        context = [evaluation.SENTENCE_START] + previous[-2:]
        if context[-1] in self.bigrams:
            result = self.interpolate(self.bigrams[context[-1]], result)
        if len(context) >= 2 and " ".join(context[-2:]) in self.trigrams:
            result = self.interpolate(self.trigrams[" ".join(context[-2:])], result)
        return result

###############################################################################

class Mapping:
    """From a base model's ids to a stage's vocabulary; words the base doesn't know share its unknown-word odds."""

    def __init__(self, base_words, vocab):
        self.index = {word: n for n, word in enumerate(base_words)}
        self.ids = numpy.array([self.index.get(word, ngram.BOUNDARY) for word in vocab.words])
        self.outside = self.ids == ngram.BOUNDARY

    def __call__(self, probabilities):
        rows = probabilities[..., self.ids]
        rows[..., self.outside] = probabilities[..., 1:2] / max(1, self.outside.sum())
        return rows / rows.sum(axis=-1, keepdims=True)

###############################################################################

def neural_rows(network, mapping, text):
    """One distribution per word of `text`, each given everything before it in the message."""
    inputs = [ngram.BOUNDARY]
    positions = []
    for match in evaluation.TOKEN.finditer(text):
        token = match.group()
        if not token[0].isalpha():
            if inputs[-1] != ngram.BOUNDARY:
                inputs.append(ngram.BOUNDARY)
            continue
        positions.append(len(inputs) - 1)
        inputs.append(mapping.index.get(token.lower(), 1))
    if not positions:
        return []
    return mapping(word_model.softmax(network.logits(numpy.array(inputs))[positions]))

###############################################################################

def load_kneser_ney(work, order):
    name = f"{work}/data/kn{order}-full.pkl"
    if os.path.exists(name):
        with open(name, "rb") as source:
            return pickle.load(source)
    tokens = numpy.load(f"{work}/data/base-tokens.npy")
    with open(f"{work}/data/base-vocabulary.txt") as source:
        size = len(source.read().split("\n")) - 1
    model = ngram.KneserNey(tokens, order, size)
    with open(name, "wb") as out:
        pickle.dump(model, out)
    return model

###############################################################################

def evaluate(texts, stage, bases, weights):
    """`bases` map a name to ("message", text -> rows) or ("previous", previous words -> distribution)."""
    tallies = collections.defaultdict(evaluation.Tally)
    for text in texts:
        per_message = {name: base(text) for name, (kind, base) in bases.items() if kind == "message"}
        for position, (word, _, previous) in enumerate(evaluation.words_with_context(text)):
            word = word.lower()
            distributions = {name: rows[position] for name, rows in per_message.items()}
            distributions.update({name: base(previous) for name, (kind, base) in bases.items() if kind == "previous"})
            offered = {}
            if stage.online:
                # Words not yet learned can't be suggested.
                distributions = {name: probabilities * stage.known for name, probabilities in distributions.items()}
            for name, probabilities in distributions.items():
                offered[name] = evaluation.offered_at(probabilities, word, stage.vocab)
            if stage.personal:
                personal = stage.personal.distribution(previous)
                if stage.online:
                    personal = personal * stage.known
                for name, probabilities in distributions.items():
                    for weight in weights:
                        offered[f"personal+{name}@{weight}"] = evaluation.offered_at(weight * personal + (1 - weight) * probabilities, word, stage.vocab)
                if stage.online:
                    # Your own text earns its weight as the keyboard learns more of it.
                    learned = sum(stage.personal.typed.values())
                    for name, probabilities in distributions.items():
                        for ramp in (2000, 10000):
                            weight = 0.45 * learned / (learned + ramp)
                            offered[f"personal+{name}~ramp{ramp}"] = evaluation.offered_at(weight * personal + (1 - weight) * probabilities, word, stage.vocab)
            for name, typed in offered.items():
                tallies[name].add(word, typed)
        if stage.online:
            stage.personal.add(text)
    return {name: tally.summary() for name, tally in tallies.items()}

###############################################################################

def report(stage, results):
    print(f"== {stage.name} ({stage.words} personal words)")
    for name, summary in sorted(results.items(), key=lambda item: -item[1]["keystroke_savings"])[:8]:
        print(f"  {name:36} words {summary['words']}  savings {summary['keystroke_savings']:.3f}  bar {summary['next_word_top3']:.3f}"
              f"  by1 {summary['offered_by_1_letter']:.3f}")
    sys.stdout.flush()

###############################################################################

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("work")
    parser.add_argument("--split", default="dev")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--stages", default=",".join(STAGES))
    parser.add_argument("--kneser-ney", type=int, default=0, help="order of the public n-gram to include, 0 for none")
    parser.add_argument("--neural", default="", help="comma-separated model names under WORK_DIR/models")
    parser.add_argument("--weights", default="0.2,0.35,0.5,0.65,0.8")
    parser.add_argument("--online", action="store_true", help="learn each scored message after scoring it")
    args = parser.parse_args()

    train, notes, contacts, cutoff, dev, test = load_splits()
    texts = dev if args.split == "dev" else test
    if args.limit:
        texts = texts[:args.limit]
    lexicon = evaluation.GenericLexicon()
    with open(f"{args.work}/data/base-vocabulary.txt") as source:
        base_words = source.read().split("\n")[:-1]
    kneser_ney = load_kneser_ney(args.work, args.kneser_ney) if args.kneser_ney else None
    networks = {name: word_model.WordModel(f"{args.work}/models/{name}") for name in filter(None, args.neural.split(","))}
    weights = [float(w) for w in args.weights.split(",")]
    for name in args.stages.split(","):
        stage = Stage(name, STAGES[name], train, notes, contacts, cutoff, lexicon, texts, args.online)
        mapping = Mapping(base_words, stage.vocab)
        bases = {}
        if kneser_ney:
            bases[f"kn{args.kneser_ney}"] = ("previous", lambda previous, m=mapping: m(kneser_ney.distribution(
                ([ngram.BOUNDARY] + [m.index.get(w, 1) for w in previous])[-(kneser_ney.order - 1):])))
        for model_name, network in networks.items():
            bases[model_name] = ("message", lambda text, n=network, m=mapping: neural_rows(n, m, text))
        report(stage, evaluate(texts, stage, bases, weights))

###############################################################################

if __name__ == "__main__":
    main()
