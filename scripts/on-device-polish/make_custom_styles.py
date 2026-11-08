# Writes custom polish-style instructions like the ones users add in the app.
#
# Usage: python make_custom_styles.py OUT.json COUNT

import concurrent.futures
import json
import re
import sys

import common

PROMPT = """Users of a voice-note app write their own "polish styles": one or two sentences telling a rewriting model how to shape their rough dictation. Built-in examples:
{examples}

Write {count} new, varied custom styles real people would create (a nurse's shift handoff note, a LinkedIn post, a polite complaint letter, a text to grandma in simple words, a standup update, a product review, a toast, a cover letter paragraph, a tweet thread, meeting minutes, notes for a doctor, Spanish translation, pirate voice for fun, etc). Mix lengths and tones; some terse, some specific.

Return only a JSON array of {count} instruction strings."""


def main():
    out, count = sys.argv[1], int(sys.argv[2])
    examples = "\n".join(f"- {text}" for text in common.STYLES.values())

    def one(index):
        reply = common.chat("anthropic/claude-opus-5.5", [{"role": "user", "content": PROMPT.format(examples=examples, count=50)}],
                            temperature=1.0, max_tokens=32000)
        return json.loads(re.search(r"\[.*\]", reply, re.S).group(0))

    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        styles = sorted({style.strip() for batch in pool.map(one, range((count + 49) // 50)) for style in batch})
    json.dump(styles[:count] if len(styles) >= count else styles, open(out, "w"), indent=1)
    print(f"wrote {len(styles)} custom styles")


if __name__ == "__main__":
    main()
