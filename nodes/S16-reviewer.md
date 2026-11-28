# S16 — reviewer

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G12, S08, U05, U07 | S17 | L |

**Owns:** `scheduler/reviewer.py` (new: `candidates`, `prepare`, `draft`, `post`, the job folder, the regime checks and
the frozen-line count it makes, the review JSON's schema, the review's body, the record), its tests `scheduler/reviewer.test.sh`, `scheduler/reviewer-draft.test.sh` and
`scheduler/reviewer-post.test.sh` (new, each under the 30 s file budget) and their lines in the `Makefile`'s `TESTS`,
their fixtures under `scheduler/testdata/reviewer/`; the review session's prompt `scheduler/unattended-review.md` (new)
and `scheduler/unattended-review.test.sh` (new) with its line in the `Makefile`'s `TESTS`; in `scheduler/harness.py`,
the read-only start (`start --read-only`) and its line in the docstring; in the Claude Code backend
`scheduler/harnesses/claude_code.py`, the permissions of a read-only start; their cases in a new
`scheduler/harness-s16.test.sh` and its line in the `Makefile`'s `TESTS`.
**Resolves:** #259

## Purpose
After this node noodlebot can review one PR at one head with the reviewer App, the way spockbot reviews a GitLab merge
request. It reuses spockbot's design, not its code. `scheduler/reviewer.py` lists the PRs that are eligible for a
review: the owner's and the bot's, from a branch of the repository itself. For one PR it prepares a job folder of context and a detached worktree at the head. It validates the review
session's JSON review with a `draft` command, and it posts the review through G12's reviewer profile only if the PR is
still at the head that was reviewed. The session itself runs read-only and holds no forge credential. The verdict
follows the findings, the body's first line comes from code, and the owner's decisions (frozen-line approvals, scope,
money, deleting things, anything outward-facing) are never taken: such a PR gets a `COMMENT`, never an approval. S17
runs it from the loop.

