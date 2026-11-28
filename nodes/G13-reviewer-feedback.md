# G13 — reviewer-feedback

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G03, G12 | U08 | M |

**Owns:** in `scheduler/feedback.py`, the reviewer's items (the `--reviewer LOGIN` option, taking the reviewer App's
`REQUEST_CHANGES` review at a bot PR's current head and that review's inline comments as feedback, and leaving every
other reviewer item out), the rounds cap (the option `--rounds-max M`, the count `feedback/<N>.rounds` and the hold
record `feedback/<N>.held` in the state folder) and their lines in the docstring; in `scheduler/loop.sh`, passing
`--reviewer` with the first line of `~/.config/noodlebot/reviewer-login` to `feedback.py` when that file exists, and
`--rounds-max` from the setting `SCHED_REVIEW_ROUNDS` (default 3), and their lines in the header comment; the new tests
`scheduler/feedback-g13.test.sh`, `scheduler/loop-g13.test.sh` and `scheduler/loop-g13-rounds.test.sh` (each under the
30 s file budget), their lines in the `Makefile`'s `TESTS`, and any fixtures they add under `scheduler/testdata/g13/`.
**Resolves:** #259

## Purpose
After this node the reviewer App's `request_changes` review at a bot PR's current head is rework the loop acts on,
just as it acts on the owner's review comments: the loop starts a feedback session for that PR with the review and its
inline comments in `FEEDBACK.md`. No other bot's item counts, and neither does a reviewer review at an older head or a
reviewer approval or comment. A waiting `QUESTION.md` still holds feedback as it does today. When the session pushes a
new head, S17's next pass reviews it again. The rounds are capped: after `SCHED_REVIEW_ROUNDS` (default 3) feedback
sessions on one PR started by the reviewer alone, its later `request_changes` reviews on that PR are not feedback and
the PR waits for the owner, whose own comment or review starts the rework again.

## Tests
- `scheduler/feedback-g13.test.sh` (new), on fixtures of a bot PR:
  - With `--reviewer LOGIN`, a `REQUEST_CHANGES` review by `LOGIN` whose head is the PR's current head is listed as
    feedback once, its body and each of its inline comments as items in `FEEDBACK.md` (kind, URL, author, body, and
    for a line comment its file, line and thread), and the acted-on record advances past it as for the owner's items.
  - A `REQUEST_CHANGES` review by `LOGIN` at an older head, an `APPROVED` or `COMMENTED` review by `LOGIN`, a reply by
    `LOGIN` in a thread, and any item by another bot (`n00dl3b0t` among them) are not feedback.
  - Without `--reviewer`, feedback is found exactly as before (the existing `feedback*.test.sh` cases pass unchanged).
  - The owner's PRs (not the bot's) get no feedback from the reviewer, as today for any item.
  - With `--rounds-max M`: a feedback set made only of the reviewer's items adds one to `feedback/<N>.rounds`; once the
    count is `M`, a new reviewer `REQUEST_CHANGES` at the current head is not listed, the acted-on record does not
    advance past it, and `feedback/<N>.held` names the PR's head and the count. A set holding an owner item is listed
    as before, with any reviewer items at the current head beside it, sets the count to 0 and removes `.held`.
    Without `--rounds-max` there is no cap.
- `scheduler/loop-g13.test.sh` (new), end to end with fakes, `~/.config/noodlebot/reviewer-login` in the fake home:
  a reviewer `REQUEST_CHANGES` at a bot PR's current head starts one feedback session for that PR; the same review
  once the PR's head has moved past it starts none; and a waiting `QUESTION.md` of the PR's unit holds the feedback
  until it is answered, as it holds the owner's.
- `scheduler/loop-g13-rounds.test.sh` (new), end to end with fakes and `SCHED_REVIEW_ROUNDS=2`: two reviewer
  `REQUEST_CHANGES` reviews at two successive heads start two feedback sessions, the third at the next head starts none
  and leaves `feedback/<N>.held`, an owner comment then starts one feedback session holding both the owner's comment
  and the reviewer's review, and the reviewer's next `REQUEST_CHANGES` at the head that session pushed starts one again.
  With `SCHED_REVIEW_ROUNDS` unset the cap is 3.

