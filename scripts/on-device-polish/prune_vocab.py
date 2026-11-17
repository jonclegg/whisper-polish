# Trims a byte-level BPE GGUF (Qwen3.5) to the tokens Latin-script text uses, so
# the keyboard holds a smaller tokenizer: llama.cpp keeps every token and merge
# in memory, and the full 248k-token list cost about 57 MB of the keyboard's
# 177 MB. A token stays when its text is only Latin letters, digits, punctuation
# and symbols (see KEPT_RANGES); the 256 single-byte tokens and every control
# token stay too, so any text still tokenizes. Every piece a merge needs to build
# a kept token is kept too (partial bytes of characters such as ’ included), so
# Latin text tokenizes as before; on 147 eval and dictation inputs every token
# matched. Other text (emoji, other scripts, combining accents) falls back to
# smaller pieces, down to single bytes, which the model saw less in training.
# The embedding rows of dropped tokens go with them.
#
# With --corpus, a token stays instead when tokenizing the given text (every string
# in the JSONL files, through the base model's tokenizer.json) produces it, along
# with every piece the merges need to build it, so that text tokenizes exactly as
# before while rarer words fall back to smaller pieces.
#
# Usage: python prune_vocab.py IN.gguf OUT.gguf [--corpus tokenizer.json TEXT.jsonl ...]

import argparse
import json

import numpy as np
from gguf import GGUFReader, GGUFValueType, GGUFWriter, Keys
from tokenizers import Tokenizer

# Basic Latin, Latin-1, Latin Extended-A/B, IPA-free: U+0000-024F; General
# Punctuation, superscripts and currency: U+2000-20CF; letterlike, arrows and
# math operators: U+2100-22FF.
KEPT_RANGES = [(0x0000, 0x024F), (0x2000, 0x20CF), (0x2100, 0x22FF)]


def bytes_to_unicode():
    """GPT-2's map from each byte to the printable character that stands for it in token text."""
    printable = list(range(ord("!"), ord("~") + 1)) + list(range(ord("¡"), ord("¬") + 1)) + list(range(ord("®"), ord("ÿ") + 1))
    characters = printable[:]
    extra = 0
    for byte in range(256):
        if byte not in printable:
            printable.append(byte)
            characters.append(256 + extra)
            extra += 1
    return dict(zip(printable, map(chr, characters)))


BYTE_OF = {character: byte for byte, character in bytes_to_unicode().items()}


def keeps(token, token_type):
    if token_type != 1:  # anything but a normal token: control, user-defined, byte
        return True
    raw = bytes(BYTE_OF[character] for character in token)
    if len(raw) == 1:
        return True
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return all(any(low <= ord(character) <= high for low, high in KEPT_RANGES) for character in text)


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def corpus_tokens(tokenizer_path, paths):
    tokenizer = Tokenizer.from_file(tokenizer_path)
    used = set()
    for path in paths:
        texts = [text for line in open(path) for text in strings(json.loads(line))]
        for start in range(0, len(texts), 2000):
            for encoding in tokenizer.encode_batch(texts[start:start + 2000], add_special_tokens=False):
                used.update(encoding.tokens)
    return used


def with_merge_parts(kept_text, merges):
    """Adds the pieces of every merge that builds a kept token, until nothing changes."""
    pairs = [merge.split(" ", 1) for merge in merges]
    while True:
        added = {part for left, right in pairs if left + right in kept_text for part in (left, right)} - kept_text
        if not added:
            return kept_text
        kept_text |= added


