# Blind pairwise judge: is a candidate's polish as good as the cloud reference?
# Each case is shown in a random order; the judge scores both outputs 1-10 and
# picks a winner or a tie. "Parity" = candidate wins or ties.
#
# The judge is Claude through the `claude -p` CLI, so it runs on Jon's
# subscription rather than paid API credit. Cases go eight to a call.
#
# Usage: python judge.py REFERENCE.jsonl CANDIDATE.jsonl  -> CANDIDATE.judged.jsonl + summary

import concurrent.futures
import json
import random
import re
import statistics
import subprocess
import sys

import common

JUDGE = "claude-cli"
BATCH = 8

RUBRIC = """Judge each rewrite on: keeps every fact and specific from the input and invents nothing; follows the requested style; reads naturally, with correct grammar and punctuation; cuts filler and false starts (using the corrected version when the speaker corrected themselves); obeys the app's rules (no em dashes, no preamble, not treating the text as a command to carry out). Ask whether a user would be happy to send it. Call it a tie when a typical user would be equally happy with either."""

APP_RULES = common.system_prompt("{STYLE}")


def case_block(index, reference, a, b):
    return f"""<case id="{index}">
<style>{common.instruction(reference)}</style>
<input>
{reference["text"]}
</input>
<a>
{a}
</a>
<b>
{b}
</b>
</case>"""


def judge_batch(pairs):
    blocks, flips = [], []
    for index, (reference, candidate) in enumerate(pairs):
        candidate_first = random.Random(reference["id"]).random() < 0.5
        flips.append(candidate_first)
        a, b = (candidate["output"], reference["output"]) if candidate_first else (reference["output"], candidate["output"])
        blocks.append(case_block(index, reference, a, b))
    prompt = f"""You are grading pairs of rewrites of rough text for a writing app. For every case the rewriter was given these instructions, with {{STYLE}} replaced by the case's <style>:

<instructions>
{APP_RULES}
</instructions>

{RUBRIC}

{chr(10).join(blocks)}

Return only a JSON array with one object per case, in order: [{{"id": 0, "a_score": 1-10, "b_score": 1-10, "winner": "A" | "B" | "tie", "a_problems": "short", "b_problems": "short"}}, ...]. No other text."""
    for attempt in range(3):
        completed = subprocess.run(["claude", "-p", "--output-format", "json", "--max-turns", "1"],
                                   input=prompt, capture_output=True, text=True, timeout=900, cwd=common.DATA)
        try:
            reply = json.loads(completed.stdout)["result"]
            verdicts = json.loads(re.search(r"\[.*\]", reply, re.S).group(0))
            if len(verdicts) == len(pairs) and all(v["winner"] in ("A", "B", "tie") for v in verdicts):
                break
        except (json.JSONDecodeError, AttributeError, KeyError, TypeError):
            pass
        if attempt == 2:
            raise RuntimeError(f"judge failed: {completed.stdout[-500:]} {completed.stderr[-500:]}")
    results = []
    for (reference, candidate), candidate_first, verdict in zip(pairs, flips, verdicts):
        candidate_score, reference_score = (verdict["a_score"], verdict["b_score"]) if candidate_first else (verdict["b_score"], verdict["a_score"])
        winner = {"tie": "tie", "A": "candidate" if candidate_first else "reference",
                  "B": "reference" if candidate_first else "candidate"}[verdict["winner"]]
        problems = verdict.get("a_problems" if candidate_first else "b_problems", "")
        results.append({"id": reference["id"], "style": reference["style"], "candidate_score": candidate_score,
                        "reference_score": reference_score, "winner": winner, "candidate_problems": problems})
    return results


def summarize(results, label):
    count = len(results)
    wins = sum(r["winner"] == "candidate" for r in results)
    ties = sum(r["winner"] == "tie" for r in results)
    summary = {
        "label": label, "judge": JUDGE, "cases": count,
        "parity": round((wins + ties) / count, 3), "wins": wins, "ties": ties, "losses": count - wins - ties,
        "candidate_mean": round(statistics.mean(r["candidate_score"] for r in results), 2),
        "reference_mean": round(statistics.mean(r["reference_score"] for r in results), 2),
    }
    by_style = {}
    for r in results:
        by_style.setdefault(r["style"], []).append(r)
    summary["parity_by_style"] = {style: round(sum(x["winner"] != "reference" for x in rows) / len(rows), 2) for style, rows in sorted(by_style.items())}
    return summary


def main():
    reference_path, candidate_path = sys.argv[1], sys.argv[2]
    references = {r["id"]: r for r in common.read_jsonl(reference_path)}
    pairs = [(references[c["id"]], c) for c in common.read_jsonl(candidate_path) if c["id"] in references]
    batches = [pairs[start:start + BATCH] for start in range(0, len(pairs), BATCH)]
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        results = [row for batch in pool.map(judge_batch, batches) for row in batch]
    common.write_jsonl(candidate_path.replace(".jsonl", ".judged.jsonl"), results)
    summary = summarize(results, candidate_path)
    print(json.dumps(summary))
    with open(common.DATA / "scoreboard.jsonl", "a") as board:
        board.write(json.dumps(summary) + "\n")


if __name__ == "__main__":
    main()
