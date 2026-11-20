# A10 — gate-strip

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | A05, A06, A09 | G08 | S |

**Owns:** the strip step of the gate's pass condition (A05's wording) wherever it stands: in `plugin/skills/node/SKILL.md`
(GREEN, step 5's paragraph "The gate's pass condition", the `--update` step that stops on a failing test, the feedback
steps), in `plugin/agents/tester.md`, `plugin/agents/implementer.md` and `plugin/agents/reviewer.md`, and in
`scheduler/unattended-node-update.md`; in `plugin/skills/adopt/SKILL.md`, the strip of the probe's and the baseline's
own output (section 1's probe bullet and section 3's baseline rule); the two in-progress passages of
`plugin/skills/adopt/example-baseline/SPEC.md` ("The regime") and `plugin/skills/adopt/example-baseline/AGENTS.md`
(the **Owns.** bullet), and the note recording their hand correction in `plugin/skills/adopt/example-baseline/FACTS.md`;
`plugin/skills/node/skill-a10.test.sh` (new) and its line in the `Makefile`'s `TESTS`; the new cases in
`plugin/skills/adopt/adopt.test.sh`.
**Resolves:** #211

## Purpose
After this node the gate's pass condition reads the same text whether a run printed it locally or a CI runner
printed it. Before a line is matched against `fail_pattern` and checked for a `known_red` entry, the session strips
what the runner or CI added: colour escape codes, and the timestamp prefix on every line of a fetched job log. The
adopt skill writes `fail_pattern` from a probe run as CI would run it (A09), and that probe's own output can be
coloured too, so the probe and the baseline strip the same additions. The first real adoption took four review
rounds to fix its `fail_pattern` for this. The recorded example `example-baseline/` also stops teaching the
in-progress wording ("lists no node yet", "in an area or in a node") that A09's "Drafts stay true" rule forbids.
That wording reaches `example-area/` too, which reuses its `SPEC.md` and `AGENTS.md`.

## Tests
- `plugin/skills/node/skill-a10.test.sh` (new): the strip step in the skill's GREEN check, in step 5's pass condition
  paragraph, in the `--update` step that stops on a failing test and in the feedback steps; the same in
  `plugin/agents/tester.md`, `plugin/agents/implementer.md`, `plugin/agents/reviewer.md` and
  `scheduler/unattended-node-update.md`. Each case checks one statement within one sentence or one window of lines, as
  the existing A05-AC-3 cases of `plugin/skills/node/skill.test.sh` do.
- `plugin/skills/adopt/adopt.test.sh` (extended, cases added only): section 1's probe and section 3's baseline rule
  strip the same additions from their own output before matching; `example-baseline/SPEC.md` and `AGENTS.md` hold
  none of the in-progress forms the "Drafts stay true" rule names; `example-baseline/FACTS.md` records the hand
  correction.
- The existing cases of `skill.test.sh`, `skill-g07.test.sh` and `adopt.test.sh` (A05's, A06's, A07's and A09's)
  pass unchanged.

## Changes
1. **The strip step in the pass condition.** Wherever the pass condition stands (the Owns line), it says that before a
   line of a run's output is matched against `fail_pattern` and checked for a `known_red` entry, what CI and the
   runner add is stripped: escape codes (colour among them) and a fetched job log's leading timestamp. This holds for
   the CI run of `gate.command` and for local output alike, and the evidence lists each failing line as stripped, with
   the `known_red` entry it matched. The wording names no forge and no harness. *A10-AC-1.*
2. **The adopt skill's own output.** Section 1's probe bullet and section 3's baseline rule say to strip the same
   additions from the probe's and the baseline's own output before `fail_pattern` is checked against it: every
   matched line containing a `known_red` entry, and at least one matched line on a non-zero exit. *A10-AC-2.*
3. **The example stays true.** In `example-baseline/SPEC.md`, "The regime" no longer says the graph lists no node yet
   or names the adoption areas as what the graph holds now. In `example-baseline/AGENTS.md`, the **Owns.** bullet
   no longer says a node places a file it adds "in an area or in a node". Each passage says what stays true while
   the areas are mapped and after `adoption` is removed. This is a hand correction of A06's recorded dry run, not a
   re-recording. `example-baseline/FACTS.md` gets a short note saying so, naming the two passages and the rule they
   now follow. Nothing else in `example-baseline/` or `example-area/` changes. *A10-AC-3.*

## Gate
- **A10-AC-1** — The gate's pass condition in `plugin/skills/node/SKILL.md` (GREEN, step 5's pass condition paragraph, the `--update` step that stops on a failing test, the feedback steps), in `plugin/agents/tester.md`, `plugin/agents/implementer.md`, `plugin/agents/reviewer.md` and in `scheduler/unattended-node-update.md` says that escape codes and a fetched job log's timestamp prefix are stripped from a line before it is matched against `fail_pattern` and checked for a `known_red` entry, for the CI run and local output alike, and that the evidence lists the failing lines as stripped; A05's existing cases pass unchanged. *Verify:* `sh plugin/skills/node/skill-a10.test.sh` and `sh plugin/skills/node/skill.test.sh`.
- **A10-AC-2** — Section 1's probe bullet and section 3's baseline rule of `plugin/skills/adopt/SKILL.md` say that the same additions are stripped from the probe's and the baseline's own output before it is matched against `fail_pattern`; A06's and A09's existing cases pass unchanged. *Verify:* `sh plugin/skills/adopt/adopt.test.sh`.
- **A10-AC-3** — `plugin/skills/adopt/example-baseline/SPEC.md` and `AGENTS.md` hold none of "no node yet", "lists no node" and "in an area or" (either form), and SPEC.md names the adoption areas only as held while the adoption is in progress; `example-baseline/FACTS.md` records that these passages are a hand correction of A06's recorded dry run; A06's and A07's checks of `example-baseline/` and `example-area/` pass unchanged. *Verify:* `sh plugin/skills/adopt/adopt.test.sh`.

## Risks
- Text checks are loose by nature: a case can pass on a sentence that says the opposite. At RED, the tester sweeps
  each new case against removed and reversed clauses (the strip dropped, "local output" left out, "before" turned
  into "after") and each must fail.
- No file under `plugin/` may name a forge or a harness or hold a URL (R02-AC-2, `scheduler/agnostic.test.sh`): the
  timestamp prefix is described, not tied to one CI service.
- The wording tells a session to strip; nothing strips for it. A session that skips the step still misjudges a
  coloured line. G08 gives step 5 the job log to apply it to. A shared strip script would be a separate node.
- A06's checks of the example (`check-regime.py` and `check-coverage.py` on the fixture with the dry run laid over it)
  read the graph, not the prose, so the correction cannot break them. The A07 `example-area/` checks reuse the same
  two files and are run too.
