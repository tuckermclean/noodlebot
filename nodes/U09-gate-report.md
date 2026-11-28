# U09 — gate-report

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G15, U04 | none | S |

**Owns:** in `scheduler/report.py`, the gate state of each open node PR on the status issue (read from G15's records
under `gate/`), the gate-off line, and the "Waiting on you" items for node PRs the gate left to the owner; the new test
`scheduler/report-u09.test.sh`, its line in the `Makefile`'s `TESTS`, and any fixtures it adds under
`scheduler/testdata/u09/`.
**Resolves:** #175

## Purpose
After this node the status issue says, for each open node PR, where it stands in the auto-gate (G15): which of the five
points hold at its head and why each other one does not, when its window ends, that auto-merge is on and the forge
merges it, or that it waits for the owner and why. When the gate is off, the issue says so once, with the reason. The
node PRs the gate leaves to the owner are listed under "Waiting on you", so the owner sees at a glance which merges are
still theirs.

## Tests
- `scheduler/report-u09.test.sh` (new), `report.py` over a fixture state folder with G15 records and the fake forge:
  - A node PR in each gate state (`waiting` with points 1 and 2 failing, `window` with its end, `holds`,
    `auto-merge on`) gets one line in the PR table's gate column naming its head, the points that hold (`1 2 3 4 5`
    style, the failing ones marked) and the first failing point's `why`, or `merges when the window ends at <time>`, or
    `auto-merge on at <sha>`.
  - A PR the gate left to the owner (a protected path, a frozen-line change without approval, a spec-file change, a
    red check, an owner comment or `hold` in the window) is a "Waiting on you" item `<ID>'s PR #N waits for you: <why>`,
    and a PR still within the gate's own steps (CI running, no review yet, window running) is not.
  - The gate off (no reviewer App, the base not requiring `noodlebot/auto-gate`, auto-merge not allowed) gives one line
    `Auto-gate off: <reason>` and no gate column; no `gate/` folder at all gives neither.
  - A spec PR gets no gate line; U04's, U05's and U07's merge-record lines and "Waiting on you" items are unchanged
    (`scheduler/report-u04.test.sh`, `scheduler/report-u05.test.sh` and `scheduler/report-u07.test.sh` pass
    unchanged).
  - A record that does not parse gives the PR `gate state unreadable`, and the rest of the issue is written (SPEC §1.2).

## Changes
1. **The gate column.** `report.py` reads `gate/<N>/record.json` for each open node PR and writes its gate state as
   the Tests section says. *U09-AC-1.*
2. **Waiting on you.** A PR whose record says it waits for the owner gets its item with the reason; one still in the
   gate's steps gets none. *U09-AC-2.*
3. **Gate off.** The record of the gate's state gives the one `Auto-gate off` line. *U09-AC-3.*

## Gate
- **U09-AC-1** — For each open node PR with a G15 record, the status issue shows its head, which of the five points hold and the first failing point's reason, or when its window ends, or that auto-merge is on at that head; a spec PR gets no gate line; and a record that does not parse reads `gate state unreadable` with the rest of the issue written. *Verify:* `sh scheduler/report-u09.test.sh`.
- **U09-AC-2** — A node PR the gate left to the owner is a "Waiting on you" item naming the PR and the reason, a PR still in the gate's own steps (CI running, no review yet, window running) is not, and U04's, U05's and U07's items are unchanged. *Verify:* `sh scheduler/report-u09.test.sh`; `sh scheduler/report-u04.test.sh`, `sh scheduler/report-u05.test.sh` and `sh scheduler/report-u07.test.sh` unchanged.
- **U09-AC-3** — When G15's records say the gate is off, the status issue has one `Auto-gate off: <reason>` line and no gate column; with no `gate/` folder it has neither. *Verify:* `sh scheduler/report-u09.test.sh`.

## Risks
- The issue shows the gate's last pass, not the forge's present state: a PR merged between the pass and the report
  reads as `auto-merge on` until the next report.
- The status issue is not the scheduler's: a failed read of a record is logged and ignored (AGENTS.md).
