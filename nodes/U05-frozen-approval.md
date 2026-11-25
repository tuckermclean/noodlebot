# U05 — frozen-approval

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G03, G07, U04 | S16, U07 | M |

**Owns:** in `plugin/skills/node/SKILL.md`, the frozen-line record of the final review (step 6: the `Frozen test lines changed:` line, the list of those lines and the approval line it names); in `scheduler/report.py`, the frozen-line fields of each open node PR's merge record in `report.json` (the frozen-line count of its last `Fresh review`, the head of the owner's last approval comment) and the frozen-line wording of a ready PR's "Waiting on you" item; in `scheduler/site.py`, the frozen-line note in a ready node's `merge_why`; in `scheduler/feedback.py`, leaving out the owner's approval comment; the new tests `plugin/skills/node/skill-u05.test.sh`, `scheduler/report-u05.test.sh`, `scheduler/site-u05.test.sh` and `scheduler/feedback-u05.test.sh`, their lines in the `Makefile`'s `TESTS`, and any fixtures they add under `scheduler/testdata/u05/`.
**Resolves:** #198

## Purpose
After this node a node PR that changes frozen test lines no longer reads as plainly "ready to merge". The final review on the PR records how many frozen test lines the PR changes and lists them. The owner approves them with their own comment on the PR, whose first line is `Frozen lines approved at <sha>`. Until that approval names the PR's current head, the status issue says `PR #N changes frozen test lines: needs your approval`, and the site's `merge_why` says the same. After the approval, both say the PR is ready to merge with its frozen test line changes approved. The owner's approval comment is not taken as feedback that starts a session.

