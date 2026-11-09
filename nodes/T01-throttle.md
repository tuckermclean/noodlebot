# T01 — throttle

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | none | S02 | M |

**Owns:** `scheduler/usage.py`, `scheduler/usage.test.sh`, the throttle and limit-exit handling in `scheduler/loop.sh`, the Usage section in `scheduler/report.py` and `scheduler/status.sh`, their cases in `scheduler/loop.test.sh` and `scheduler/report.test.sh`.

## Purpose
After this node the scheduler paces itself against the plan's usage limits instead of running into them. It reads the plan's 5-hour and 7-day windows from the sessions' own `rate_limit_event` lines, holds new sessions when a window would run out before it resets, and shows the windows and the throttle on every status issue. Built by hand (Claude, at the owner's request) because the limit was about to be hit; recorded here as a node.

## Tests
- `scheduler/usage.test.sh` (new): readings across repositories and windows, the burn-rate projection, the 7-day pace, a rejected window, a window past its reset, no readings.
- `scheduler/loop.test.sh` (extended): the throttle engages, holds ready nodes and releases; a session stopped by the usage limit uses up no start.
- `scheduler/report.test.sh` (extended): the Usage section.

## Changes
1. **`usage.py --state-root DIR`** merges every repository's readings into `DIR/usage.json` (within a window usage only grows, so the reading with the latest reset and the highest utilization is current) and prints `open: …` or `hold: <reason>`. It holds when a window's status is not `allowed`, when the 5-hour window is projected past `USAGE_5H_LIMIT` (default 0.90) by its reset at the last 30 minutes' burn rate, or when the 7-day window is more than `USAGE_7D_MARGIN` (default 0.10) ahead of an even pace. *AC-1, AC-2.*
2. **The loop throttles.** While `usage.py` says hold, no node or triage starts; running sessions go on. Engaging and releasing are one status-log event each. `SCHED_THROTTLE=0` turns it off. *AC-3.*
3. **Limit exits.** A session that ends with a non-zero code after a non-`allowed` reading, or with a result naming a usage limit, gives its start back. *AC-4.*
4. **Visibility.** The status issue's Usage section shows both windows (bar, percentage, reset, projection, pace) and the throttle; `status.sh` prints one usage line. *AC-5.*

## Gate
- **T01-AC-1** — `usage.py` reports a window's current reading as the highest utilization among the readings with its latest reset, across every repository's session logs, ignoring older windows and malformed lines. *Verify:* `scheduler/usage.test.sh`.
- **T01-AC-2** — It holds for a 5-hour window projected past its limit before the reset, a 7-day window ahead of pace by more than the margin, and a window whose status is not `allowed`; it is open once the burn slows, after a reset, and with no readings. *Verify:* `scheduler/usage.test.sh`.
- **T01-AC-3** — While the throttle holds, ready nodes do not start; a fresh window releases it and they start; each change is one status-log event. *Verify:* `scheduler/loop.test.sh`.
- **T01-AC-4** — A session stopped by the usage limit is reported as such and uses up no start. *Verify:* `scheduler/loop.test.sh`.
- **T01-AC-5** — The status issue shows both windows and whether the throttle holds, with its reason. *Verify:* `scheduler/report.test.sh`.

## Risks
- `rate_limit_event` is what the CLI emits today (unverified as a stable interface); if it changes, the throttle reads nothing and stays open.
- Readings arrive only while sessions run, so an idle machine keeps the last reading until a session starts.
- How the CLI behaves at the limit (waits, or exits) is unverified; both are handled (the session keeps running, or its start is given back).
