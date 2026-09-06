# Transcripted indexer conformance and acceptance

Two DIFFERENT things live under this name, and conflating them was a Round 2 defect this file
fixes. Read the distinction before trusting a green CI run to mean anything about the second
one.

## The portable conformance tests — ALWAYS run, on every machine, including CI

`TranscriptedMarkdownExporterTests.swift`'s `ReferenceIndexerParser`-based tests (byte-equality
against a real fixture, the two-space separator, header-line-shape/mandatory-`/`/blank-line
conformance, the speakerLabel identity proof (exported == resolved, and header == `speakers:`), the sanitization fail-silent proofs) pin
this exporter's OUTPUT against a verbatim port of the real indexer's parsing rule, copied from
source. These require no external binary, run everywhere, and their being green is genuine,
unconditional proof that this exporter's format matches the real regex/chunking contract.

## The speaker-label policy, and why it is only a last line of defence

The real indexer deletes every literal `**` from an utterance's header line before it reads the
label, and it unescapes nothing — not Markdown, not backslashes (`parseStyledTranscriptEntry`
and `parseFrontmatterSpeakers`, both read from source). So a run of two or more consecutive
asterisks in a speaker label CANNOT be represented: whatever the file stores is what a reader
sees, and any `**` in it is silently deleted on the way into the index.

`TranscriptSanitizer.speakerLabel` therefore collapses each run of 2+ asterisks to a single
`*`, and leaves everything else — a lone `*` included — byte-identical. That is deterministic
and idempotent, and it is deliberately, visibly lossy: `**Mark**` is exported and indexed as
`*Mark*`, and `**` and `****` alike become `*`. Run length is not recoverable. Two earlier
designs failed here — preserving `**` let the indexer silently rename the speaker; escaping
every `*` stored backslashes the reader then sees forever, in both the transcript header and
the `speakers:` names.

**The durable fix is input validation at the speaker-rename UI, which is Phase 2 work that does
not exist yet.** That is where a person can be told a name cannot be stored exactly while they
still have the keyboard in their hands. This exporter's transform is a last line of defence
behind that, not the primary guard, and it is documented as such in
`TranscriptedMarkdownExporter.swift` as well as here.

## The real-indexer acceptance check — NOT YET a proven gate

`TranscriptedIndexerAcceptanceTests.exportedMeetingIndexesWithRealCounts()`
(`Tests/VoiceInkTests/Features/Meetings/Export/TranscriptedIndexerAcceptanceTests.swift`) is a
DIFFERENT kind of proof: it drives the REAL `transcripted-mcp` binary — Mark's own separate
"Transcripted" app's indexer, not a reimplementation — against a file this exporter actually
wrote, and reads the real SQLite index it produced. This is the only test in this exporter's
suite that can catch a defect the conformance tests, by construction, cannot: a divergence
between the real binary's actual behavior and the `ReferenceIndexerParser` port of it (a stale
port, a build the port doesn't match, a bug specific to the real binary).

**This is currently gated by `.enabled(if:)` on the real binary's presence, which means CI —
and any machine without Mark's Transcripted app installed — SKIPS it.** A skipped test reports
as passing in `xcodebuild`'s summary, indistinguishable from a real pass in the CI status this
PR shows. **A reader must not conclude, from a green CI run on this PR, that the real-indexer
check ever executed.** It has only actually run, and only actually proven anything, on
machines where it's been run BY HAND with the binary present (the mini, so far — see the
measured result below) or where a FUTURE required gate-mode explicitly fails when the binary
is absent rather than skipping.

That gate-mode doesn't exist yet, deliberately. A sibling PR (`#19`,
`phase2-realmodel-smoke`) is independently building an explicit "fail loudly if the
prerequisite is absent" idiom for exactly this shape of problem — an env var that flips a
test's missing-prerequisite behavior from skip to hard-fail. As of this round `#19` has not
merged to `main`. This file deliberately does not invent a second, competing mechanism ahead
of that: once `#19` lands, `TranscriptedIndexerAcceptanceTests` should adopt its exact idiom
(same env var, same failure behavior) rather than grow its own. Until then, the honest
description of this test is "an opportunistic real-indexer check with no required mode" — not
"the acceptance gate" — and this file's title has been corrected accordingly.

## Why a real binary check exists at all, given the conformance tests

The conformance tests prove this exporter's output matches a *reference copy* of the real
regex/chunking rule. They cannot prove the real binary agrees, because that reference copy
could itself be stale, wrong, or drift from a real binary rebuild. Only actually running the
real binary against real output closes that gap — which is exactly why it matters that this
check currently has no required mode: without one, that gap stays open on every CI run.

