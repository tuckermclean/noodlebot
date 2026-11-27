# D19 — u04-date

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | U04, U06 | none | S |

**Owns:** in U04's test `scheduler/report-u04.test.sh`, the lines that set or compute the clock of two cases' runs, at
`f984b60`: case 53's runs (Phase 8, "unread record"; lines 553–560), that is the two `urun3 "$state"` runs (lines 553
and 554), the "new day" run (line 560, `TZ=UTC NOODLEBOT_NOW=2026-11-21T09:00:00`) and lines added between lines 552
and 560 that only compute or set that clock; and U06's Phase U06-A runs (lines 629–631), that is the two
`urun6 "$state"` runs (lines 629 and 630), the overview run (line 631, `TZ=UTC NOODLEBOT_NOW=2026-12-01T09:00:00`) and
lines added between lines 628 and 631 that only compute or set that clock; the record of the runs, in the node's PR and
under `out/node/D19/`. These are frozen test lines: the owner approved changing them, and only them, in issue #226 for
case 53 and in review 6033208452 on PR #227 for U06's runs (both quoted in the PR, Change 3).
**Resolves:** #226

## Purpose
After this node two cases of `scheduler/report-u04.test.sh` pass on any date: case 53 (U04's "unread record") and
U06's Phase U06-A. Each fixes one run at a date (case 53's "new day" run at `NOODLEBOT_NOW=2026-11-21T09:00:00`,
U06-A's overview run at `NOODLEBOT_NOW=2026-12-01T09:00:00`) after two runs on the real clock, so whether that run is on
a new day depends on the day the suite runs. `report.py` takes any change of date, earlier or later, as a new log day,
so each case fails only on the day it names: case 53 failed its three checks on `main` and on every PR on 2026-11-21
(CI runs 44949913403 at `ddc29b2`, 44950000079 at `f984b60` and 44963463375) and passes again from 2026-11-22. Runs of
the file at `f984b60` with `NOODLEBOT_NOW` exported (`TZ=UTC`, 12:00) fail 29 U06 checks on 2026-12-01, 12 on
2026-12-02 and none on 2026-11-30, so U06's case turns `main` and every PR red from 2026-12-01. The node makes each
fixed run always fall on a later day, as `report.py` dates its runs, than the two runs before it, and changes no
assertion.

## Tests
- `scheduler/report-u04.test.sh`, changed only as Change 3 allows. At the head its case 53 lines pass:
  `U04-AC-2: (53, precondition) ready to merge` and the three `U04-AC-2: (53, unread record)` checks (the morning overview
  has a line for the PR; the line does not say ready to merge; the line says still being worked on). Its U06-A lines
  pass too: every `U06-AC-1` check of Phase U06-A (lines 639–666 at `f984b60`), among them those that read
  `$tmp/u6overview`. Every other `PASS:` line of the file at the node's base is the same `PASS:` line at the head.
- The recorded clock sweep of Change 2, at the node's base and at its head.

## Changes
1. **The new day is always later.** Case 53's runs and U06-A's runs each get their clock in one of the two ways issue
   #226 names, or an equivalent one: the two earlier runs get a fixed `NOODLEBOT_NOW` on one day and the fixed run one
   on the next day, or the fixed run's `NOODLEBOT_NOW` is computed as the earlier runs' day plus one, at 09:00. The day
   that counts is the one `report.py` uses (`a.today`, from `now()`: `NOODLEBOT_NOW` read as a local datetime in the
   run's own `TZ`, else the local clock). In each case the earlier runs use the time zone of the test's environment and
   the fixed run `TZ=UTC`, so a computed day is taken in the zone each run is dated in, not from `date -u` alone.
   `urun3`, `urun6` and every other case and run stay as they are: an earlier run that needs a clock of its own is
   written out on its own line (the `env … report.py` command `urun3` or `urun6` runs, with the clock added) instead of
   changing the shared helper. *D19-AC-1.*
2. **Sweep the clock.** Run the whole file, `sh scheduler/report-u04.test.sh`, with the clock its earlier runs read set
   by exporting `NOODLEBOT_NOW` (and `TZ`) to the file's run, which `urun3` and `urun6` pass on to `report.py`:
   - at 12:00 with `TZ=UTC` on each of: the day of the run, one month after it, one year after it, 2026-11-01 (before
     2026-11-21), 2026-12-01 and 2026-12-02;
   - on the day of the run at 00:01 and at 23:59, each with `TZ=Etc/GMT-14` (UTC+14) and with `TZ=Etc/GMT+12`
     (UTC−12);
   - and once with neither variable set (the real clock).

   Each run's output goes under `out/node/D19/`, at the node's base and at its head. At the head, case 53's four lines
   and every `U06-AC-1` line of Phase U06-A are `PASS:` in every run. A `FAIL:` line of another case in a run with an
   exported clock is not this node's (other cases may expect the clock to move between runs); the PR lists each such
   line with whether the base run with the same settings has it too. *D19-AC-1.*
3. **Only the approved lines change.** The diff of `scheduler/report-u04.test.sh` touches only the lines **Owns** names:
   no check, expected value, pattern, check name or other case changes, `urun3`, `urun6` and the fixtures stay
   unchanged, every other U06 run stays as it is, and no other test file changes. The PR lists every frozen line it
   changes (line at the base, before and after) and quotes both of the owner's approvals:
   - for case 53, from issue #226: "Approve, separate fix", given in chat on 2026-11-21 for "that case's frozen lines
     (l.560's fixed NOODLEBOT_NOW, made relative to the earlier runs' clock, or the earlier runs given a fixed earlier
     date), with no assertion changed", covering the lines of case 53's runs (l.553–560 at `f984b60`) and nothing else;
   - for U06's runs, from review 6033208452 on PR #227: "Widen D19", given in chat on 2026-11-24 for "changing only the
     clock of U06's three runs (l.629-631), no assertion changed, same terms as case 53", covering the lines of
     U06-A's runs (l.629–631 at `f984b60`) and nothing else. *D19-AC-2.*
4. **CI is green again.** The quick gate (`sh scheduler/report-u04.test.sh`) passes, and CI passes on the PR, whose CI
   run is the whole suite's evidence. *D19-AC-1.*

## Gate
- **D19-AC-1** — At the node's head case 53's four lines (`U04-AC-2: (53, precondition) ready to merge` and the three `U04-AC-2: (53, unread record)` checks) and every `U06-AC-1` line of Phase U06-A (among them the checks that read `$tmp/u6overview`) are `PASS:` in every run of Change 2's sweep (six dates at 12:00 UTC, from 2026-11-01 to a year after the run and including 2026-12-01 and 2026-12-02, the day of the run at 00:01 and 23:59 in UTC+14 and UTC−12, and the real clock), because each case's fixed run is on a later day, as `report.py` dates it, than the two runs before it; the file passes in the quick gate and CI passes on the PR. *Verify:* the sweep's recorded runs at the base and the head under `out/node/D19/` with their case 53 and U06-A lines in the PR, the quick gate's output and the CI run URL, checked by the fresh reviewer.
- **D19-AC-2** — The node changes only the lines of case 53's runs and U06-A's runs that **Owns** names: every `PASS:` line of `scheduler/report-u04.test.sh` in a base run is the same `PASS:` line at the head, no check, expected value, pattern or check name changes, `urun3`, `urun6`, the fixtures, every other U06 run and every other case are unchanged, no other file outside **Owns** changes, and the PR lists each changed frozen line (base line, before and after) with the owner's approvals quoted: "Approve, separate fix" from issue #226 for case 53 and "Widen D19" from review 6033208452 on PR #227 for U06's lines 629–631. *Verify:* the fresh reviewer's check of `git diff <base>..HEAD` against the PR's list of changed frozen lines and the two approvals, recorded in the PR with the sorted `PASS:` lines of a base run (with a clock at which both cases pass there, such as `NOODLEBOT_NOW=2026-11-20T12:00:00`) and of a head run and their diff.

## Risks
- Case 53 can no longer fail on the real clock: it failed only on 2026-11-21, the day its new-day run names, and that
  day has passed. The deadline is U06's: on 2026-12-01 its overview run falls on the same day as the runs before it, and
  `main` and every PR go red until this node merges.
- With node U05 (PR #225) merged, a node PR that changes frozen test lines reads as needing the owner's approval until
  the owner comments `Frozen lines approved at <head>` on it; the approvals quoted from issue #226 and PR #227 do not
  take that comment's place.
- A sweep that exports `NOODLEBOT_NOW` freezes the clock of every case of the file, so cases that expect time to pass
  between runs may fail in it; Change 2 records those and does not count them.
- The checks of either case may pass at a clock the sweep does not try and still fail at one it misses (a
  daylight-saving change, say); the sweep's two extreme zones near midnight cover the day boundary.
