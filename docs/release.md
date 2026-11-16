# Release log

## 2026-11-16 — Keyboard no longer crashes when it closes mid-work

**What changed for users:** the Whisper Polish keyboard could crash when you left a
text field or switched apps while it was still working out suggestions, holding
delete, moving the cursor with the space bar, or polishing. It now drops that late
work instead. A polish still running when the keyboard closes is thrown away rather
than written into the field.

**Operator:** nothing to do beyond shipping a new build. No cost.
