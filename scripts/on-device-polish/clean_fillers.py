# Cuts filler hedges and intensifiers ("really", "actually", "just", ...) and
# filler "like" / "you know" from training answers, so the model learns to cut
# them too. Round three's answers kept about three in four of them, and the
# model copied that.
#
# Claude (through the `claude -p` CLI, on Jon's subscription) decides which uses
# carry meaning. A word-level diff then rejects any edit that does more than
# delete those words, so the answers' facts can't change; a rejected edit keeps
# the original answer. Rows with none of the words are copied as they are.
#
# Usage: python clean_fillers.py IN.jsonl OUT.jsonl FIELD [FIELD ...]
#        python clean_fillers.py data/sft-r3.jsonl data/sft-r4.jsonl output
#        python clean_fillers.py data/r3/dpo-pairs.jsonl data/r4/dpo-pairs.jsonl chosen rejected

import concurrent.futures
import difflib
import json
import re
import subprocess
import sys

import common

FILLERS = ["really", "actually", "basically", "literally", "honestly", "totally", "just", "kind of", "sort of", "pretty much", "like", "you know"]
FILLER_PATTERN = re.compile(r"\b(" + "|".join(FILLERS) + r")\b", re.IGNORECASE)
FILLER_WORDS = {word for phrase in FILLERS for word in phrase.split()}
BATCH = 20
WORKERS = 8
MODEL = "sonnet"

PROMPT = """Each text below is a finished, polished message. Delete the filler hedges and intensifiers from it: really, actually, basically, literally, honestly, totally, just, kind of, sort of, pretty much, and "like" and "you know" used as filler ("for like four hours").

Keep a word only when deleting it would change what the message says:
- "just" meaning only or a moment ago ("just two left", "I just got here")
- "kind of" / "sort of" meaning type of ("what kind of car")
- "pretty much" meaning almost ("pretty much done")
- "like" as a verb or meaning similar to ("I like it", "looks like rain")
- "not really" and similar, where it softens a negative ("I don't really mind")
- a word that is itself the topic, or inside a quote, name or title

Change nothing else. You may fix the capitalization or punctuation a deletion leaves behind, or "a"/"an" next to it. Do not rephrase, reorder or fix anything else, even if it looks wrong.

{texts}

Return only a JSON array with one object per text, in order: [{{"id": 0, "text": "..."}}, ...]. No other text."""


def words(text):
    return [re.sub(r"[^\w']", "", token).lower() for token in text.split() if re.sub(r"[^\w']", "", token)]


def only_deletes_fillers(before, after):
    before_words, after_words = words(before), words(after)
    for tag, start, end, new_start, new_end in difflib.SequenceMatcher(None, before_words, after_words, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        if tag == "replace" and {*before_words[start:end], *after_words[new_start:new_end]} <= {"a", "an"}:
            continue
        if tag == "delete" and set(before_words[start:end]) <= FILLER_WORDS:
            continue
        return False
    return True


def clean_batch(texts):
    blocks = "\n\n".join(f'<text id="{index}">\n{text}\n</text>' for index, text in enumerate(texts))
    prompt = PROMPT.format(texts=blocks)
    for attempt in range(3):
        completed = subprocess.run(["claude", "-p", "--model", MODEL, "--output-format", "json", "--max-turns", "1"],
                                   input=prompt, capture_output=True, text=True, timeout=900, cwd=common.DATA)
        try:
            reply = json.loads(completed.stdout)["result"]
            cleaned = json.loads(re.search(r"\[.*\]", reply, re.S).group(0))
            if len(cleaned) == len(texts) and all(isinstance(item["text"], str) for item in cleaned):
                return [item["text"].strip() for item in cleaned]
        except (json.JSONDecodeError, AttributeError, KeyError, TypeError):
            pass
    raise RuntimeError(f"cleaning failed: {completed.stdout[-500:]} {completed.stderr[-500:]}")


def main():
    source, out, fields = sys.argv[1], sys.argv[2], sys.argv[3:]
    rows = common.read_jsonl(source)
    partial = f"{out}.partial"
    done = {}
    try:
        done = {entry["key"]: entry["text"] for entry in common.read_jsonl(partial)}
    except FileNotFoundError:
        pass
    todo = sorted({(index, field) for index, row in enumerate(rows) for field in fields
                   if FILLER_PATTERN.search(row[field]) and f"{index}:{field}" not in done})
    print(f"{len(todo)} answers to clean ({len(done)} already done), {len(todo) // BATCH + 1} calls")
    batches = [todo[start:start + BATCH] for start in range(0, len(todo), BATCH)]
    with open(partial, "a") as log, concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
        futures = {pool.submit(clean_batch, [rows[index][field] for index, field in batch]): batch for batch in batches}
        for count, future in enumerate(concurrent.futures.as_completed(futures), 1):
            for (index, field), text in zip(futures[future], future.result()):
                done[f"{index}:{field}"] = text
                log.write(json.dumps({"key": f"{index}:{field}", "text": text}, ensure_ascii=False) + "\n")
            log.flush()
            if count % 25 == 0:
                print(f"  {count} of {len(batches)} calls", flush=True)

    changed = rejected = 0
    for index, row in enumerate(rows):
        for field in fields:
            cleaned = done.get(f"{index}:{field}")
            if cleaned is None or cleaned == row[field]:
                continue
            if only_deletes_fillers(row[field], cleaned):
                row[field] = cleaned
                changed += 1
            else:
                rejected += 1
    common.write_jsonl(out, rows)
    before = sum(len(FILLER_PATTERN.findall(row[field])) for row in common.read_jsonl(source) for field in fields)
    after = sum(len(FILLER_PATTERN.findall(row[field])) for row in rows for field in fields)
    print(f"wrote {len(rows)} rows to {out}: {changed} answers changed, {rejected} edits rejected by the diff check; "
          f"filler words {before} -> {after}")


if __name__ == "__main__":
    main()
