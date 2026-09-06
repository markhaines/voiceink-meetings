# Transcripted indexer acceptance gate

This is Phase 3's acceptance gate for `TranscriptedMarkdownExporter`: proof that a file this
exporter writes is not merely self-consistent, but actually indexes correctly through the
REAL `transcripted-mcp` binary — Mark's own separate "Transcripted" app's indexer — the tool
this exporter exists to feed.

Automated as `TranscriptedIndexerAcceptanceTests.exportedMeetingIndexesWithRealCounts()`
(`Tests/VoiceInkTests/Features/Meetings/Export/TranscriptedIndexerAcceptanceTests.swift`),
guarded by `.enabled(if:)` so it only runs on a Mac that actually has the Transcripted app
installed at its default location — it is reported **skipped**, not failed, everywhere else
(CI included).

## Why a real binary, not a reimplementation

`TranscriptedMarkdownExporterTests.swift` already pins this exporter's output against a
reference port of the real indexer's regex/chunking logic (`ReferenceIndexerParser`), copied
from source for pinning purposes. That proves conformance to the *rule*. It does not prove the
real binary — built from a different Xcode project, on Mark's own release cadence — actually
agrees. This test runs that binary.

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

## Real measured result (2026-09-06, mini)

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

`word_count: 42` matches the file's own `total_word_count: 42` frontmatter exactly. Non-zero,
matching the two known-good real Transcripted meetings the original investigation indexed
(`word_count: 3736` and `3521`) — a fork-produced file is not a special case to this indexer,
it is legible to it the same way a real Transcripted capture is.

Full narrative, the defect this uncovered (`auto_summary_version` gating), and the fail-silent
sanitization proof are in `transcripted-exporter.md`'s Round 2 section
(`.tandem/884f6ef6905c4e2aa4e2ca28c34ea629/`, not tracked in this repo).
