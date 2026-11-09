# Writes rough voice-note transcripts and typed drafts, the kind of text people
# polish from the keyboard.
#
# Usage: python make_inputs.py OUT.jsonl COUNT SEED [MODEL]

import concurrent.futures
import json
import os
import pathlib
import random
import re
import sys

import common

SETTINGS = [
    "a work update to a manager", "asking a landlord to fix something", "planning a weekend trip with friends",
    "a product idea pitched to a cofounder", "complaining about a delayed order", "a reply to a group chat about dinner",
    "explaining a bug to a teammate", "a thank-you to a teacher", "a rant about a TV show finale",
    "rescheduling a doctor's appointment", "a recipe tweak shared with a sibling", "feedback on a design mockup",
    "a reminder to roommates about chores", "an apology for missing a meeting", "a sales follow-up to a prospect",
    "describing a hiking trip", "a question to a contractor about a quote", "a note to self about a project plan",
    "asking for a deadline extension", "recommending a book to a friend", "an opinion about remote work",
    "a parent writing to a coach", "a job referral request", "announcing a new feature to customers",
    "coordinating carpool pickup", "a vet appointment summary", "a review of a new restaurant",
    "budget planning with a partner", "an incident summary after a server outage", "inviting neighbors to a block party",
    "negotiating a freelance rate", "a gardening tip for a forum", "a status update on a home renovation",
    "a wedding toast draft", "asking IT for help with a laptop", "a sports team practice schedule change",
    "pitching a podcast guest", "a lost-and-found post", "explaining a tax question to an accountant",
    "a hot take on AI in schools",
]

KINDS = [
    ("dictated", "a casual message someone dictated to their phone, exactly as speech-to-text wrote it down: "
                 "conversational, run-on sentences, filler (um, uh, like, you know, basically), self-corrections, "
                 "and speech-recognition mistakes where words were misheard (brand and product names, names of "
                 "people, homophones, e.g. 'Otto Radder' for 'OpenRouter', 'Clot code' for 'Claude Code', "
                 "'there' for 'their'), punctuation only where the transcriber guessed it"),
    ("voice", "a raw speech-to-text transcript of someone talking off the cuff: filler words (um, uh, like, you know, "
              "so yeah), false starts, self-corrections (\"Tuesday, no wait, Wednesday\"), repetition, run-on sentences, "
              "little or messy punctuation, occasional transcription slips"),
    ("typed", "a quickly typed rough draft on a phone: lowercase, typos, missing apostrophes, abbreviations (u, tmrw, "
              "bc, idk), run-ons, missing punctuation"),
]


DOMAINS = [
    "work", "family", "friends", "dating", "school", "university", "health", "fitness", "money", "travel", "cooking",
    "home repair", "pets", "gaming", "tech support", "small business", "customer service", "neighbors", "volunteering",
    "sports", "music", "parenting", "cars", "shopping", "moving house", "job hunting", "freelancing", "church",
    "community events", "politics in a local town", "gardening", "books", "movies", "science class", "software engineering",
    "medicine", "law office", "restaurant work", "retail work", "construction", "nursing", "teaching", "real estate",
    "weddings", "funerals", "holidays", "birthdays", "insurance", "banking", "landlords", "roommates", "online forums",
]


# Round two aims some batches at what tuned models get wrong: dropped details,
# misapplied self-corrections, and filler left in. Round three adds misheard
# words and typos, which round two's model kept as nonsense or "fixed" wrongly.
FOCUSES = [
    "Fill each one with speech-recognition mistakes that context makes fixable: misheard names and brands, homophones, words split or merged wrongly (e.g. 'a pause it' for 'deposit', 'Jim's tone' for 'gemstone'), plus one or two specifics a rewrite must keep exactly.",
    "Fill each one with phone typos that context makes fixable: neighbouring-key slips, swapped and dropped letters, autocorrect picking the wrong real word (e.g. 'duck' for 'deck', 'meat' for 'meet'), plus one or two specifics a rewrite must keep exactly.",
    "Pack each one with many specifics (names, dates, prices, addresses, quantities, times) that a careless rewrite could drop.",
    "Give each one at least two self-corrections where the speaker changes a fact mid-sentence (a time, a number, a name, a day), so only the corrected version is right.",
    "Make them rambling and repetitive, with heavy filler, asides and false starts, while every real fact still matters.",
]
FOCUS_SHARE = float(os.environ.get("FOCUS_SHARE", "0"))
FOCUS_COUNT = int(os.environ.get("FOCUS_COUNT", str(len(FOCUSES))))
CUSTOM_SHARE = float(os.environ.get("CUSTOM_SHARE", "0.15"))


