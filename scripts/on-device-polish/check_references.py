# Fact-checks cloud polishes before they become training examples, so the small
# model doesn't learn to invent words or details. A cheap model reads each input
# and its polish and rejects polishes that add facts, change facts, keep
# nonsense words, or drop facts the style didn't ask to drop.
#
# Usage: python check_references.py REFERENCE.jsonl KEPT.jsonl
#   -> KEPT.jsonl (polishes that passed) and KEPT.rejected.jsonl (with reasons)

import concurrent.futures
import json
import pathlib
import re
import sys

import common

CHECKER = "anthropic/claude-haiku-5.5"
BATCH = 8

INSTRUCTIONS = """Each case below is rough text (speech-to-text or fast phone typing) and a rewrite of it in a requested style. Check only whether the rewrite is faithful; ignore tone and wording choices.

Reject a rewrite if any of these is true:
- invented: it adds a fact, detail, opinion, event or sentence the input doesn't support.
- changed: it changes a name, number, price, date, time, place or other specific (rounding $79.99 to $79 counts).
- nonsense: it contains a word or phrase that isn't real or makes no sense in context, such as a misheard word kept as is ("grocery homie") or a typo turned into the wrong word.
- dropped: it leaves out a name, number, date, request or other fact the reader needs, unless the style asked for a summary and the fact is minor.

Fixing an obvious misheard word or typo to what the speaker clearly meant is correct, not a change. Cutting filler, repetition and false starts is correct. When the speaker corrects themselves, keeping only the correction is correct."""


def case_block(index, row):
    return f"""<case id="{index}">
<style>{common.instruction(row)}</style>
<input>
{row["text"]}
</input>
<rewrite>
{row["output"]}
</rewrite>
</case>"""


def check_batch(rows):
    prompt = f"""{INSTRUCTIONS}

{chr(10).join(case_block(index, row) for index, row in enumerate(rows))}

Return only a JSON array with one object per case, in order: [{{"id": 0, "verdict": "keep" | "reject", "problem": "empty, or which rule and the words involved"}}, ...]."""
    # A reply that isn't the expected JSON is asked for again, twice.
    for attempt in range(3):
        reply = common.chat(CHECKER, [{"role": "user", "content": prompt}], temperature=0, max_tokens=4000)
        found = re.search(r"\[.*\]", reply, re.S)
        try:
            verdicts = json.loads(found.group(0)) if found else None
        except json.JSONDecodeError:
            verdicts = None
        if verdicts is not None and len(verdicts) == len(rows):
            break
        if attempt == 2:
            raise ValueError(f"unusable reply: {reply[:200]}")
    return [{"id": row["id"], "keep": verdict["verdict"] == "keep", "problem": verdict.get("problem", "")}
            for row, verdict in zip(rows, verdicts)]


def main():
    source, out = sys.argv[1], sys.argv[2]
    rows = common.read_jsonl(source)
    # Verdicts land in a side file as they finish, so a stopped run resumes where it was.
    partial = pathlib.Path(out + ".partial")
    done = {}
    if partial.exists():
        for line in partial.open():
            verdict = json.loads(line)
            done[verdict["id"]] = verdict
    todo = [row for row in rows if row["id"] not in done]
    batches = [todo[start:start + BATCH] for start in range(0, len(todo), BATCH)]
    print(f"{len(done)} checked, {len(todo)} to go with {CHECKER}", flush=True)
    failed = 0
    with concurrent.futures.ThreadPoolExecutor(48) as pool, partial.open("a") as sink:
        futures = [pool.submit(check_batch, batch) for batch in batches]
        for finished, future in enumerate(concurrent.futures.as_completed(futures), 1):
            try:
                verdicts = future.result()
            except Exception as error:
                failed += 1
                print(f"  batch failed: {error}", flush=True)
                continue
            for verdict in verdicts:
                done[verdict["id"]] = verdict
                sink.write(json.dumps(verdict) + "\n")
            sink.flush()
            if finished % 100 == 0:
                print(f"  {finished}/{len(batches)} batches", flush=True)
    if failed:
        sys.exit(f"{failed} batches failed; run again to finish them")
    kept = [row for row in rows if done[row["id"]]["keep"]]
    rejected = [{**row, "problem": done[row["id"]]["problem"]} for row in rows if not done[row["id"]]["keep"]]
    common.write_jsonl(out, kept)
    common.write_jsonl(out.removesuffix(".jsonl") + ".rejected.jsonl", rejected)
    print(f"kept {len(kept)} of {len(rows)}, rejected {len(rejected)}")


if __name__ == "__main__":
    main()
