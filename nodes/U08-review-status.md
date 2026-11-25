# U08 — review-status

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G13, S17, U04 | none | M |

**Owns:** in `scheduler/report.py`: the review state of each open PR (read from `state/<name>/review/`,
`review.log` and G13's `feedback/<N>.held`), its line in the status table, the "no reviewer App token" line, and the reviewer's items under "Waiting
on you" (a PR the reviewer left to the owner for its frozen-line approval or the owner's decision, a head with a
no-verdict note, a PR whose reviewer rework rounds reached the cap); the review fields in `report.json`; the new test `scheduler/report-u08.test.sh`, its line in the
`Makefile`'s `TESTS`, and any fixtures it adds under `scheduler/testdata/u08/`.
**Resolves:** #259

## Purpose
After this node the status issue says where each open PR stands with the reviewer. It gives the head reviewed and the
verdict, or what the review waits for: CI, a session, the owner, or the reviewer App. When there is no reviewer App
token it says so. A PR the reviewer left to the owner (frozen-line approval, the owner's decision, no verdict) is
listed under "Waiting on you", and so is a PR whose reviewer-started rework rounds reached G13's cap. The report only reads the records S16 and S17 keep: it calls the forge for nothing new.

## Tests
- `scheduler/report-u08.test.sh` (new), with fixtures of `state/<name>/review/` and `review.log`:
  - An open PR reviewed at its current head shows `reviewed at <short sha>: approved` or `changes requested`. A PR
    reviewed at an older head shows that it waits for a review of its new head and why (`settling`, `CI running`,
    `session live`, or `queued` for a turn).
  - A PR whose last review is a frozen-line or owner-decision `COMMENT` at its current head is listed under "Waiting on
    you" as `PR #N: reviewed at <short sha>, ready apart from your approval of its frozen test lines` or `needs your
    decision: <reasons>`, and a no-verdict note at its current head as `PR #N: the reviewer gave no verdict at <short
    sha>`. A PR with `feedback/<N>.held` at its current head is listed as `PR #N: changes requested at <short sha>
    after <count> rework rounds; your comment or review starts the next`, and once the hold is gone it is not.
  - With `review.log`'s last loop start saying `no reviewer App token; nothing reviewed`, the status issue says
    `Reviewer: no reviewer App token; nothing reviewed` and gives no PR a review state. With `review.stop`, it says
    `Reviewer: paused`.
  - A repository with no `review/` folder and no `review.log` gives the status issue it gives today (the existing
    `report*.test.sh` cases pass unchanged).
  - `report.json` holds each open PR's review state, and a run that reads no new record keeps it.

## Changes
1. **The review state.** `report.py` reads each open PR's review records and the last `review.log` lines, gives the
   PR its review state in the status table and in `report.json`, and writes the reviewer's line. *U08-AC-1, U08-AC-3.*
2. **Waiting on you.** The reviewer's frozen-line, owner-decision and no-verdict outcomes at a PR's current head, and
   G13's rounds hold at it, are items under "Waiting on you", next to U04's merge items for the same PR. *U08-AC-2.*

## Gate
- **U08-AC-1** — The status issue gives each open PR's review state: reviewed at which head and the verdict, or waiting for a review of its new head with the reason (`settling`, `CI running`, `session live`, `queued`), and `report.json` holds it. *Verify:* `sh scheduler/report-u08.test.sh`.
- **U08-AC-2** — A PR whose last review at its current head is a frozen-line or owner-decision `COMMENT` or a no-verdict note, or whose `feedback/<N>.held` names its current head (the rework rounds cap), is listed under "Waiting on you" with what it waits for, and a PR whose hold is gone is not. *Verify:* `sh scheduler/report-u08.test.sh`.
- **U08-AC-3** — With no reviewer App token the status issue says `Reviewer: no reviewer App token; nothing reviewed` and gives no PR a review state, with `review.stop` it says `Reviewer: paused`, and with no review records at all it is as today. *Verify:* `sh scheduler/report-u08.test.sh`.

## Risks
- The status issue's body grows by a line per open PR. With many PRs open, the table may need folding, which is a
  later change.
- The review state is read from local records, so it can lag the forge by one pass, for example after the owner
  dismisses a reviewer review by hand. The next pass corrects it.
