# U07 — frozen-unreadable

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | U05 | none | S |

**Owns:** in `scheduler/report.py`, the reading of the last `Fresh review`'s `Frozen test lines changed:` lines into the merge record's `frozen` (the value `"unreadable"`) and the frozen-line wording of a ready PR's "Waiting on you" item for that value; in `scheduler/site.py`, the frozen-line note in a ready node's `merge_why` for that value; lines 260 and 261 of U05's frozen `scheduler/report-u05.test.sh` (cases 32 and 33, their expected `frozen` only); the new tests `scheduler/report-u07.test.sh` and `scheduler/site-u07.test.sh`, their lines in the `Makefile`'s `TESTS`, and any fixtures they add under `scheduler/testdata/u07/`.
**Resolves:** #230

## Purpose
After this node a final review whose frozen-line record cannot be read fails safe. U05 reads the last `Fresh review`'s `Frozen test lines changed:` line only when it gives `none` or a count. A line that holds that text but does not parse, such as a quoted `> Frozen test lines changed: 2` or `Frozen test lines changed: 2 lines`, gives `frozen` `null` today, so the PR reads as plainly ready, as if no frozen line changed. Now such a review gives `frozen` `"unreadable"`. The status issue and the site read that value as needing the owner's approval, exactly as they read a count, and the owner's `Frozen lines approved at <sha>` comment at the head clears it the same way. A review with no such line at all (one posted before U05) still gives `null` and reads as plainly ready.

## Tests
- `scheduler/report-u07.test.sh` (new), with the fake forge and state folder that `scheduler/report-u05.test.sh` uses, and one node with its open PR that U04 makes ready (an approving final review at the head, CI passed, no session, no question). Cases, each checking `frozen` in `report.json` and the "Waiting on you" item:
  - the frozen line quoted (`> Frozen test lines changed: 2`): `"unreadable"`, needs approval;
  - more text after the count (`Frozen test lines changed: 2 lines`): `"unreadable"`, needs approval;
  - a word for the count (`Frozen test lines changed: two`), no value after the colon, `0`, `-1` and `02`: `"unreadable"` each;
  - the text in another letter case (`frozen test lines changed: 2`): `"unreadable"`;
  - the text after other words on the line (`Note: Frozen test lines changed: 2`): `"unreadable"`;
  - one line that parses and one that does not (`Frozen test lines changed: none` and a quoted `> Frozen test lines changed: 2`, in either order): `"unreadable"`;
  - two lines that parse to different values (`none` and `2`, in either order): `"unreadable"`; two lines that parse to the same value (`3` twice): `3`;
  - each of U05's accepted forms (a list item, bold with the colon inside, the whole line bold, backticks, CRLF endings): the value U05 gives, unchanged;
  - a review with no line holding the text: `null`, U04's ready item;
  - `"unreadable"` and the owner's approval comment naming the head (and a seven-character prefix of it): ready to merge with the changes approved;
  - `"unreadable"` and an approval naming an earlier head, after a push and a new review at the new head that is unreadable again: needs approval again;
  - `"unreadable"` and an approval from another user, the bot or an author the forge does not mark as the owner: needs approval;
  - `"unreadable"` with `mergeable` `UNKNOWN`: the item carries both notes;
  - `"unreadable"` on a PR that is not ready (CI failed): U04's "still being worked on" item;
  - a later review at the same head that says `Frozen test lines changed: none` after an unreadable one: `"none"`, U04's ready item;
  - the record is kept across a run that reads no new comment.
- `scheduler/site-u07.test.sh` (new): a runtime root built in a scratch folder from copies of `scheduler/testdata/site/` and the cases' `report.json` records, run through `site.py build`, as `scheduler/site-u05.test.sh` does. It checks the `merge_ready` and `merge_why` of a ready node whose record's `frozen` is `"unreadable"`, without an approval, with one at its head, with one at an earlier head, and with the forge-unknown note; and the output against `scheduler/site-schema.json`.
- `scheduler/report-u05.test.sh` (U05's, frozen): lines 260 and 261 change, with the owner's approval given on issue #230, and nothing else in the file does. Each line's expected value `null` becomes `'"unreadable"'`, and its label's closing words `frozen is null` become `frozen is "unreadable"`.
- The other `scheduler/report*.test.sh`, `scheduler/site*.test.sh` and `site/test/*.test.mjs` pass unchanged.

## Changes
1. **An unreadable frozen line.** In `report.py`, a frozen line of the last `Fresh review` comment is any line of its body that holds the text `Frozen test lines changed:`, in any letter case. U05's reading of a line stays: the line parses when only marks that are no letter, digit, underscore or `>` come before the text (a list item's `- `, bold, a backtick), and only `*`, `_`, backticks and blanks surround `none` or a count from 1 without a leading zero after the colon, with an optional CR at the line's end. The record's `frozen` is then:
   - `null` when the comment has no frozen line, or there is no review (as U05);
   - `"none"` or the count when every frozen line parses and all give that same value;
   - `"unreadable"` when a frozen line does not parse, or two give different values.

   `"unreadable"` is kept across runs that read no new comment, and replaced by a newer review, as U05's values are. The owner approved this reading for U05's cases 32 (a quoted line) and 33 (`2 lines`) on issue #230, which is the node skill's step 7 approval of the change to lines 260 and 261 of `scheduler/report-u05.test.sh`; the node's PR still needs the owner's `Frozen lines approved at <head>` comment. *U07-AC-1.*
