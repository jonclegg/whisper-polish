# Packs a trained word LSTM into the file the keyboard memory-maps, plus a
# fixture of numpy predictions the Swift tests check it against.
#
# Usage: python export.py MODEL_DIR VOCABULARY OUTPUT.bin [FIXTURE.json]
#
# Layout, little-endian, every array starting on a 16-byte boundary:
#   "WPWM", version, vocabulary size, embedding size, hidden size, vocabulary bytes (UInt32 each)
#   vocabulary: UTF-8 words joined by "\n", id order (0 is the sentence boundary, 1 an unknown word)
#   Float16: embedding [vocabulary x embedding], input weights [4 hidden x embedding],
#            hidden weights [4 hidden x hidden], projection [embedding x hidden]
#   Float32: gate bias [4 hidden], projection bias [embedding], output bias [vocabulary]
# Gates are in PyTorch's order: input, forget, cell, output.

import json
import struct
import sys

import numpy

import model as word_model

MAGIC = b"WPWM"
VERSION = 1

###############################################################################

def padded(blob):
    return blob + b"\0" * (-len(blob) % 16)

###############################################################################

def export(directory, vocabulary_path, output):
    network = word_model.WordModel(directory)
    if network.config["layers"] != 1:
        raise ValueError("the keyboard runs single-layer models")
    with open(vocabulary_path) as source:
        words = source.read().split("\n")[:-1]
    input_weights, hidden_weights, gate_bias = network.layers[0]
    vocabulary = "\n".join(words).encode()
    header = MAGIC + struct.pack("<5I", VERSION, len(words), network.embedding.shape[1], hidden_weights.shape[1], len(vocabulary))
    blob = padded(header) + padded(vocabulary)
    for array in (network.embedding, input_weights, hidden_weights, network.projection):
        blob += padded(array.astype("<f2").tobytes())
    for array in (gate_bias, network.projection_bias, network.bias):
        blob += padded(array.astype("<f4").tobytes())
    with open(output, "wb") as out:
        out.write(blob)
    return network, words

###############################################################################

def fixture(network, words, path):
    """Top predictions after a few contexts, from the float16 weights the keyboard uses."""
    for name in ("embedding", "projection"):
        setattr(network, name, getattr(network, name).astype(numpy.float16).astype(numpy.float32))
    network.layers = [tuple(w.astype(numpy.float16).astype(numpy.float32) if n < 2 else w for n, w in enumerate(layer)) for layer in network.layers]
    index = {word: n for n, word in enumerate(words)}
    cases = []
    for text in ("", "how are", "i will be there in", "thank you so"):
        ids = [0] + [index.get(word, 1) for word in text.split()]
        logits = network.logits(numpy.array(ids))[-1]
        top = numpy.argsort(-logits)[:5]
        cases.append({"ids": ids, "top": top.tolist(), "logits": logits[top].tolist()})
    with open(path, "w") as out:
        json.dump(cases, out, indent=1)

###############################################################################

if __name__ == "__main__":
    network, words = export(sys.argv[1], sys.argv[2], sys.argv[3])
    if len(sys.argv) > 4:
        fixture(network, words, sys.argv[4])
