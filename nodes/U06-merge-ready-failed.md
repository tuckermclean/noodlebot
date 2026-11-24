# U06 — merge-ready-failed

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | U04 | D19 | S |

**Owns:** in `scheduler/report.py`: the failed-run reason of a node PR's "Waiting on you" item (`merge_state`, and the morning overview's line built from it) and the comment id of the last `Fresh review` kept in each open node PR's merge record in `report.json` (`post_prs`); in `scheduler/site.py`, the failed-run reason of a node's `merge_ready` and `merge_why` (`merge_state`); the cases this node appends to U04's tests `scheduler/report-u04.test.sh` and `scheduler/site-u04.test.sh` (added lines only, their scratch paths under a folder named `U06`), and any fixtures they add under `scheduler/testdata/u06/`.
**Resolves:** #210

## Purpose
After this node a node PR whose run failed never reads as ready to merge. When the node's state folder `node/<ID>` or the PR's own folder `pr/<N>` holds `FAILED`, the status issue no longer lists both "`<ID>` FAILED" and "`<ID>`'s PR #N is ready to merge": the PR's item says it is still being worked on because its run failed, even when the last `Fresh review` approves the head and CI passed. The site says the same for a `pr-open` node whose `pr/<N>` holds `FAILED`, and keeps a node whose `node/<ID>` holds `FAILED` in state `failed`, never ready. A `Fresh review` comment that a person edits after a newer review was posted no longer becomes the PR's last review again.

## Tests
- `scheduler/report-u04.test.sh` (U04's, frozen; this node only appends cases, with the fake forge and state folder it already uses and every scratch path under a folder named `U06`). Each case starts from a PR U04 makes ready (an approving `Fresh review` at the head, CI passed, no session, no question):
  - `FAILED` in `node/<ID>`: the "Waiting on you" section keeps its `**<ID> FAILED**` item, and the PR's item says the PR is still being worked on, names that its run failed and does not say ready to merge; the morning overview's line for the PR says the same;
  - `FAILED` in `pr/<N>`: the `**PR #N FAILED**` item stays, and the PR's item says still being worked on and names that its run failed;
  - `FAILED` removed again (the owner deletes it to retry): the PR's item is U04's ready item again;
  - `FAILED` together with CI failed on the head: the item names both reasons;
  - an edited review: a first run reads an approving `Fresh review` at the head followed by a newer `Fresh review (request_changes)` at the head (not ready, the verdict named); a later run's comment read returns only the older approving comment, with an update time after the cursor as the forge's `since` filter returns an edited comment (the fake forge filters on the update time); the PR is still not ready, and `report.json`'s record keeps the newer comment's id and verdict; a new `Fresh review (approve)` at the head with a higher id then makes it ready; the newest review edited (same id) to request changes makes it not ready again;
  - a merge record written before this node (no comment id kept) takes the run's last review as U04 does.
- `scheduler/site-u04.test.sh` (U04's, frozen; this node only appends cases, scratch paths under `U06`): with the same ready record, `FAILED` in `pr/<N>` gives the `pr-open` node `merge_ready` false and a `merge_why` naming that its run failed; `FAILED` in `node/<ID>` gives the node state `failed` with `merge_ready` and `merge_why` `null`; the output passes `scheduler/site-schema.json`.
- The existing cases of `scheduler/report-u04.test.sh` and `scheduler/site-u04.test.sh`, and the other `scheduler/report*.test.sh`, `scheduler/site*.test.sh` and `site/test/*.test.mjs`, pass unchanged.

## Changes
1. **A failed run in the status issue.** `report.py`'s `merge_state` gets the reason "its run failed" when the node's folder `node/<ID>` or the PR's folder `pr/<N>` holds `FAILED`, and with that reason the PR is never ready to merge, whatever its review, CI and `mergeable` say. The reason sits with U04's other reasons ("is still being worked on: its run failed; …"). The `**<ID> FAILED**` and `**PR #N FAILED**` items of "Waiting on you" stay as they are, and so does the rule that a node with `QUESTION.md` or `WAITING-PR` in `node/<ID>`, or a session running, gets no PR item. The morning overview's line for the PR, built from the same function, follows. *U06-AC-1.*
2. **A failed run on the site.** `site.py`'s `merge_state` reads `FAILED` in `pr/<N>` as change 1 does: `merge_ready` false and `merge_why` naming that its run failed, through the cleaning and length cut U04 gives `merge_why`. A node whose `node/<ID>` holds `FAILED` already takes state `failed` before `pr-open` and keeps `null` merge fields (U04-AC-3's other states); this node keeps it so. *U06-AC-2.*
3. **An edited review does not come back.** The merge record in `report.json` keeps, next to `review_head` and `verdict`, the id of the comment they came from. A run's comments are read in id order as before; their last `Fresh review` replaces the record's review only when its id is not lower than the kept one (the kept comment itself, edited, or a newer one), so an older review comment that the forge returns again because a person edited it (the `since` filter goes by update time) changes nothing. A record without a kept id (written before this node) takes the run's last review, as U04 does. *U06-AC-3.*

## Gate
- **U06-AC-1** — With `FAILED` in `node/<ID>` or in `pr/<N>`, the status issue's "Waiting on you" item for the node's open PR (and the morning overview's line for it) says the PR is still being worked on and names that its run failed, never that it is ready to merge, even when the last `Fresh review` approves the PR's head and CI on it passed; the `**<ID> FAILED**` or `**PR #N FAILED**` item is still listed, other reasons (CI failed) are still named with it, and with `FAILED` removed the item is U04's ready item again. *Verify:* the U06 cases of `scheduler/report-u04.test.sh`.
- **U06-AC-2** — `site.py build` gives a `pr-open` node whose `pr/<N>` holds `FAILED` `merge_ready` false and a `merge_why` naming that its run failed, with an approving review at its head and CI passed; a node whose `node/<ID>` holds `FAILED` with the same open PR has state `failed` and `null` for both fields; the output passes `scheduler/site-schema.json`. *Verify:* the U06 cases of `scheduler/site-u04.test.sh`.
- **U06-AC-3** — `report.json`'s merge record of an open node PR keeps the comment id of its last `Fresh review`, and a later run that reads an older review comment again (returned by the forge's `since` filter after an edit) leaves the record's review head, verdict and id as they were, so a PR whose newer review requested changes stays not ready; a newer review comment (higher id), or the kept comment itself read again after an edit, replaces it; a record without a kept id takes the run's last review as before. *Verify:* the U06 cases of `scheduler/report-u04.test.sh`.

## Risks
- "Still being worked on" for a failed run is U04's wording for every PR that is not ready; nothing works on a failed node until the owner deletes `FAILED`, which the `FAILED` item beside it says.
- An edit to the last review itself (same id) is taken, as what that review now says; an edit to an older review is ignored, whatever it says.
- U05 (frozen-approval, on its own spec PR) changes the same two `merge_state` functions and the merge record; whichever node is built second merges the other's change into its own.
- The API (`scheduler/api.py`, P01) still reports no ready state, as U04 left it.