def field_value(field):
    kind = field.types[0]
    if kind == GGUFValueType.ARRAY:
        return [field.contents(index) for index in range(len(field.data))], kind, field.types[-1]
    return field.contents(), kind, None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("target")
    parser.add_argument("--corpus", nargs="+", metavar=("TOKENIZER_JSON", "TEXT_JSONL"))
    arguments = parser.parse_args()
    reader = GGUFReader(arguments.source)
    fields = {field.name: field for field in reader.fields.values()}
    tokens = field_value(fields[Keys.Tokenizer.LIST])[0]
    types = field_value(fields[Keys.Tokenizer.TOKEN_TYPE])[0]
    merges = field_value(fields[Keys.Tokenizer.MERGES])[0]
    if arguments.corpus:
        used = corpus_tokens(arguments.corpus[0], arguments.corpus[1:])
        base = {token for token, kind in zip(tokens, types) if kind != 1 or len(token) == 1 and token in BYTE_OF}
        kept_text = with_merge_parts(used | base, merges)
        kept = [index for index, token in enumerate(tokens) if token in kept_text]
        print(f"corpus uses {len(used)} tokens")
    else:
        # Multi-byte characters such as ’ are built through partial-byte pieces, which keep those too.
        kept_text = with_merge_parts({token for token, kind in zip(tokens, types) if keeps(token, kind)}, merges)
        kept = [index for index, token in enumerate(tokens) if token in kept_text]
    new_id = {old: new for new, old in enumerate(kept)}
    kept_merges = []
    for merge in merges:
        left, right = merge.split(" ", 1)
        if left in kept_text and right in kept_text and left + right in kept_text:
            kept_merges.append(merge)
    print(f"tokens {len(tokens)} -> {len(kept)}, merges {len(merges)} -> {len(kept_merges)}")

    architecture = fields[Keys.General.ARCHITECTURE].contents()
    writer = GGUFWriter(arguments.target, architecture)
    token_id_keys = {Keys.Tokenizer.BOS_ID, Keys.Tokenizer.EOS_ID, Keys.Tokenizer.EOT_ID, Keys.Tokenizer.EOM_ID,
                     Keys.Tokenizer.PAD_ID, Keys.Tokenizer.UNK_ID, Keys.Tokenizer.SEP_ID, Keys.Tokenizer.MASK_ID,
                     Keys.Tokenizer.FIM_PRE_ID, Keys.Tokenizer.FIM_SUF_ID, Keys.Tokenizer.FIM_MID_ID,
                     Keys.Tokenizer.FIM_PAD_ID, Keys.Tokenizer.FIM_REP_ID, Keys.Tokenizer.FIM_SEP_ID}
    replaced = {
        Keys.Tokenizer.LIST: [tokens[index] for index in kept],
        Keys.Tokenizer.TOKEN_TYPE: [types[index] for index in kept],
        Keys.Tokenizer.MERGES: kept_merges,
    }
    for name, field in fields.items():
        if name.startswith("GGUF.") or name == Keys.General.ARCHITECTURE:
            continue
        value, kind, sub_kind = field_value(field)
        if name in replaced:
            value = replaced[name]
        elif name in token_id_keys:
            value = new_id[value]
        elif name == Keys.Tokenizer.SCORES:
            value = [value[index] for index in kept]
        elif name.endswith(".vocab_size"):
            value = len(kept)
        writer.add_key_value(name, value, kind, sub_type=sub_kind)

    rows = np.array(kept)
    vocabulary = len(tokens)
    tensors = []
    for tensor in reader.tensors:
        data = tensor.data
        # The reader gives quantized tensors as rows of bytes, which the writer takes back as is.
        if len(tensor.shape) == 2 and int(tensor.shape[1]) == vocabulary:
            data = data.reshape(vocabulary, -1)[rows]
            print(f"sliced {tensor.name}: {vocabulary} -> {len(kept)} rows")
        tensors.append((tensor, np.ascontiguousarray(data)))
    for tensor, data in tensors:
        writer.add_tensor_info(tensor.name, data.shape, data.dtype, data.nbytes, tensor.tensor_type)
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_ti_data_to_file()
    for _, data in tensors:
        writer.write_tensor_data(data)
    writer.close()


if __name__ == "__main__":
    main()