2. **The ready item.** `report.py` gives a ready PR (U04-AC-2) whose `frozen` is `"unreadable"` U05-AC-3's items for a count: `<ID>'s PR #N changes frozen test lines: needs your approval (reviewed at <sha>, CI passed)` while the current head does not start with `approved`, and `<ID>'s PR #N is ready to merge (frozen test line changes approved; reviewed at <sha>, CI passed)` once it does. U04's forge-unknown note follows when it applies. A PR that is not ready gets U04's item. *U07-AC-2.*
3. **The site.** `site.py build` gives a ready `pr-open` node whose record's `frozen` is `"unreadable"` U05-AC-4's `merge_why` for a count: `changes frozen test lines: needs your approval`, or `frozen test line changes approved` once the head in `open-prs.tsv` starts with the record's `approved`, followed by `; ` and U04's forge-unknown note when that applies. `merge_ready` stays U04's. *U07-AC-3.*

## Gate
- **U07-AC-1** — `report.py` keeps `frozen` `"unreadable"` in an open node PR's `report.json` merge record when its last `Fresh review` has a line holding `Frozen test lines changed:` (any letter case) that U05's reading does not parse (quoted, more text after the count, a word, no value, `0`, a negative count, a leading zero, other words before the text) or two such lines that parse to different values; `"none"` or the count when every such line parses to one value, including each of U05's accepted forms; `null` when there is no such line or no review; kept across runs that read no new comment and replaced by a newer review; and `scheduler/report-u05.test.sh` passes with only its lines 260 and 261 (cases 32 and 33) changed from `main`, each to expect `"unreadable"`. *Verify:* `scheduler/report-u07.test.sh`; `scheduler/report-u05.test.sh` in the PR's CI run; the PR's final review, whose `Frozen test lines changed: 2` lists exactly lines 260 and 261 of `scheduler/report-u05.test.sh` at the merge base.
- **U07-AC-2** — A node's PR that U04-AC-2 makes ready and whose `frozen` is `"unreadable"` reads `<ID>'s PR #N changes frozen test lines: needs your approval (reviewed at <sha>, CI passed)` in "Waiting on you" until its current head starts with the owner's `approved`, then `<ID>'s PR #N is ready to merge (frozen test line changes approved; reviewed at <sha>, CI passed)`; an approval naming an earlier head, or from anyone the forge does not mark as the owner, does not count; U04's forge-unknown note still follows when it applies; a PR that is not ready reads as under U04; `scheduler/report-u04.test.sh` passes unchanged. *Verify:* `scheduler/report-u07.test.sh`; `scheduler/report-u04.test.sh` in the PR's CI run.
- **U07-AC-3** — `site.py build` gives a ready `pr-open` node whose merge record's `frozen` is `"unreadable"` U04's `merge_ready` and `merge_why` `changes frozen test lines: needs your approval` while its head in `open-prs.tsv` does not start with the record's `approved`, and `frozen test line changes approved` once it does, followed by `; ` and U04's forge-unknown note when that applies; the output passes `scheduler/site-schema.json`, and `scheduler/site-u04.test.sh`, `scheduler/site-u05.test.sh` and `site/site.test.sh` pass unchanged. *Verify:* `scheduler/site-u07.test.sh`; `scheduler/site-u04.test.sh`, `scheduler/site-u05.test.sh` and `site/site.test.sh` in the PR's CI run.

## Risks
- A review that names the frozen-line text in prose as well as on its own line (for example `Frozen test lines changed: none` and, below it, a sentence quoting `Frozen test lines changed: 2`) reads as needing approval. That is the fail-safe choice: it costs the owner one look.
- A line that misspells the text, or puts a blank before the colon, is no frozen line, so a review with only such a line still reads as `null`, plainly ready. The node skill's reviewer checks the line (U05's risk).
- A merge record written before this node keeps its `frozen` until a newer review is read, because an older review is not read again (U06-AC-3). An open PR whose last review was read before the deploy reads as before until its next review.
- The contract comment at the top of `scheduler/report-u05.test.sh` (its lines 9 to 11) still says that a line that does not parse gives `null`. It is part of U05's frozen file and stays unchanged; this spec and `scheduler/report-u07.test.sh`'s own contract comment are the current rule.
- `"unreadable"` is a new string value of `frozen`: anything else reading `report.json`'s merge record and expecting only `"none"`, a number or nothing sees it. The API (`scheduler/api.py`, P01) and `nbctl` show no merge record.
