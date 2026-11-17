# Release log

## 2026-11-17 — Polish stops running the keyboard out of memory

**What changed for users:** Polish in the keyboard often failed silently, because iOS
shut the keyboard down for using too much memory while it polished. Polish now uses
about 25 MB less at its peak (148–150 MB instead of 173–175 MB, against the 177 MB
limit) and gives the same results for English and other Latin-script text. Emoji
and other scripts still work but may polish slightly differently. The app asks once to download the updated Polish
model (689 MB, smaller than before), replacing the old one.

**Operator:** the model `polish/qwen3.5-0.8b-r3dpo-latin-Q8_0.gguf` is already in the
model bucket behind CloudFront (about 1¢ a month to store). Every user downloads it
once: about $0.06 of CloudFront transfer each. Ship a new build.

## 2026-11-16 — Keyboard no longer crashes when it closes mid-work

**What changed for users:** the Whisper Polish keyboard could crash when you left a
text field or switched apps while it was still working out suggestions, holding
delete, moving the cursor with the space bar, or polishing. It now drops that late
work instead. A polish still running when the keyboard closes is thrown away rather
than written into the field.

**Operator:** nothing to do beyond shipping a new build. No cost.