## Recipe (safe to re-run by hand)

```bash
SCRATCH=/tmp/transcripted-acceptance-manual
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/meetings" "$SCRATCH/dictations" "$SCRATCH/cache"

# Drop a fork-produced .md into $SCRATCH/meetings (TranscriptedMarkdownExporter.write(...),
# or any real file) — then:

TRANSCRIPTED_MEETINGS_DIR="$SCRATCH/meetings" \
TRANSCRIPTED_DICTATIONS_DIR="$SCRATCH/dictations" \
TRANSCRIPTED_INDEX_DIR="$SCRATCH/cache" \
"/Users/mark/Library/Application Support/Transcripted/mcp/transcripted-mcp" --self-test

/usr/bin/sqlite3 -header -column "$SCRATCH/cache/mcp_index.sqlite" \
  "SELECT filename, word_count, speaker_count, duration_seconds FROM meetings;"
/usr/bin/sqlite3 -header -column "$SCRATCH/cache/mcp_index.sqlite" \
  "SELECT kind, position, owner, text FROM meeting_summary_items WHERE kind='action_item';"

rm -rf "$SCRATCH"
```

**Why this is safe** (verified against `~/code/transcripted`'s own source, not assumed):
`TRANSCRIPTED_MEETINGS_DIR`/`TRANSCRIPTED_DICTATIONS_DIR`/`TRANSCRIPTED_INDEX_DIR` sit ABOVE
the app's real manifest in `CaptureLibraryResolver.resolve()`'s own resolution order, so a
scratch-scoped `--self-test` run never reads or writes
`~/Library/Application Support/Transcripted/mcp-directories.json` or the real
`~/Library/Application Support/Transcripted/cache` — it is a brand-new, separate process, not
a client of the real running MCP server (which keeps running under its own PID, untouched).
Nothing here ever touches an `OneDrive-ATEME` path.

## Durable artifact: check the numbers yourself, don't trust this file's prose

`TranscriptedIndexerAcceptanceTests.exportedMeetingIndexesWithRealCounts()` persists its own
actual query output — the `--self-test` result, the `meetings` row, every `action_item` row —
to **`/tmp/voiceink-transcripted-acceptance-last-result.txt`** every time it runs (overwritten,
not appended: this is "the last real result", not a log), written BEFORE its assertions run so
a failed assertion still leaves the real measured numbers on disk. The test's own scratch
directory (the `.md` file and the SQLite database it ran against) is deleted immediately after
each run, so this plain-text file is the only durable record — read it directly rather than
trust the "Real measured result" section below, which is prose describing one specific run.

## Real measured result (2026-09-06, mini) — a snapshot, not the durable record

Ran the recipe above against a file `TranscriptedMarkdownExporter.write(...)` actually wrote
for a synthetic 5-utterance, 3-speaker (`You`, `Jane Doe`, `Sam Lee`) meeting with 2 action
items (one owned, "Mark: follow up with the vendor on pricing"; one unowned, "Send the
revised proposal by Friday"):

```
$ /usr/bin/sqlite3 -header -column "$SCRATCH/cache/mcp_index.sqlite" \
    "SELECT filename, word_count, speaker_count, duration_seconds FROM meetings;"
filename                            word_count  speaker_count  duration_seconds
-----------------------------------  ----------  -------------  ----------------
2026-09-06 Acceptance Test Meeting  42          3              0

$ /usr/bin/sqlite3 -header -column "$SCRATCH/cache/mcp_index.sqlite" \
    "SELECT kind, position, owner, text FROM meeting_summary_items WHERE kind='action_item';"
kind         position  owner  text
-----------  --------  -----  ------------------------------------
action_item  0         Mark   follow up with the vendor on pricing
action_item  1                Send the revised proposal by Friday
```

`word_count: 42` matches the file's own `total_word_count: 42` frontmatter exactly, and
matches the value independently counted from the fixture segments in the test itself (not
read back from the database and compared to itself). Non-zero, matching the two known-good
real Transcripted meetings the original investigation indexed (`word_count: 3736` and `3521`)
— a fork-produced file is not a special case to this indexer, it is legible to it the same way
a real Transcripted capture is.

Full narrative, the `auto_summary_version` gating defect (Round 2), the `**`-in-speakerLabel
identity defect (Round 3), and every before/after fail-silent proof are in
`transcripted-exporter.md`'s Round 2 and Round 3 sections
(`.tandem/884f6ef6905c4e2aa4e2ca28c34ea629/`, not tracked in this repo).