## Tests
- `plugin/skills/node/skill-u05.test.sh` (new): checks of the text of `plugin/skills/node/SKILL.md` (step 6's final review and the push after the final review), each check named after its criterion (change 1). It reads the file as it is. It checks, each on its own:
  - the `Frozen test lines changed:` line in the first final review and in the new final review after a push;
  - kind (a): the lines that existed at the merge base, from `git diff <merge-base>..<head>`;
  - kind (b): the lines a RED or pin commit of this node added and a later commit of the node changes or removes, from the non-merge commits of the first-parent history;
  - that changes brought in by merging the base branch do not count under (b), and that each line counts once;
  - that each listed line gives its path, its line number and the commit that number refers to (the merge base, or the RED or pin commit that added it);
  - the owner's approval comment with first line `Frozen lines approved at <head>`, and the reviewer's check against the diffs;
  - that the skill names no repository.

  Each check fails when its clause is removed from the text or reversed.
- `scheduler/report-u05.test.sh` (new), with the fake forge and the state folder that `scheduler/report-u04.test.sh` uses, and one node with its open PR that U04 makes ready (an approving final review at the head, CI passed, no session, no question). Cases:
  - the final review says `Frozen test lines changed: none`, and the item is U04's ready item;
  - the review says `Frozen test lines changed: 2` and lists the lines, and the item says the PR needs the owner's approval;
  - the owner's approval comment names the head, and the item says ready to merge with the changes approved;
  - the approval names a shorter prefix of the head (seven characters), and it counts;
  - the approval names an earlier head, followed by a pushed commit and a new final review at the new head, and the item says the PR needs approval again;
  - a comment with the same first line from another user, from the bot, or from the owner's login without the forge's owner mark, and none of them counts;
  - the same first line quoted (`> Frozen lines approved at …`), or followed by more text on that line, and it does not count;
  - an approval comment with the owner's words after its first line, and it counts;
  - a review with no `Frozen test lines changed:` line, and the item is U04's ready item;
  - a frozen-line PR that is not ready (CI failed), and the item is U04's "still being worked on" item;
  - `mergeable` `UNKNOWN` together with a frozen-line note, and the item carries both notes;
  - the record in `report.json` is kept across a run that reads no new comment.
- `scheduler/site-u05.test.sh` (new): a runtime root built in a scratch folder from copies of `scheduler/testdata/site/` and the cases' `report.json` records, run through `site.py build`. It checks the `merge_ready` and `merge_why` of a ready node for each frozen-line case of AC-4, and the output against `scheduler/site-schema.json`.
- `scheduler/feedback-u05.test.sh` (new), over G03's fake `gh api` and fixtures `scheduler/testdata/feedback/`. Cases:
  - the owner's approval comment on a bot's node PR, alone, prints nothing;
  - the same comment with the owner's words after its first line prints nothing;
  - an owner comment whose first line has more text after the sha prints;
  - an owner comment that has the approval line below its first line prints;
  - an approval comment followed by an ordinary owner comment prints the PR with only the ordinary comment in `FEEDBACK.md`.
- The existing `scheduler/report*.test.sh`, `scheduler/site*.test.sh`, `scheduler/feedback*.test.sh`, `site/test/*.test.mjs`, `plugin/skills/node/skill.test.sh` and `plugin/skills/node/skill-g07.test.sh` pass unchanged. U04's fixtures have no `Frozen test lines changed:` line, so its ready PRs keep a `null` `merge_why`.

## Changes
1. **The final review records the frozen lines.** Every final review in step 6 of `plugin/skills/node/SKILL.md`, the first one and the new one after a push, carries a line of its own: `Frozen test lines changed: none` or `Frozen test lines changed: <n>`.
   - `<n>` counts the lines of the repository's frozen test and fixture paths that the node changes or removes, each line once. Two kinds count:
     - (a) a line that existed at the merge base of the reviewed head and the PR's base branch, and that the PR changes or removes: a `-` line of `git diff <merge-base>..<head> -- <frozen paths>`;
     - (b) a line that a RED commit (`test(<ID>): …`) or pin commit (`pin(<ID>): …`) of this node added, and that a later commit of the node changes or removes. The node's commits are the non-merge commits of the branch's first-parent history, `git rev-list --first-parent --no-merges <merge-base>..<head>`. For each such commit, a `-` line of `git diff <commit>^..<commit> -- <frozen paths>` counts when `git blame` at `<commit>^` gives it to a RED or pin commit of this node.
   - The node skill freezes the lines of the node's own RED and pin commits too (step 2's RED checks, its pins and step 3's `git diff <first-red>..HEAD` check). A test file a RED commit added does not exist at the merge base, so diff (a) shows it as wholly added and cannot see such a change; (b) does.
   - Changes brought in by merging the base branch are not the node's own and do not count under (b): merge commits are left out, so `main`'s test changes after a merge are not counted. A line of kind (a) is not counted again under (b), because `git blame` gives it to a commit older than the node.
   - When `<n>` is 1 or more, the line is followed by those lines, each given as its path, its line number and the commit that number refers to: the merge base for (a), and for (b) the RED or pin commit that added the line (the line number `git blame` gives at that commit). Then comes the sentence that the PR needs the owner's approval: a comment by the owner on the PR whose first line is `Frozen lines approved at <head>`.
   - The reviewer checks the line and the list against those diffs.

   The node skill's step 7 rule stays: the owner approves a frozen line change before it is made. The new record is what the status reads at merge time. *U05-AC-1.*
2. **The merge record.** `report.py` adds two fields to U04's merge record of each open node PR in `report.json`, kept across runs that read no new comment as U04's fields are:
   - `frozen`: from the last `Fresh review` comment. It is `"none"`, or the number `<n>` (1 or more) of its `Frozen test lines changed:` line, or `null` when that comment has no such line or there is no review.
   - `approved`: the `<sha>` of the owner's last approval comment on the PR, or `null` when there is none.

   A null field is left out of the record.

   An approval comment is a conversation comment that passes `report.py`'s test of the owner's comments: the owner's login, not a bot, marked as the owner by the forge (`is_owner`). Its first line, without surrounding whitespace, must be exactly `Frozen lines approved at <sha>`, where `<sha>` is 7 to 40 hex characters. Any text after the first line is accepted, because the owner's agent may post the comment from the owner's account, quoting the owner's words below it. Anything else on the first line, a quote mark before it, or another author makes it no approval. *U05-AC-2.*
3. **The ready item.** For a node's open PR that U04 makes ready (U04-AC-2), whose `frozen` is a number, and whose current head does not start with `approved`, the "Waiting on you" item reads `<ID>'s PR #N changes frozen test lines: needs your approval (reviewed at <sha>, CI passed)`. When the head starts with `approved`, the item reads `<ID>'s PR #N is ready to merge (frozen test line changes approved; reviewed at <sha>, CI passed)`. U04's note that the forge has not said whether the PR merges cleanly follows when it applies. Any other ready PR (`frozen` `"none"` or `null`), and every PR that is not ready, gets U04's item unchanged. *U05-AC-3.*
4. **The site.** `site.py build` keeps U04's `merge_ready` for every node. A ready `pr-open` node whose merge record has a number in `frozen` gets a different `merge_why`:
   - `changes frozen test lines: needs your approval`, when the PR's head in `open-prs.tsv` does not start with the record's `approved`;
   - `frozen test line changes approved`, when it does.

   U04's note that the forge has not said whether the PR merges cleanly follows the frozen-line note after `; ` when it applies. `site/views.js` is unchanged: it shows a ready node's `merge_why` as the note after "ready to merge". *U05-AC-4.*
5. **Not feedback.** `feedback.py` does not take the owner's approval comment (a conversation comment whose first line is an approval line by change 2's rule, whatever follows) as feedback. It does not print the PR for it and does not put it in `FEEDBACK.md`, as it already leaves out a comment that is only 👍. An owner comment whose first line is anything else is feedback as before. *U05-AC-5.*

