# Measures how often the cheap fact checker is right: Claude on Jon's
# subscription (`claude -p`) checks the same cases blind, with the same rules,
# and the two sets of verdicts are compared.
#
# Usage: python audit_checker.py KEPT.jsonl REJECTED.jsonl COUNT_EACH OUT.jsonl

import concurrent.futures
import json
import random
import re
import subprocess
import sys

import check_references
import common

BATCH = 10


def audit(rows):
    prompt = f"""{check_references.INSTRUCTIONS}

{chr(10).join(check_references.case_block(index, row) for index, row in enumerate(rows))}

Return only a JSON array with one object per case, in order: [{{"id": 0, "verdict": "keep" | "reject", "problem": "empty, or which rule and the words involved"}}, ...]. No other text."""
    for attempt in range(3):
        completed = subprocess.run(["claude", "-p", "--output-format", "json", "--max-turns", "1"],
                                   input=prompt, capture_output=True, text=True, timeout=900, cwd=common.DATA)
        try:
            verdicts = json.loads(re.search(r"\[.*\]", json.loads(completed.stdout)["result"], re.S).group(0))
            if len(verdicts) == len(rows):
                return [verdict["verdict"] == "keep" for verdict in verdicts], [verdict.get("problem", "") for verdict in verdicts]
        except (json.JSONDecodeError, AttributeError, KeyError, TypeError):
            pass
    raise RuntimeError(f"audit failed: {completed.stdout[-300:]}")


def main():
    kept_path, rejected_path, count, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    rng = random.Random(5)
    rows = ([{**row, "checker_keep": True} for row in rng.sample(common.read_jsonl(kept_path), count)]
            + [{**row, "checker_keep": False} for row in rng.sample(common.read_jsonl(rejected_path), count)])
    rng.shuffle(rows)
    batches = [rows[start:start + BATCH] for start in range(0, len(rows), BATCH)]
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        results = list(pool.map(audit, batches))
    for batch, (keeps, problems) in zip(batches, results):
        for row, keep, problem in zip(batch, keeps, problems):
            row["audit_keep"], row["audit_problem"] = keep, problem
    common.write_jsonl(out, rows)
    for label, keep in (("checker kept", True), ("checker rejected", False)):
        group = [row for row in rows if row["checker_keep"] == keep]
        agree = sum(row["audit_keep"] == keep for row in group)
        print(f"{label}: Claude agrees on {agree} of {len(group)}")


if __name__ == "__main__":
    main()
