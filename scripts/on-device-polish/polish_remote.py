# Polishes every input with a hosted model through the app's exact prompt.
# Each polish is appended to OUT.partial as it finishes, so a stopped run resumes
# without paying twice; a request that keeps failing is logged and skipped.
#
# Usage: python polish_remote.py INPUTS.jsonl OUT.jsonl [MODEL] [TEMPERATURE]

import concurrent.futures
import json
import pathlib
import sys
import threading
import time

import common


def main():
    source, out = sys.argv[1], sys.argv[2]
    model = sys.argv[3] if len(sys.argv) > 3 else common.REFERENCE_MODEL
    temperature = float(sys.argv[4]) if len(sys.argv) > 4 else 0.9
    rows = common.read_jsonl(source)
    partial = pathlib.Path(out + ".partial")
    done = {row["id"]: row for row in common.read_jsonl(partial)} if partial.exists() else {}
    todo = [row for row in rows if row["id"] not in done]
    print(f"{len(done)} already polished, {len(todo)} to go", flush=True)
    lock = threading.Lock()
    failures = 0

    def polish(row):
        nonlocal failures
        started = time.time()
        try:
            output = common.chat(model, common.messages(row["text"], common.instruction(row)), temperature=temperature, reasoning=False)
        except Exception as error:
            with lock:
                failures += 1
            print(f"  failed {row['id']}: {error}", flush=True)
            return
        result = {**row, "output": output, "model": model, "seconds": round(time.time() - started, 2)}
        with lock:
            with partial.open("a") as sink:
                sink.write(json.dumps(result, ensure_ascii=False) + "\n")
            done[row["id"]] = result
            if len(done) % 1000 == 0:
                print(f"  {len(done)}/{len(rows)} polished", flush=True)

    with concurrent.futures.ThreadPoolExecutor(24) as pool:
        list(pool.map(polish, todo))
    results = [done[row["id"]] for row in rows if row["id"] in done]
    common.write_jsonl(out, results)
    print(f"wrote {len(results)} polishes by {model} to {out} ({failures} failed)")


if __name__ == "__main__":
    main()