## Tests
- `scheduler/reviewer.test.sh` (new), with the fake forge and a scratch repository:
  - `candidates` lists every open, non-draft PR whose head has no review by the reviewer's login at that head
    (`record.json` at `review/<N>/<sha>/`, or a review read back with that `commit`), and gives for each PR either
    `eligible` or the first thing it waits for. `draft PR`, `CI running` (a run at the head not completed), `settling`
    (the head first seen less than the settle time ago, `--settle`, default 600 s, kept in `review/<N>/seen`) and
    `session live` (a live `session.pid` in the PR's unit: `pr/<N>`, `node/<ID>` for a `node/<ID>-*` branch,
    `issue/<N>` for a `spec/triage-<N>-*` branch, `adopt/*` for a `spec/adopt*` branch) each wait. The owner's PRs and
    every kind of bot PR are listed alike.
  - Only a PR whose head branch is in the base repository (`fork` false) and whose author is the owner (`is_owner`,
    not a bot) or the bot (a bot author, as the loop tells its own PRs today) can be `eligible`. Any other PR, a
    fork's PR by the owner or the bot included, gets `outside author`, and `prepare` refuses it (exit 1, nothing
    fetched or run): a case lists a stranger's PR from a branch of the repository and a fork's PR by the owner, and
    both get `outside author`.
  - `prepare N` writes the job folder `review/<N>/<sha>/context/`: `pr.md` (title and body), `diff.patch` (head against
    its merge base with the base branch), `commits.txt`, `discussion.md` (every review, line comment and conversation
    comment so far, with author and head), `ci.json` (the runs and jobs at the head, with conclusions and the failing
    jobs' ids), `prior.json` and `checks.md`. `prior.json` holds every thread the reviewer started on the PR that no
    reply of `post`'s has marked addressed, resolved or not, with whether it is resolved and by whom: a case where
    another author (the feedback session) resolved one of the reviewer's threads finds it in `prior.json`. It also makes a detached worktree
    at the head under `$NOODLEBOT_DATA/worktrees/<name>/review-<N>`, fetched from `pr head-ref`.
  - `checks.md` holds each regime check with its command, exit code and output. The checkers are the deployed
    noodlebot's, `plugin/skills/node/` next to `reviewer.py` (the loop keeps that checkout on `main`), never the
    head's, and they run with every `NOODLEBOT_FORGE*` variable and every variable whose name holds `TOKEN` removed
    from their environment: a case seeds a head whose `plugin/skills/node/check-*.py` files write a marker file and print a
    marker line, and neither the file nor the line appears, while `checks.md` names the deployed checkers' paths. For a PR that changes only spec files
    (by `check-spec-diff.py`): `check-regime.py`, `check-coverage.py` and `check-spec-diff.py`, at the head and on the
    head merged onto the current base in a scratch worktree (a conflict is recorded as a failed check). For a
    `node/<ID>-*` PR: the RED commit and GREEN commits named, the last `Fresh review` and the head it names, and
    `check-owns-diff.py` when the graph has ownership. For every PR: closing keywords before an issue number in the
    body or in a commit message, the CI result, and the frozen-line count.
  - The frozen-line count is made in code: each `-` line of `diff.patch` in a file under the repository's frozen paths
    that exists at the merge base, each line once (U05's kind (a)). The frozen paths are the paths in backticks of the
    sentence that names `the frozen paths` in the "Building a node" section of `AGENTS.md` at the base branch (for
    noodlebot `*.test.sh` and `scheduler/testdata/`), never the head's copy. A PR that changes only spec files counts 0;
    for any other PR with no such sentence the count is `"unreadable"`. Cases: a head that changes one line and removes
    another of an existing `*.test.sh` counts 2, one that only adds a new test file counts 0, one that also changes the
    head's `AGENTS.md` sentence is counted with the base's, and a base `AGENTS.md` without the sentence gives
    `"unreadable"`.
  - The job folder, the worktree and the prompt `prepare` renders hold no forge credential and nothing from a node
    session's state folder (no `session.jsonl`, `events.jsonl`, `brief`, handoff or `QUESTION.md`): a case seeds a node
    unit with marker text and checks that none of it reaches the context.
- `scheduler/reviewer-draft.test.sh` (new): `draft <job> <file>` accepts a review JSON (`verdict`, `summary`,
  `findings` with `severity` blocker|major|minor|nit, `path`, `line`, `body`, `threads` with each earlier thread's id
  and `addressed|outstanding`, `frozen_lines_changed`, `owner_decision` with its reasons, `ci` with each failing job's
  check, run id, job id and reason) and writes it as `review.json`. It rejects, with exit 1 and a message naming each
  problem for the session to correct:
  - a verdict that does not follow the findings (`request_changes` exactly when there is a blocker or major finding or
    an outstanding earlier thread);
  - a finding with a `path` and `line` that is neither on a diff line nor marked outside the diff;
  - an earlier thread of `prior.json` without a status;
  - a failing CI job of `ci.json` named neither in `ci` nor in a blocker or major finding;
  - a failed check of `checks.md` with no blocker finding;
  - a `summary` or finding body holding a line that begins `Frozen lines approved`.
  - A failing CI job named in `ci` (judged unrelated to the PR) counts as one `minor` finding and nothing more: a review
    whose only failing jobs are named there, with no blocker or major finding and no outstanding thread, is accepted
    with the verdict `approve`, and the same review with `request_changes` is rejected. A `ci` entry without its
    check, run id, job id or reason, or one naming a job that is not failing in `ci.json`, is rejected.
- `scheduler/reviewer-post.test.sh` (new), with the fake forge under the reviewer profile:
  - `post N <sha>` reads the PR again. If its head is not `<sha>` or it is closed, nothing is posted and the record
    says `head moved` or `closed`.
  - Otherwise one review is posted at `<sha>`. Its event is `APPROVE` or `REQUEST_CHANGES` as the verdict says, or
    `COMMENT` when the count `checks.md` holds, the review's `frozen_lines_changed` or the PR's last `Fresh review`'s
    count (U05, U07) is above 0 or `"unreadable"` and the owner has no `Frozen lines approved at <sha>` comment at that
    head, or when `owner_decision` is not empty. A case where only the code's count is above 0 (the review says 0 and
    there is no `Fresh review`) gets the `COMMENT`. A head whose CI is red only from jobs the review names in `ci` gets the event the
    verdict says, `APPROVE` included, and the body gives one line per such job with its check, run id, job id and
    reason; nothing the reviewer posts asks for a re-run. Its inline comments are the findings on diff lines, and a finding outside the diff is
    a line of the body with a link to that line at `<sha>` (`repo url`).
  - The body's first line is written by code: exactly `Approved at <sha>.`, `Changes requested at <sha>.`, or, for a
    `COMMENT`, `Ready at <sha> apart from the owner's approval of its frozen test lines.` or `Needs the owner's decision
    at <sha>: <reasons>.`. A first line the session wrote is never the body's first line.
  - Earlier threads marked `addressed` get one reply naming `<sha>` and are resolved (a reply only, when another author
    already resolved it), `outstanding` ones stay open, an `outstanding` thread another author resolved is a line of
    the body with its link, and an earlier `REQUEST_CHANGES` review of the reviewer's is dismissed when the new review
    is a `COMMENT`.
  - `post N <sha> --no-verdict` posts one `COMMENT` review at `<sha>` whose first line is `No verdict at <sha>: the
    review session gave no valid review; this head is left to the owner.`, records it, and posts nothing when called
    again at that head.
  - `record.json` holds the verdict, the event and the review's state and head as read back with `pr reviews`. No body,
    comment or reply the reviewer posts holds a line beginning `Frozen lines approved`. Every write goes through the
    reviewer profile (the fake `gh` sees the reviewer's marker token on each call and no other).
- `scheduler/harness-s16.test.sh` (new): a read-only start of the Claude Code backend, as the fake `claude` records it,
  denies the edit tools, ref-changing git commands (`commit`, `push`, `merge`, `rebase`, `reset`, `checkout`,
  `switch`, `branch`, `tag`, `update-ref`, `fetch`), `gh`, `curl`, reading or running anything under
  `~/.config/noodlebot/` (the token scripts `token` and `reviewer-token` and the Claude credential `oauth-token`
  among them), and reading or running `scheduler/forge-cli.sh` and `scheduler/forge.py` of any checkout. Its
  environment holds no `GH_TOKEN`, no `NOODLEBOT_FORGE*` variable, no variable whose name holds `TOKEN`, `SECRET` or
  `PASSWORD`, and no `GIT_CONFIG*` variable, and the marker token is in neither its argv nor its prompt.
- `scheduler/unattended-review.test.sh` (new), on `scheduler/unattended-review.md`: the prompt points the session at
  the job folder, the repository's `SPEC.md`, `AGENTS.md`, graph and the node spec of a node PR. It says that the
  review is submitted only through `draft`, and it gives the regime the review is judged against (G05's spec-file rule,
  a node PR's RED commit before its GREEN commits and its criterion-to-evidence table, no closing keywords, green CI).
  It says the session runs RED and GREEN itself only where that is cheap, bounded as D18 says. A failing CI job judged
  unrelated to the PR is named in `ci` with its check, run and job ids and why it is timing-related, it is a `minor`
  finding (so it alone does not keep the verdict from `approve`), and the session never asks for a re-run. It answers no questions, and it marks a scope, money, deletion or outward-facing change
  `owner_decision`. Each case checks one statement within one sentence or one window of lines.

## Changes
1. **Eligibility.** `reviewer.py candidates --repo --state --settle` gives each open PR's state as the tests above
   say: only the owner's and the bot's PRs from a branch of the repository itself can be eligible. It writes only
   `review/<N>/seen` (the first time a head was seen). *S16-AC-1.*
2. **Preparation.** `reviewer.py prepare N` writes the job folder and the worktree. The regime checks run in code,
   with the deployed checkers and no forge variable, and their results and the frozen-line count go into `checks.md`
   for the session to judge. *S16-AC-2, S16-AC-3, S16-AC-6.*
3. **The read-only start.** `harness.py start --read-only` starts a session that may read and run commands but not
   edit, change refs, reach the forge or read or run the credentials and the forge CLI. The Claude Code backend maps it
   to its permission settings, and the session's environment is scrubbed as above. *S16-AC-3.*
4. **The prompt.** `scheduler/unattended-review.md`, rendered by `prepare`, names the job folder and the worktree and
   nothing else of the runtime root. *S16-AC-3, S16-AC-7.*
5. **`draft`.** It validates the review JSON against the job folder and writes `review.json` only when it is valid,
   printing what to correct otherwise. A failing CI job named in `ci` weighs as one `minor` finding. *S16-AC-4,
   S16-AC-9.*
6. **`post`.** It re-reads the PR, composes the review in code, posts it through the reviewer profile, answers and
   resolves the reviewer's own earlier threads, and writes `record.json` from the forge's answer. The jobs named in
   `ci` become body lines. The event is a `COMMENT` when any of the three frozen-line counts is above 0 or
   unreadable without the owner's approval at the head. *S16-AC-5, S16-AC-6, S16-AC-9.*
7. **No verdict.** `post --no-verdict` posts the one note S17 asks for after the second failed attempt at a head.
   *S16-AC-8.*

## Gate
- **S16-AC-1** — `reviewer.py candidates` lists an open, non-draft PR at a head with no reviewer review as `eligible` once the head is settled and CI at it has finished, and gives `draft PR`, `settling`, `CI running` or `session live` (a live session on the PR's unit) for each such case; a PR the reviewer has reviewed at its head is not listed; the owner's PRs are listed like the bot's; a PR from a fork, or by an author who is neither the owner nor the bot, gets `outside author` and is never eligible, and `prepare` refuses it with nothing fetched or run. *Verify:* `sh scheduler/reviewer.test.sh`.
- **S16-AC-2** — `reviewer.py prepare N` writes `pr.md`, `diff.patch`, `commits.txt`, `discussion.md`, `ci.json`, `prior.json` (every thread the reviewer started that `post` has not marked addressed, resolved or not) and `checks.md` under `review/<N>/<sha>/context/` and a detached worktree at the head; the checkers it runs are the deployed noodlebot's `plugin/skills/node/` copies, never the head's (a head with changed `check-*.py` files that leave a marker leaves none), with no `NOODLEBOT_FORGE*` or `*TOKEN*` variable in their environment; and `checks.md` records the spec checkers at the head and merged onto the base for a spec-only PR, the RED and GREEN commits, the head of the last `Fresh review` and `check-owns-diff.py` (with ownership) for a node PR, and closing keywords, the CI result and the frozen-line count made in code (the `-` lines of existing files under the frozen paths named by the base's `AGENTS.md`, or `"unreadable"` without them) for every PR. *Verify:* `sh scheduler/reviewer.test.sh`.
- **S16-AC-3** — The review session's environment, argv and prompt hold no forge credential (a marker token reaches none of them, and no `GH_TOKEN`, `NOODLEBOT_FORGE*`, `*TOKEN*`, `*SECRET*`, `*PASSWORD*` or `GIT_CONFIG*` variable is set), its read-only start denies edits, ref-changing git commands, `gh`, `curl`, reading or running anything under `~/.config/noodlebot/` (`token`, `reviewer-token` and `oauth-token` among them) and reading or running `scheduler/forge-cli.sh` and `scheduler/forge.py` of any checkout, and its context and prompt hold nothing from a node session's state folder. *Verify:* `sh scheduler/harness-s16.test.sh` and `sh scheduler/reviewer.test.sh`.
- **S16-AC-4** — `draft` writes `review.json` only for a valid review and rejects with a message naming each problem a verdict that does not follow the findings, an anchor neither on a diff line nor marked outside the diff, an earlier thread without a status, a failing CI job not named, a failed check without a blocker and a line beginning `Frozen lines approved`. *Verify:* `sh scheduler/reviewer-draft.test.sh`.
- **S16-AC-5** — `post` posts nothing when the PR's head moved or the PR closed; otherwise it posts one review at the reviewed head with the findings on diff lines inline and the others as body lines linked at that head, whose first line is written by code (`Approved at <sha>.` or `Changes requested at <sha>.`), replies to and resolves the reviewer's earlier threads marked addressed (only replying where another author resolved one) and gives an outstanding one another author resolved as a linked body line, and writes `record.json` with the state and head read back from the forge, every write going through the reviewer profile. *Verify:* `sh scheduler/reviewer-post.test.sh`.
- **S16-AC-6** — A PR whose frozen test lines change at the head (the count `prepare` made in code, the review's count, or the last `Fresh review`'s count, any of them above 0 or `"unreadable"`; a case with only the code's count above 0 included) without the owner's `Frozen lines approved at <sha>` comment at that head, or whose review names an owner decision, gets a `COMMENT` review whose first line says so, never an approval, the reviewer's earlier `REQUEST_CHANGES` review is dismissed, and nothing the reviewer posts holds a line beginning `Frozen lines approved`. *Verify:* `sh scheduler/reviewer-post.test.sh`.
- **S16-AC-7** — `scheduler/unattended-review.md` points the session at the job folder and the repository's own regime, submits only through `draft`, runs RED and GREEN only where cheap and bounded, names an unrelated failing CI job with its check, run and job ids and why it is timing-related without asking for a re-run, answers no questions and marks scope, money, deletion and outward-facing changes as the owner's decision. *Verify:* `sh scheduler/unattended-review.test.sh`.
- **S16-AC-8** — `post N <sha> --no-verdict` posts one `COMMENT` review at `<sha>` whose first line is the no-verdict line written by code, records it, and a second call at that head posts nothing. *Verify:* `sh scheduler/reviewer-post.test.sh`.
- **S16-AC-9** — A failing CI job the review names in `ci` (judged unrelated to the PR) is one `minor` finding: `draft` accepts `approve` for a review whose only failing jobs are named there and that has no blocker, major or outstanding thread, rejects `request_changes` for it and rejects a `ci` entry lacking its check, run id, job id or reason or naming a job that is not failing; `post` then posts `APPROVE` at the red head with one body line per such job giving its check, run id, job id and reason, and nothing the reviewer posts asks for a re-run. *Verify:* `sh scheduler/reviewer-draft.test.sh` and `sh scheduler/reviewer-post.test.sh`.

## Risks
- The settle time is measured from the first time a pass saw the head, not from the push, so a loop restart can
  delay a review by up to one settle time. That errs toward waiting.
- `checks.md` runs the deployed noodlebot's checkers, never the head's, so a PR that changes a checker is judged by
  `main`'s version, and its new version is judged only once merged. An adopted repository's heads hold no checker, so
  this is also the only way its PRs get checked.
- The harness's deny list is the only barrier between the review session and the token scripts: the session runs as
  the loop's user, `~/.config/noodlebot/token` prints n00dl3b0t's token to whoever runs it, and `forge-cli.sh` uses it
  by itself when no token script variable is set. Code the session runs (the PR's tests in RED and GREEN, an
  interpreter) is not bound by the deny list. What keeps a stranger's code away from the token is that only the
  owner's and the bot's PRs from the repository itself are ever reviewed. Reviewing anyone else's PR would need the
  session isolated by the operating system (another user or a container with no access to `~/.config/noodlebot/`),
  which is a separate decision of the owner's.
- An approval at a red head rests on the session's judgement that the failure is unrelated. The body names each such
  job with its ids and reason, so the owner sees it before merging, and the auto-gate (issue #175) never treats a red
  CI as green: a flake leaves the PR waiting there, and filing the flake issue is issue #275's.
- The frozen-line count in code sees only U05's kind (a), the lines that existed at the merge base. A change to lines
  the node's own RED commit added (kind (b)) is seen only by the review session's count and, for a node PR, by its
  `Fresh review`'s. Either of them above 0 still gives a `COMMENT`. The frozen paths come from the base's `AGENTS.md`
  sentence; a repository whose sentence names too few paths gets too low a count.
- spockbot's design was written for GitLab merge requests. GitHub's review states differ: a `COMMENT` leaves an
  earlier `CHANGES_REQUESTED` standing, which is why change 6 dismisses it.