## Gate
- **U05-AC-1** — Step 6 of `plugin/skills/node/SKILL.md` says that every final review posted as `Fresh review (<verdict>) at <sha>`, including the new final review after a push, carries a line `Frozen test lines changed: none` or `Frozen test lines changed: <n>`, where `<n>` counts each line once over the repository's frozen test and fixture paths, of two kinds: (a) the `-` lines of `git diff <merge-base>..<head>`, lines that existed at the merge base and that the PR changes or removes; and (b) lines that a RED or pin commit of this node added and that a later commit of the node (a non-merge commit of the branch's first-parent history after the merge base) changes or removes, with changes brought in by merging the base branch not counted; when `<n>` is 1 or more, each of those lines follows with its path, its line number and the commit that number refers to (the merge base for (a), the RED or pin commit that added it for (b)), and then that the PR needs the owner's approval as an owner comment whose first line is `Frozen lines approved at <head>`; and that the reviewer checks the line against those diffs. The skill names no repository, and `plugin/skills/node/skill.test.sh` and `plugin/skills/node/skill-g07.test.sh` pass unchanged. *Verify:* `plugin/skills/node/skill-u05.test.sh`; `plugin/skills/node/skill.test.sh` and `plugin/skills/node/skill-g07.test.sh` in the PR's CI run.
- **U05-AC-2** — For each open node PR, `report.py` keeps in its `report.json` merge record `frozen` (`"none"`, the count `<n>` of the last `Fresh review`'s `Frozen test lines changed:` line, or `null` when that review has no such line or there is no review) and `approved` (the `<sha>` of the last conversation comment by the owner, as `report.py` tests owner comments, whose first line without surrounding whitespace is exactly `Frozen lines approved at <sha>` with 7 to 40 hex characters, any text after the first line accepted; else `null`), kept across runs that read no new comment; a comment with that first line from another user, the bot or an author the forge does not mark as the owner, quoted, or with more text on the first line is no approval. *Verify:* `scheduler/report-u05.test.sh`.
- **U05-AC-3** — A node's PR that U04-AC-2 makes ready and whose `frozen` is a number reads `<ID>'s PR #N changes frozen test lines: needs your approval (reviewed at <sha>, CI passed)` in "Waiting on you" until its current head starts with `approved`, then `<ID>'s PR #N is ready to merge (frozen test line changes approved; reviewed at <sha>, CI passed)`; an approval naming an earlier head does not count after a push; U04's forge-unknown note still follows when it applies; a ready PR whose `frozen` is `"none"` or `null`, and a PR that is not ready, read as under U04, and `scheduler/report-u04.test.sh` passes unchanged. *Verify:* `scheduler/report-u05.test.sh`; `scheduler/report-u04.test.sh` in the PR's CI run.
- **U05-AC-4** — `site.py build` gives a `pr-open` node U04's `merge_ready`; a ready node whose merge record's `frozen` is a number has `merge_why` `changes frozen test lines: needs your approval` while its head in `open-prs.tsv` does not start with the record's `approved`, and `frozen test line changes approved` once it does, followed by `; ` and U04's forge-unknown note when that applies; every other node's `merge_why` is U04's; the output passes `scheduler/site-schema.json`, and `scheduler/site-u04.test.sh` and `site/test/views-u04.test.mjs` pass unchanged. *Verify:* `scheduler/site-u05.test.sh`; `scheduler/site-u04.test.sh` and `site/site.test.sh` in the PR's CI run.
- **U05-AC-5** — `feedback.py` prints no PR and writes nothing to `FEEDBACK.md` for an owner conversation comment whose first line is an approval line by U05-AC-2's rule, whatever follows it; an owner comment whose first line is anything else (more text after the sha, or the approval line only below the first line) is feedback as before, and an approval comment followed by an ordinary owner comment prints the PR with only the ordinary comment; `scheduler/feedback.test.sh` and `scheduler/feedback-g06.test.sh` pass unchanged. *Verify:* `scheduler/feedback-u05.test.sh`; `scheduler/feedback.test.sh` and `scheduler/feedback-g06.test.sh` in the PR's CI run.

## Risks
- A final review with no `Frozen test lines changed:` line (one posted before this node, or one whose session left the line out) reads as U04 makes it: plainly ready. The reviewer checks the line, and the count is only as right as the session's two counts, (a) over the merge base and (b) over the node's own RED and pin commits, and that check. Kind (b) finds the node's RED and pin commits by their `test(<ID>):` and `pin(<ID>):` subjects, which step 2 of the node skill requires.
- A line of this node's own RED or pin commits changed inside a merge commit's conflict resolution is not counted under (b), which leaves merge commits out. The node skill's resolution review checks that a resolution changes, removes or renames no frozen test line.
- The owner approves a frozen line change twice, by design. At step 7 of the node skill the owner has already approved the change before it was made, recorded in the answer. The approval comment records that approval on the PR for the exact head the status reads, so the owner, or their agent quoting them, posts it at merge time.
- An approval names one head. Any push after it (a CI fix, an update merging `main`) needs a new approval comment, as it already needs a new final review.
- Only a comment on the PR itself counts. An approval given on the issue, in a question's answer or in another channel counts once it is posted on the PR from the owner's account. The owner's agent may post it there, quoting the owner's words below the first line.
- U04-AC-3's "any other ready node has `merge_why` null" no longer holds for a ready node whose review counts frozen lines. U04's frozen tests have no such case.
- The status issue and the site are as fresh as their last run (U04's risk), so an approval shows at the next report run and the next publish.
- The API (`scheduler/api.py`, P01) and `nbctl` show none of this, as they show none of U04's ready state.
