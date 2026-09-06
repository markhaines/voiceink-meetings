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

`TranscriptSanitizer.speakerLabel` runs THREE steps, named exactly so the claim below is
falsifiable rather than descriptive: (1) every Unicode scalar for which
`CharacterSet.whitespacesAndNewlines.contains(scalar)` is true becomes a single ASCII space
(U+0020) — checked BEFORE the control-character check, so TAB/LF/CR/NEL (U+0085), which are in
BOTH `whitespacesAndNewlines` and `controlCharacters`, are normalized to a space here and never
reach step (2); `whitespacesAndNewlines` also covers non-ASCII space separators, verified
directly rather than assumed: NO-BREAK SPACE U+00A0, LINE SEPARATOR U+2028, and IDEOGRAPHIC
SPACE U+3000 all test `true` and are each normalized to a plain space exactly like ASCII
whitespace, with no divergence found. (2) any remaining scalar for which
`CharacterSet.controlCharacters.contains(scalar)` is true — genuinely non-whitespace controls
such as NUL, which step (1) does not touch — is dropped outright. (3) the result, which now
contains only U+0020 as whitespace, is split on `CharacterSet.whitespaces`, empty components
are filtered out, and the parts are rejoined with one `" "` — collapsing any run (including one
step (1) just created) and stripping leading/trailing whitespace. THEN, and only then, each run
of 2+ asterisks in that already-normalized value is collapsed to a single `*`. For everything
else — a lone `*` included — that asterisk pass makes no additional change: the result is
byte-identical to the value steps (1)-(3) produce, not to the raw input. None of `" Jane  Doe "`,
`"*\u{0}a"`, `"Jane\u{00A0}Doe"`, `"*\u{2028}*"`, or `"*\u{3000}*"` is returned byte-identical to
what was typed — only the value steps (1)-(3) produce is what the final asterisk step is a no-op
against. That asterisk pass is deterministic and idempotent, and it is deliberately, visibly
lossy: `**Mark**` is exported and indexed as
`*Mark*`, and `**` and `****` alike become `*`. Run length is not recoverable. Two earlier
designs failed here — preserving `**` let the indexer silently rename the speaker; escaping
every `*` stored backslashes the reader then sees forever, in both the transcript header and
the `speakers:` names.

**The durable fix is input validation at the speaker-rename UI, which is Phase 2 work that does
not exist yet.** That is where a person can be told a name cannot be stored exactly while they
still have the keyboard in their hands. This exporter's transform is a last line of defence
behind that, not the primary guard, and it is documented as such in
`TranscriptedMarkdownExporter.swift` as well as here.

## The real-indexer acceptance check — now has a required gate mode

`TranscriptedIndexerAcceptanceTests.exportedMeetingIndexesWithRealCounts()`
(`Tests/VoiceInkTests/Features/Meetings/Export/TranscriptedIndexerAcceptanceTests.swift`) is a
DIFFERENT kind of proof: it drives the REAL `transcripted-mcp` binary — Mark's own separate
"Transcripted" app's indexer, not a reimplementation — against a file this exporter actually
wrote, and reads the real SQLite index it produced. This is the only test in this exporter's
suite that can catch a defect the conformance tests, by construction, cannot: a divergence
between the real binary's actual behavior and the `ReferenceIndexerParser` port of it (a stale
port, a build the port doesn't match, a bug specific to the real binary).

**On an ORDINARY run — gate mode NOT set, which is what the current default CI configuration
does, and what every plain local `xcodebuild test` does — this still SKIPS on any machine
without Mark's Transcripted app installed.** A skipped test reports as passing in `xcodebuild`'s
summary, indistinguishable from a real pass. That remains correct, desired convenience behavior:
the binary has never been on CI and is not expected to be. **A reader must not conclude, from an
ordinary green CI run (one that did not set the gate-mode flag below), that the real-indexer
check executed.**

**ROUND 5: this test now has a required GATE-RUNNING MODE, closing that gap for anyone who
deliberately wants proof.** It adopts `RealModelSmokeTests.swift`'s
(`Tests/VoiceInkTests/Features/Meetings/Transcription/RealModelSmokeTests.swift`, from PR #19
`phase2-realmodel-smoke`, merged to `main`) TWO-NAME CONVENTION and its
prerequisite-plus-gate-mode expression (`.disabled(if: <prerequisite missing> &&
!isGateRunningMode, "...")`) rather than growing a second, competing mechanism.

**ROUND 6 CORRECTION: this is NOT that sibling's exact idiom, and Round 5 saying "the same
failure behavior" was itself imprecise, corrected here.** `RealModelSmokeTests` also carries an
INDEPENDENT, UNCONDITIONAL CI-disable trait (`.disabled(if: isRunningInCI, ...)`) that no
gate-mode flag can override — on `main`, explicit gate mode there still skips under CI
detection. This test DELIBERATELY OMITS an equivalent CI-disable trait, so
`TEST_RUNNER_TRANSCRIPTED_ACCEPTANCE_GATE_MODE=1` overrides CI (or any other environment) here —
Mark's explicit ruling: gate mode exists so an explicitly requested proof fails loudly when the
environment cannot satisfy it, because otherwise an environment variable the caller may not even
know about could silently downgrade a requested gate into a skip, which is the exact false
assurance this mechanism exists to eliminate. `RealModelSmokeTests` is expected to be realigned
to this same rule in a separate change, not this file's to make. See FOLLOWUPS.md's
"Gate-running modes" central list for the repo-wide registry of every one of these flags.

**Set the EXTERNAL, `TEST_RUNNER_`-prefixed form on the `xcodebuild` invocation — this is the
thing to copy:**

```
TEST_RUNNER_TRANSCRIPTED_ACCEPTANCE_GATE_MODE=1 xcodebuild test \
  -project VoiceInk.xcodeproj -scheme VoiceInk -destination 'platform=macOS' \
  -only-testing:VoiceInkTests/TranscriptedIndexerAcceptanceTests
```

The UNPREFIXED form, `TRANSCRIPTED_ACCEPTANCE_GATE_MODE` (no `TEST_RUNNER_`), is what the
already-launched test process reads back internally via `ProcessInfo` — it is never what an
external caller sets. `xcodebuild test` launches the test host through a LaunchServices-mediated
path that inherits nothing from the invoking shell except `TEST_RUNNER_`-prefixed variables,
which it forwards with the prefix stripped; setting the unprefixed form on the outer `xcodebuild`
command never crosses that boundary, so the missing binary quietly skips and the run reports
green — the exact false assurance this mechanism exists to prevent. Documenting the unprefixed
name as the thing to set was itself a blocking review finding against PR #19; do not repeat it
here.

With gate mode engaged and the binary genuinely absent, the test runs for real and fails (the
`Process().run()` call against the missing binary path throws) instead of skipping. With gate
mode engaged and the binary present, this proves the same thing running it by hand always
proved — see the measured result below — except now a CI-style run can demand that proof
instead of trusting prose.

## Why a real binary check exists at all, given the conformance tests

The conformance tests prove this exporter's output matches a *reference copy* of the real
regex/chunking rule. They cannot prove the real binary agrees, because that reference copy
could itself be stale, wrong, or drift from a real binary rebuild. Only actually running the
real binary against real output closes that gap — which is exactly why the required gate mode
above matters: on an ordinary run where gate mode is not set (the current default CI
configuration's own runs included), that gap stays open, same as it would for any other
prerequisite-gated real-hardware/real-binary check.

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
