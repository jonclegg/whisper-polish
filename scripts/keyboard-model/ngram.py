# Interpolated Kneser-Ney word n-grams over token ids, built with numpy so
# 170M tokens fit in memory. Id 0 is the sentence boundary, which only ever
# starts a context; 1 is a word outside the list.

import numpy

BOUNDARY = 0
BITS = 16
DISCOUNT = 0.75

###############################################################################

def pack(columns):
    key = numpy.zeros(len(columns[0]), dtype=numpy.uint64)
    for column in columns:
        key = (key << numpy.uint64(BITS)) | column.astype(numpy.uint64)
    return key

###############################################################################

def windows(tokens, order):
    """Every n-gram of `order` tokens whose boundary, if any, comes first."""
    count = len(tokens) - order + 1
    columns = [tokens[i:i + count] for i in range(order)]
    valid = numpy.ones(count, dtype=bool)
    for column in columns[1:]:
        valid &= column != BOUNDARY
    return [column[valid] for column in columns]

###############################################################################

class Table:
    """Counts for one order: contexts sorted by key, each with a run of (word, count)."""

    def __init__(self, contexts, words, counts):
        order = numpy.lexsort((words, contexts))
        contexts, words, counts = contexts[order], words[order], counts[order]
        self.keys, starts = numpy.unique(contexts, return_index=True)
        self.starts = numpy.append(starts, len(contexts)).astype(numpy.int64)
        self.words = words.astype(numpy.int32)
        self.counts = counts.astype(numpy.float64)
        self.totals = numpy.add.reduceat(self.counts, starts) if len(starts) else numpy.zeros(0)
        self.types = numpy.diff(self.starts).astype(numpy.float64)

    def lookup(self, key):
        n = numpy.searchsorted(self.keys, key)
        if n >= len(self.keys) or self.keys[n] != key:
            return None
        start, end = self.starts[n], self.starts[n + 1]
        return self.words[start:end], self.counts[start:end], self.totals[n], self.types[n]

    def pruned(self, minimum):
        keep = self.counts >= minimum
        contexts = numpy.repeat(self.keys, numpy.diff(self.starts))
        return Table(contexts[keep], self.words[keep], self.counts[keep])

###############################################################################

class KneserNey:
    """Highest order uses counts; lower orders use how many contexts each word follows."""

    def __init__(self, tokens, order, vocabulary_size, minimum_counts=None):
        self.order = order
        self.size = vocabulary_size
        self.tables = {}
        higher = None
        for n in range(order, 0, -1):
            keys, counts = numpy.unique(pack(windows(tokens, n)), return_counts=True)
            if higher is not None:
                # How many different words come right before each n-gram. N-grams
                # that start a sentence have none, so they keep their counts.
                suffixes, extensions = numpy.unique(higher & numpy.uint64((1 << (BITS * n)) - 1), return_counts=True)
                positions = numpy.minimum(numpy.searchsorted(suffixes, keys), len(suffixes) - 1)
                matched = suffixes[positions] == keys
                counts = numpy.where(matched, extensions[positions], counts)
            higher = keys
            if n == 1:
                unigram = numpy.zeros(vocabulary_size)
                unigram[keys.astype(numpy.int64)] = counts
                unigram[BOUNDARY] = 0
                self.unigram = (unigram + 0.01) / (unigram + 0.01).sum()
                break
            table = Table(keys >> numpy.uint64(BITS), keys & numpy.uint64((1 << BITS) - 1), counts)
            if minimum_counts and n in minimum_counts:
                table = table.pruned(minimum_counts[n])
            self.tables[n] = table

    def distribution(self, context):
        """P(word | last order-1 ids of `context`) over every id."""
        result = self.unigram.copy()
        for n in range(2, self.order + 1):
            if len(context) < n - 1:
                break
            entry = self.tables[n].lookup(pack([numpy.array([c]) for c in context[-(n - 1):]])[0])
            if entry is None:
                continue
            words, counts, total, types = entry
            result *= DISCOUNT * types / total
            result[words] += numpy.maximum(counts - DISCOUNT, 0) / total
        return result
