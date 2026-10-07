# Runs a trained word LSTM with numpy alone: the reference the keyboard's Swift
# implementation is checked against, and what scores models on the Mac.

import json

import numpy

###############################################################################

class WordModel:
    def __init__(self, directory):
        with open(f"{directory}/config.json") as source:
            self.config = json.load(source)
        weights = numpy.load(f"{directory}/weights.npz")
        self.embedding = weights["embedding.weight"]
        self.layers = []
        for n in range(self.config["layers"]):
            self.layers.append((
                weights[f"lstm.weight_ih_l{n}"],
                weights[f"lstm.weight_hh_l{n}"],
                weights[f"lstm.bias_ih_l{n}"] + weights[f"lstm.bias_hh_l{n}"],
            ))
        self.projection = weights["projection.weight"]
        self.projection_bias = weights["projection.bias"]
        self.bias = weights["bias"]

    def logits(self, ids):
        """Next-id logits after each id in `ids`, one row per position."""
        x = self.embedding[ids]
        for input_weights, hidden_weights, bias in self.layers:
            size = hidden_weights.shape[1]
            hidden = numpy.zeros(size, dtype=numpy.float32)
            cell = numpy.zeros(size, dtype=numpy.float32)
            projected = x @ input_weights.T + bias
            outputs = numpy.empty((len(ids), size), dtype=numpy.float32)
            for t in range(len(ids)):
                gates = projected[t] + hidden_weights @ hidden
                i, f, g, o = numpy.split(gates, 4)
                cell = sigmoid(f) * cell + sigmoid(i) * numpy.tanh(g)
                hidden = sigmoid(o) * numpy.tanh(cell)
                outputs[t] = hidden
            x = outputs
        return (x @ self.projection.T + self.projection_bias) @ self.embedding.T + self.bias

###############################################################################

def sigmoid(x):
    return 1 / (1 + numpy.exp(-x))

###############################################################################

def softmax(logits):
    shifted = numpy.exp(logits - logits.max(axis=-1, keepdims=True))
    return shifted / shifted.sum(axis=-1, keepdims=True)
