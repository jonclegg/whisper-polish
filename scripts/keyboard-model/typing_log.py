# Reads the keyboard's typing log (Settings › Typing log › Share, or copied off the
# phone with devicectl) and reports how the suggestion bar did on real typing:
# the same bar and savings numbers as bench.py, how the bar's speed held up, and
# the words it missed with what it offered instead, and where bar taps landed.
#
# Usage: python typing_log.py typing-log.jsonl [--misses 40]
#   Copy off a phone that's plugged in:
#   xcrun devicectl device copy from --device Jiphone --domain-type appGroupDataContainer \
#     --domain-identifier group.com.jonclegg.WhisperPolish --source Library/typing-log.jsonl --destination typing-log.jsonl

import argparse
import collections
import json
import random

###############################################################################

def offered_at(entry):
    """How many letters were typed when the bar first offered the word, or None."""
    word = entry["word"].lower()
    for bar in entry["bars"]:
        typed = bar["typed"].lower()
        if not word.startswith(typed):
            continue
        suggestions = bar["shown"] if not typed else bar["shown"][1:]
        if word in (s.lower() for s in suggestions):
            return len(typed)
    return None

###############################################################################

def next_word_bar(entry):
    """What the bar offered before a letter of the word was typed, if it caught up in time."""
    return next((bar["shown"] for bar in entry["bars"] if not bar["typed"]), None)

###############################################################################

def percentile(values, share):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(share * len(ordered)))]

###############################################################################

BAR_HEIGHT = 40
# A bar tap this soon after a key, this low in the bar, was likely meant for the top row.
QUICK_MS = 350
LOW_IN_BAR = 26

def report_taps(entries):
    """Where bar taps landed, and the ones that look like a top-row key caught by the bar."""
    taps = [(e, t) for e in entries for t in e.get("taps", [])]
    if not taps:
        return
    bar = [(e, t) for e, t in taps if t["target"].startswith("bar ")]
    print(f"\n{len(taps)} touches logged, {len(bar)} on the bar")
    rows = collections.Counter(int(t["y"] // 10) * 10 for _, t in bar)
    print("bar taps by height (y from the top, bar is 0-40): " + ", ".join(f"{y}-{y + 10}: {n}" for y, n in sorted(rows.items())))
    suspicious = [(e, t) for e, t in bar if t["y"] >= LOW_IN_BAR and (t["milliseconds"] or 10_000) < QUICK_MS]
    print(f"bar taps low in the bar within {QUICK_MS} ms of the touch before: {len(suspicious)}")
    for e, t in suspicious[:20]:
        print(f"  {t['target']!r} at x {t['x']:.0f} of {e['keyboardWidth']:.0f}, y {t['y']:.0f}, {t['milliseconds']} ms → {e['word']!r}  …{e['before'][-30:]!r}")
    # Keys typed from the strip of the bar that now belongs to the keys while typing.
    edge = [(e, t) for e, t in taps if not t["target"].startswith("bar ") and t["y"] < BAR_HEIGHT]
    print(f"keys typed from the bar's bottom edge: {len(edge)} " + str(collections.Counter(t["target"] for _, t in edge).most_common(10)))

###############################################################################

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("log")
    parser.add_argument("--misses", type=int, default=40)
    args = parser.parse_args()
    with open(args.log) as source:
        entries = [json.loads(line) for line in source if line.strip()]
    if not entries:
        print("The log is empty.")
        return

    words = len(entries)
    keystrokes = sum(len(e["word"]) + 1 for e in entries)
    hits = [offered_at(e) for e in entries]
    before = sum(1 for h in hits if h == 0)
    saved = sum(len(e["word"]) - h for e, h in zip(entries, hits) if h is not None)
    finishes = collections.Counter(e["finish"] for e in entries)
    late = sum(1 for e in entries if next_word_bar(e) is None)
    print(f"{words} words, {entries[0]['date'][:10]} to {entries[-1]['date'][:10]}")
    print(f"next word in the bar before typing: {before / words:.1%}")
    print(f"keystrokes saved: {saved / keystrokes:.1%}")
    print(f"finished by: {dict(finishes)}")
    print(f"bar never showed next-word predictions before the first letter: {late / words:.1%}")
    slowest = [e["slowestBarMilliseconds"] for e in entries if e.get("slowestBarMilliseconds") is not None]
    if slowest:
        print(f"slowest bar update per word, ms: median {percentile(slowest, 0.5)}, 90% {percentile(slowest, 0.9)}, "
              f"99% {percentile(slowest, 0.99)}, worst {max(slowest)}")

    report_taps(entries)

    # Words typed out in full that the bar never offered, for a look at what it offered instead.
    misses = [e for e, h in zip(entries, hits) if h is None and e["finish"] == "typed" and len(e["word"]) > 1]
    print(f"\n{len(misses)} words typed out without the bar offering them; a sample:")
    random.seed(0)
    for e in random.sample(misses, min(args.misses, len(misses))):
        context = e["before"][-60:].replace("\n", "⏎")
        offered = next_word_bar(e)
        print(f"  …{context!r} → {e['word']!r}  bar: {offered if offered is not None else 'not caught up'}")
    corrected = [e for e in entries if e["finish"] in ("autocorrected", "reverted")]
    if corrected:
        print("\nautocorrections:")
        for e in corrected[-args.misses:]:
            print(f"  {e['finish']}: {e.get('typed')!r} → {e['word']!r}  …{e['before'][-40:]!r}")

###############################################################################

if __name__ == "__main__":
    main()
