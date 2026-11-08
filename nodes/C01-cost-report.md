# C01 — cost-report

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| later | none | none | S |

**Owns:** the cost lines in `scheduler/report.py`, their cases in `scheduler/report.test.sh`.

## Purpose
After this node the status issue shows what each session costs: while it runs, its cost and turns so far, and when it ends, its total in the event comment. The figures come from the session's own stream-json `result` events.

## Tests
- `scheduler/report.test.sh` (extended): session logs with several `result` events, with none, and with malformed lines.

## Changes
1. **Running cost.** The body's line for each running session adds its cost so far (the sum of `total_cost_usd` over its `result` events) and turns. *AC-1, AC-3.*
2. **Total at the end.** The comment for a session's end adds its total cost and turns. *AC-2.*

## Gate
- **C01-AC-1** — The status body's line for a running session shows its cost so far in dollars and its turns, summed over its `result` events. *Verify:* `scheduler/report.test.sh`.
- **C01-AC-2** — The comment for a session's end carries the session's total cost and turns. *Verify:* `scheduler/report.test.sh`.
- **C01-AC-3** — A session with no `result` event yet, or with malformed lines, shows "no cost yet" and does not stop the report. *Verify:* `scheduler/report.test.sh`.

## Risks
- `total_cost_usd` is the CLI's list-price estimate, not the bill; the issue says so.
