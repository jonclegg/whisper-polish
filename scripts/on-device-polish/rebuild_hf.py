# Rebuilds Hugging Face weights from a tuned GGUF, for when the training box that
# held the original weights is gone. llama.cpp's converter reorders, splits and
# offsets tensors on the way to GGUF; rather than invert that by hand, this runs
# the converter on stand-in weights whose values are their own positions, which
# records where every number lands, then puts the tuned GGUF's numbers back.
#
# Usage (llama.cpp's gguf-py on PYTHONPATH):
#   python rebuild_hf.py BASE_HF_DIR LLAMA_CPP_DIR TUNED.gguf OUT_DIR

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

import gguf
import numpy
import torch
from safetensors.torch import load_file, save_file

SPLIT = 1 << 22  # positions go through float32 in two exact halves


def convert(base, llama_cpp, tensors, work, label):
    folder = work / label
    folder.mkdir()
    for item in base.iterdir():
        if item.is_file() and not item.name.endswith(".safetensors") and item.name != "model.safetensors.index.json":
            shutil.copy(item, folder / item.name)
    save_file(tensors, folder / "model.safetensors")
    out = work / f"{label}.gguf"
    subprocess.run([sys.executable, str(llama_cpp / "convert_hf_to_gguf.py"), str(folder), "--outtype", "f32",
                    "--outfile", str(out)], check=True, capture_output=True)
    shutil.rmtree(folder)
    return {tensor.name: numpy.array(tensor.data, dtype=numpy.float64) for tensor in gguf.GGUFReader(out).tensors}


def main():
    base, llama_cpp, tuned_path, out = (pathlib.Path(argument) for argument in sys.argv[1:5])
    original = {}
    for file in base.glob("*.safetensors"):
        original.update(load_file(file))
    names = sorted(original)
    shapes = {name: original[name].shape for name in names}

    def stand_in(values):
        return {name: values(index, name).reshape(shapes[name]).to(torch.float32).contiguous()
                for index, name in enumerate(names)}

    def positions(name):
        return torch.arange(original[name].numel(), dtype=torch.int64)

    with tempfile.TemporaryDirectory() as temporary:
        work = pathlib.Path(temporary)
        zero = convert(base, llama_cpp, stand_in(lambda index, name: torch.zeros(original[name].numel())), work, "zero")
        low = convert(base, llama_cpp, stand_in(lambda index, name: positions(name) % SPLIT), work, "low")
        high = convert(base, llama_cpp, stand_in(lambda index, name: positions(name) // SPLIT), work, "high")
        which = convert(base, llama_cpp, stand_in(lambda index, name: torch.full((original[name].numel(),), index)), work, "which")

    tuned = {tensor.name: tensor for tensor in gguf.GGUFReader(tuned_path).tensors}
    rebuilt = {name: original[name].to(torch.float32).clone().reshape(-1) for name in names}
    filled = {name: numpy.zeros(original[name].numel(), dtype=bool) for name in names}
    # The base also carries a next-token-prediction head the tuned model was saved without.
    skipped = sorted(set(zero) - set(tuned))
    print(f"{len(skipped)} base tensors missing from the tuned GGUF, kept from the base: {skipped[:3]}")
    for gguf_name, offset in zero.items():
        if gguf_name not in tuned:
            continue
        source = tuned[gguf_name]
        values = gguf.quants.dequantize(source.data, source.tensor_type).astype(numpy.float64).reshape(-1)
        offset = offset.reshape(-1)
        if numpy.all(offset == -1):
            # A_log is stored as -exp(A_log): undo it, and read positions through it.
            position = numpy.rint(numpy.log(-low[gguf_name].reshape(-1))).astype(numpy.int64)
            layer = int(gguf_name.split(".")[1])
            owner = [name for name in names if name.endswith(f"layers.{layer}.linear_attn.A_log")]
            assert len(owner) == 1, gguf_name
            values = numpy.log(-values)
            index = numpy.full(position.shape, names.index(owner[0]))
        else:
            assert numpy.all((offset == 0) | (offset == 1)), gguf_name
            position = (numpy.rint(low[gguf_name].reshape(-1) - offset).astype(numpy.int64)
                        + SPLIT * numpy.rint(high[gguf_name].reshape(-1) - offset).astype(numpy.int64))
            index = numpy.rint(which[gguf_name].reshape(-1) - offset).astype(numpy.int64)
            values = values - offset
        assert values.size == position.size, (gguf_name, values.size, position.size)
        for owner_index in numpy.unique(index):
            name = names[owner_index]
            chosen = index == owner_index
            rebuilt[name][torch.from_numpy(position[chosen])] = torch.from_numpy(values[chosen]).to(torch.float32)
            filled[name][position[chosen]] = True

    untouched = [name for name in names if not filled[name].any()]
    partial = [name for name in names if filled[name].any() and not filled[name].all()]
    assert not partial, partial[:5]
    print(f"rebuilt {len(names) - len(untouched)} tensors; {len(untouched)} kept from the base "
          f"(e.g. {untouched[:3]})")
    out.mkdir(parents=True, exist_ok=True)
    for item in base.iterdir():
        if item.is_file() and not item.name.endswith(".safetensors") and item.name != "model.safetensors.index.json":
            shutil.copy(item, out / item.name)
    save_file({name: rebuilt[name].reshape(shapes[name]).to(original[name].dtype).contiguous() for name in names},
              out / "model.safetensors")
    json.dump({"source": str(tuned_path)}, open(out / "rebuilt-from.json", "w"))


if __name__ == "__main__":
    main()