## Changes
1. **The reviewer's items.** `feedback.py --reviewer LOGIN` adds, to the owner's items, the reviews by `LOGIN` whose
   state is `CHANGES_REQUESTED` and whose `commit` is the PR's head, with that review's inline comments. An item's
   author must be `LOGIN` exactly and a bot. *G13-AC-1, G13-AC-2.*
2. **The loop passes the login.** When `~/.config/noodlebot/reviewer-login` exists, the feedback step passes its first
   line as `--reviewer`. Without the file nothing changes. *G13-AC-3.*
3. **The rounds cap.** `feedback.py --rounds-max M` counts, in `feedback/<N>.rounds`, the feedback sets of a PR made
   only of the reviewer's items, and leaves the reviewer's items out once the count is `M`, writing
   `feedback/<N>.held` (the head and the count) for U08. An owner item resets the count and removes the hold. The loop
   passes `SCHED_REVIEW_ROUNDS` (default 3) as `--rounds-max` along with `--reviewer`. *G13-AC-4, G13-AC-5.*

## Gate
- **G13-AC-1** — With `--reviewer LOGIN`, the reviewer's `REQUEST_CHANGES` review at a bot PR's current head and its inline comments are feedback, listed once in `FEEDBACK.md` with kind, URL, author and body (and file, line and thread for a line comment), and the record advances past them. *Verify:* `sh scheduler/feedback-g13.test.sh`.
- **G13-AC-2** — A reviewer review at an older head, a reviewer approval, comment or reply, and any other bot's item are not feedback, and without `--reviewer` the feedback found is as before. *Verify:* `sh scheduler/feedback-g13.test.sh`.
- **G13-AC-3** — End to end with fakes, a reviewer `REQUEST_CHANGES` at a bot PR's current head starts one feedback session for that PR, the same review after the head moved starts none, and a waiting `QUESTION.md` holds it as it holds the owner's feedback. *Verify:* `sh scheduler/loop-g13.test.sh`.
- **G13-AC-4** — With `--rounds-max M`, a feedback set of only the reviewer's items adds one to `feedback/<N>.rounds`; at `M` a further reviewer `REQUEST_CHANGES` is not listed, the record does not advance past it and `feedback/<N>.held` names the head and the count; a set holding an owner item is listed with the reviewer's items at the current head, resets the count and removes the hold; without `--rounds-max` nothing is capped. *Verify:* `sh scheduler/feedback-g13.test.sh`.
- **G13-AC-5** — End to end with fakes and `SCHED_REVIEW_ROUNDS=2`, two reviewer-started feedback sessions on one PR run, the third reviewer `REQUEST_CHANGES` starts none and leaves the hold, an owner comment then starts one feedback session holding the owner's comment and the reviewer's review, and the next reviewer `REQUEST_CHANGES` starts one again; unset, the cap is 3. *Verify:* `sh scheduler/loop-g13-rounds.test.sh`.

## Risks
- A reviewer that keeps requesting changes and feedback sessions that keep pushing could cycle on one PR and spend the
  plan's usage. The rounds cap bounds it at `SCHED_REVIEW_ROUNDS` reviewer-started sessions per PR between two owner
  items, and each round also needs a new head, a settled review and the throttle's leave.
- A held reviewer review is listed again only beside an owner item. If the owner wants the reviewer's findings acted
  on as they are, a short comment saying so is enough; U08 tells the owner the PR waits on them.
- A session that pushes a new head before the reviewer's review is read would make that review stale, and so not
  feedback. The next review at the new head carries any finding still outstanding.
- The feedback session resolves the line threads it fixed, the reviewer's among them (G03's prompt). The reviewer
  still checks them, because S16's `prior.json` takes every thread it started that it has not marked addressed,
  resolved or not.
- The login file is the owner's setup step. A wrong login means the reviewer's reviews are not feedback: the PR waits,
  nothing is acted on wrongly.