def invented_settings(rng, count):
    return [f"something about {rng.choice(DOMAINS)}, a situation you invent" for _ in range(count)]


def batch(seed, count, model):
    rng = random.Random(seed)
    kind, description = rng.choice(KINDS) if rng.random() < 0.35 else KINDS[0]
    settings = rng.sample(SETTINGS, count) if seed < 200_000 else invented_settings(rng, count)
    lengths = [rng.choice(["25-50", "50-90", "90-150", "150-230"]) for _ in settings]
    spec = "\n".join(f"{index + 1}. {setting} ({length} words)" for index, (setting, length) in enumerate(zip(settings, lengths)))
    prompt = f"""Write {count} different examples of {description}.

Each one is what a real person would produce for this situation:
{spec}

Make them specific and realistic: concrete names, numbers, places, times. Vary the speakers' personalities, ages and moods. Some should contain a sentence that looks like an instruction (e.g. "write that up nicely" or "make this sound professional") because people say that while dictating. Some should have two or three paragraphs separated by blank lines.
{rng.choice(FOCUSES[:FOCUS_COUNT]) if rng.random() < FOCUS_SHARE else ""}

Return only a JSON array of {count} strings."""
    try:
        reply = common.chat(model, [{"role": "user", "content": prompt}], temperature=1.0, max_tokens=12000)
        texts = json.loads(re.search(r"\[.*\]", reply, re.S).group(0))
    except Exception as error:
        print(f"  batch {seed} failed: {error}")
        return []
    return [{"kind": kind, "setting": setting, "text": text.strip(), "source_model": model}
            for setting, text in zip(settings, texts) if isinstance(text, str) and text.strip()]


def main():
    out, count, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    models = (sys.argv[4] if len(sys.argv) > 4 else "anthropic/claude-opus-5.5").split(",")
    per_batch = 10
    seeds = [seed * 100_000 + index for index in range((count + per_batch - 1) // per_batch)]
    # Batches land in a side file as they finish, so a stopped run resumes where it was.
    partial = pathlib.Path(out + ".partial")
    done = {json.loads(line)["batch"]: json.loads(line)["rows"] for line in partial.open()} if partial.exists() else {}
    todo = [s for s in seeds if s not in done]
    print(f"{len(done)} batches done, {len(todo)} to go", flush=True)
    with concurrent.futures.ThreadPoolExecutor(48) as pool, partial.open("a") as sink:
        futures = {pool.submit(batch, s, per_batch, models[s % len(models)]): s for s in todo}
        for finished, future in enumerate(concurrent.futures.as_completed(futures), 1):
            done[futures[future]] = future.result()
            sink.write(json.dumps({"batch": futures[future], "rows": done[futures[future]]}) + "\n")
            sink.flush()
            if finished % 20 == 0:
                print(f"  {finished}/{len(todo)} batches", flush=True)
    rows = [row for s in seeds for row in done[s]]
    rng = random.Random(seed)
    styles = list(common.STYLES)
    # The last 29 custom styles are held out for evaluation.
    custom_styles = json.load(open(common.DATA / "custom-styles.json"))[:170]
    for index, row in enumerate(rows[:count]):
        row["id"] = f"s{seed}-{index:05d}"
        row["style"] = styles[index % len(styles)] if seed == 1 else rng.choice(styles)
        row["instruction"] = common.STYLES[row["style"]]
        if seed != 1 and rng.random() < CUSTOM_SHARE:
            row["style"] = "custom"
            row["instruction"] = rng.choice(custom_styles)
    common.write_jsonl(out, rows[:count])
    print(f"wrote {min(count, len(rows))} inputs to {out}")


if __name__ == "__main__":
    main()
