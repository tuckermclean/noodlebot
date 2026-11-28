# G15 — auto-gate

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G14, G12, S17, A05, L01 | U09 | L |

**Owns:** `scheduler/autogate.py` (new: `check`, `pass`, the five points, the window, the gate's records under
`$NOODLEBOT_DATA/state/<name>/gate/`, reading the protected-path list); its tests `scheduler/autogate.test.sh` and
`scheduler/autogate-act.test.sh` (new, each under the 30 s file budget) and their lines in the `Makefile`'s `TESTS`, their
fixtures under `scheduler/testdata/autogate/`; in `scheduler/loop.sh`, the gate pass in the tick (after the review
pass), its status-log lines and its lines in the header comment; `scheduler/loop-g15.test.sh` (new) and its line in the
`Makefile`'s `TESTS`; in `scheduler/labels.py`, the `hold` label, and its case in a new `scheduler/labels-g15.test.sh`
with its line in the `Makefile`'s `TESTS`; this repository's protected-path list `.noodlebot/protected-paths` (new);
in `README.md`, a section "Auto-merge of node PRs" (the owner's setup steps, the five points, the window, `hold` and
the protected-path list) and the "Until the auto-gate is built" line of "Reviewing and merging PRs";
`scheduler/readme-g15.test.sh` (new) and its line in the `Makefile`'s `TESTS`; the recorded run of G15-AC-11 in the node
PR.
**Resolves:** #175

## Purpose
After this node a node PR merges without the owner once the auto-gate holds at its head, so the loop no longer sits
idle with PRs that wait only for a merge. The forge merges it, by its own squash auto-merge under the branch protection
the owner sets; the loop only turns auto-merge on, and marks the head with the required `noodlebot/auto-gate` status
once five points hold there: (1) the reviewer App (G12, S17) approved that head; (2) every check at that head passed,
never re-run; (3) no frozen test or fixture line changed unless the owner's U05 approval names the head, the
ownership check is clean and no spec file changed; (4) no protected path changed; (5) 30 minutes passed after the
approval with no owner comment or changes-requested review and no `hold` label. Anything else leaves the PR for the
owner. Spec and adoption PRs are never gated: they stay the owner's to merge.

## Tests
- `scheduler/autogate.test.sh` (new), `autogate.py check N` against the fake forge (G14's world) and a scratch clone,
  with a fixed clock (`NOODLEBOT_NOW`), one case per point and kind, each printing the PR's head, each point's
  `holds` and, for a point that does not hold, a `why` naming the cause:
  - **A passing PR.** A bot PR from `node/X01-thing` (and one from `node/X01-followup-1`) to the default branch, not a
    draft, whose head has the reviewer's `APPROVED` review, passed checks and no frozen, spec or protected change,
    holds points 1–4, and point 5 holds only from 30 minutes (`SCHED_AUTOGATE_WINDOW`, default 1800 s) after the
    approval's time: a clock one second before gives `window` with the end time.
  - **Point 1.** No reviewer review at the head; a reviewer `APPROVED` at an earlier head only; a reviewer
    `CHANGES_REQUESTED` or `COMMENTED` after its approval at the head; a dismissed approval; and an `APPROVED` at the
    head by another login (the owner, another bot) each fail point 1. The reviewer's login is the one G12 keeps.
  - **Point 2.** A failed, cancelled or timed-out check run at the head, a check still running, a failed or pending
    commit status other than `noodlebot/auto-gate`, and a head with no check at all each fail point 2; a failed check
    with the reviewer's approval at that red head (S16-AC-9) still fails it, and nothing is re-run (the fake forge
    recorded no `ci rerun`).
  - **Point 3.** A changed or removed line of an existing frozen test file or fixture (the frozen paths as S16 reads
    them from the base's `AGENTS.md`, counted by S16's code), and a last `Fresh review` counting frozen lines, each fail
    point 3 until the owner's comment `Frozen lines approved at <head>` (U05's rule) is there, and still fail with that
    approval at an earlier head; an approval by another user fails it; a merged spec's approval is no way through. A
    `check-owns-diff.py` run (the deployed copy) that exits 1 or 2 fails it, a graph without ownership passes it, and
    any changed path that is a spec file (the **Spec files:** line of the base's `AGENTS.md`, as
    `check-spec-diff.py` reads it), a node spec's Verify path among them, fails it.
  - **Point 4.** A path matched by a glob of `.noodlebot/protected-paths` at the base branch's tip (one root-relative
    glob a line in `owns.match`'s form, blank and `#` lines skipped), the old path of a rename into an unprotected
    path, and each always-protected path (`.noodlebot/**`, `.github/**`, `AGENTS.md`, `CLAUDE.md`) with no list file
    each fail point 4 naming the path and the glob; a list changed at the PR's head (more globs, or none) changes
    nothing, as the list is read at the base's tip; an unreadable list and a `pr files` answer with `complete` false
    fail it.
  - **Point 5.** An owner conversation comment, review or line comment after the approval at this head, the owner's
    last review being `CHANGES_REQUESTED`, a `hold` label, a live session or a `QUESTION.md` in the PR's unit (`pr/<N>`)
    or its node's (`node/<ID>`), and a PR the forge reports as conflicting each fail point 5; the owner's U05 approval
    comment does not; an owner comment before the approval does not; `hold` removed (from `issue events`) while no
    owner item came after the approval restarts the window from the removal; a new head starts over (a new approval
    and a new window).
  - **Not gated.** A `spec/triage-*`, `spec/adopt*` or other `spec/*` PR, a PR by the owner or another user, a PR from
    a fork, a draft, a PR to another base and a `node/` branch naming no node of the base's graph each print `not
    gated` with the reason, whatever its reviews and checks.
- `scheduler/autogate-act.test.sh` (new), `autogate.py pass` against the fake forge, which records every call:
  - A PR whose five points hold gets, in this order, one `pr auto-merge` with its head, a `pr view` reading auto-merge
    back as squash, and one `commit status` `noodlebot/auto-gate` `success` on that exact head; a second pass makes
    no further call; one pass at a clock before the window's end makes none of them.
  - When the base branch's rules do not require `noodlebot/auto-gate`, require it from any source or from another App
    than the bot's, or the repository does not allow squash auto-merge, or `branch protection` gives `"unknown"` for
    any of these, the pass turns nothing on, sets no status and records the gate as off with the reason; the same when
    the reviewer App's token script or login file is missing, recorded without a log line.
  - A refused `pr auto-merge` (clean status, another head) sets no status and is recorded; the next pass tries again
    only while the five points still hold at the same head.
  - A PR with auto-merge on, or with its status `success`, that then gets an owner comment, a `CHANGES_REQUESTED`
    review or `hold`, or a new head, gets `pr auto-merge-off` and, at the head it marked, the status `failure` with the
    reason as its description; a merged PR gets no call.
  - A spec PR and an adoption PR that would hold all five points get no auto-merge call and no status, and no call
    in the pass sets a status on any PR the gate does not gate.
  - The records rebuilt by a pass with an empty `gate/` folder (a restarted loop) give the same state from the forge's
    reviews, labels, events, statuses and auto-merge alone.
  - A test with a node state folder holding a `session.jsonl`, handoff files and a `brief.md` with a unique marker
    shows that the job folder `reviewer.py prepare` writes for that node's PR, and the review session's prompt, hold
    none of the marker.
- `scheduler/loop-g15.test.sh` (new), the loop end to end with the fake forge and the fake reviewer setup: a node PR
  that passes gets auto-merge and the status only after the window, the fake forge then merges it, and the status log
  has one line for the window's start, one for the auto-merge and none for repeated passes; an owner comment in the
  window leaves it unmerged, starts a feedback session as today, and logs one line; a spec PR is never merged. Without
  the reviewer's token script and login, the loop's status log and calls are as before (existing loop tests pass
  unchanged).
- `scheduler/labels-g15.test.sh` (new): `labels.py ensure` creates `hold` with a colour and a description and leaves
  an existing `hold` as it is; `scheduler/labels.test.sh` passes unchanged.
- `scheduler/readme-g15.test.sh` (new): the README's "Auto-merge of node PRs" section names each setup step (see
  change 6), the five points, the window and its variable, `hold` and `.noodlebot/protected-paths`, and "Reviewing and
  merging PRs" no longer says the owner merges node PRs until the auto-gate is built.
- The recorded run of G15-AC-11.

## Changes
1. **`autogate.py check N`.** It reads the PR (`pr view` with G14's `auto_merge` and `labels`), the reviews, comments,
   line comments and label events, the checks and statuses at the head, the base's rules, and the changed files
   (`pr files`), and judges the five points as the Tests section says, with the loop's clone fetched at the base's tip
   and the head (G12's `pr head-ref`). Points 3 and 4 read `AGENTS.md`, the graph and `.noodlebot/protected-paths` at the
   base's tip, never at the head. The checkers it runs are the deployed noodlebot's `plugin/skills/node/` copies, as
   S16 runs them, with no forge variable. It prints one JSON object: the head, each point's `holds` and `why`, the
   window's start and end, and the state (`not gated`, `off`, `waiting`, `window`, `holds`, `auto-merge on`,
   `merged`). *G15-AC-1 to G15-AC-6.*
2. **`autogate.py pass`.** For each open PR it gates: when the five points hold, it turns squash auto-merge on for the
   head (`pr auto-merge --head`), reads it back, and only then sets `noodlebot/auto-gate` to `success` on that sha,
   with a description naming the head and the window's end. The PR is still blocked by the missing required status
   when auto-merge is turned on, so the forge accepts the call, and the forge merges once the status is set. When a
   PR with auto-merge on or its status set stops holding before the merge, the pass turns auto-merge off and sets the
   status to `failure` with the reason. It never merges, approves, re-runs CI or changes a setting. Its record per PR
   (`gate/<N>/record.json`: the head, the points, the window, each call and its result) is rebuilt from the forge
   when missing. *G15-AC-7, G15-AC-8, G15-AC-9.*
3. **The gate is off** unless the reviewer App is set up (its token script and login file, as S17 needs them), the
   base branch's rules require `noodlebot/auto-gate` set by the bot's own App, and the repository allows squash
   auto-merge. Off, the pass sets nothing and turns nothing on; the reason is recorded, and logged once a loop start
   when the reviewer App is set up. *G15-AC-8.*
4. **The loop.** Each tick runs `autogate.py pass` after the review pass, and logs one status-log line per change of a
   PR's state (window started with its end, auto-merge on, held with the reason, auto-merge turned off), not one per
   pass. A failed pass is logged and the tick carries on (SPEC §1.2). Feedback on an owner comment is G03's as today.
   *G15-AC-10.*
5. **`hold`.** `labels.py ensure` adds `hold` ("The auto-gate leaves this PR to the owner") to the labels the loop
   makes sure exist. *G15-AC-6.*
6. **The protected paths and the README.** `.noodlebot/protected-paths` lists `scheduler/loop.sh`, `scheduler/loops.sh`,
   `scheduler/deploy.sh`, `scheduler/run-session.sh`, `scheduler/usage.py`, `plugin/hooks/**`, `.github/**`,
   `scheduler/testdata/lib/**`, `AGENTS.md`, `scheduler/autogate.py` and `scheduler/reviewer.py`. The README's
   "Auto-merge of node PRs" section gives the owner's setup steps: grant the n00dl3b0t App "Commit statuses: Read and
   write"; turn on "Allow auto-merge" and squash merging in the repository's settings; a ruleset on `main` that
   requires a PR with one approving review, dismisses stale approvals when new commits are pushed, requires the status
   checks `test` and `noodlebot/auto-gate` with `noodlebot/auto-gate`'s source set to the n00dl3b0t App, and keeps the
   repository admin role as a bypass actor so the owner merges spec, adoption and their own PRs. It names the five
   points, the window and `SCHED_AUTOGATE_WINDOW`, `hold`, and the protected-path list and the always-protected paths.
   The "Until the auto-gate is built" line becomes: node PRs merge by themselves once the auto-gate holds, and any PR
   it leaves to the owner is the owner's to merge. *G15-AC-6, G15-AC-12.*
7. **The live record.** On this repository, after the owner applied the setup steps: one node PR (G15's own needs the
   owner, since it changes protected paths; the first node PR after it is the record) shown by `autogate.py check` in
   each state, its auto-merge turned on after the window and merged by GitHub, with the commands and outputs in the
   PR, or, if no node PR reaches the end of its window while G15's PR is open, the `check` outputs of the open node PRs
   with the reason each waits. *G15-AC-11.*

## Gate
- **G15-AC-1** — `autogate.py check N` gates only an open, non-draft PR by the bot from a `node/<ID>-<name>` or `node/<ID>-followup-<n>` branch of the base repository to the default branch naming a node of the base's graph; every other PR (`spec/*`, `spec/adopt*`, the owner's or another user's, a fork's, a draft, another base, an unknown node) prints `not gated` with the reason. *Verify:* `sh scheduler/autogate.test.sh`.
- **G15-AC-2** — Point 1 holds only when the reviewer App's login has an `APPROVED`, undismissed review whose commit is the PR's head and no later review of its own at that head; an approval at an earlier head, a later `CHANGES_REQUESTED` or `COMMENTED`, a dismissed approval and another login's approval each fail it with a `why`. *Verify:* `sh scheduler/autogate.test.sh`.
- **G15-AC-3** — Point 2 holds only when the head has at least one check and every check run there completed with `success`, `neutral` or `skipped` and every commit status but `noodlebot/auto-gate` is `success`; a failed, cancelled, timed-out, running or pending check fails it, also when the reviewer approved that red head, and the gate never calls `ci rerun`. *Verify:* `sh scheduler/autogate.test.sh`.
- **G15-AC-4** — Point 3 holds only when S16's code count of changed or removed frozen lines at the head is 0 and the last `Fresh review`'s count is none or absent, or the owner's U05 approval comment names the head; and `check-owns-diff.py` (the deployed copy) exits 0 and no changed path is a spec file by the base's **Spec files:** line; an approval at an earlier head, another user's approval line and a spec-file change (a Verify path amendment included) each fail it. *Verify:* `sh scheduler/autogate.test.sh`.
- **G15-AC-5** — Point 4 fails, naming the path and the glob, for any changed path (both paths of a rename) matched by a glob of `.noodlebot/protected-paths` read at the base branch's tip or by `.noodlebot/**`, `.github/**`, `AGENTS.md` or `CLAUDE.md` with or without the file; the list at the PR's head is never read; an unreadable list and an incomplete file list fail it. *Verify:* `sh scheduler/autogate.test.sh`.
- **G15-AC-6** — Point 5 holds only from `SCHED_AUTOGATE_WINDOW` seconds (default 1800) after the approval at the head, or after the last removal of `hold` when no owner item came after the approval, with no owner conversation comment (other than a U05 approval comment), review or line comment after the approval, the owner's last review not `CHANGES_REQUESTED`, no `hold` label, no live session or `QUESTION.md` in the PR's or its node's unit and the PR not conflicting; a new head starts over; and `labels.py ensure` creates `hold` with a colour and a description. *Verify:* `sh scheduler/autogate.test.sh`; `sh scheduler/labels-g15.test.sh`; `sh scheduler/labels.test.sh` unchanged.
- **G15-AC-7** — `autogate.py pass` on a PR whose five points hold calls, in order, `pr auto-merge` with its head, `pr view` showing squash auto-merge on, and `commit status` `noodlebot/auto-gate` `success` on that sha, and makes no further call on a second pass; before the window's end it makes none; a refused `pr auto-merge` sets no status. *Verify:* `sh scheduler/autogate-act.test.sh`.
- **G15-AC-8** — The pass turns nothing on and sets no status when the reviewer App's token script or login file is missing, when the base branch's rules do not require `noodlebot/auto-gate` from the bot's own App, when the repository does not allow squash auto-merge, or when `branch protection` gives `"unknown"` for one of these, and records why; and a spec or adoption PR that would hold all five points gets no auto-merge call and no status. *Verify:* `sh scheduler/autogate-act.test.sh`.
- **G15-AC-9** — A PR with auto-merge on or its status `success` that gets an owner comment, an owner `CHANGES_REQUESTED` review, `hold` or a new head before the merge gets `pr auto-merge-off` and its marked head's status set to `failure` with the reason; a merged PR gets no call; and a pass with an empty `gate/` folder reaches the same state from the forge alone. *Verify:* `sh scheduler/autogate-act.test.sh`.
- **G15-AC-10** — The loop runs the gate pass each tick: a passing node PR gets auto-merge and the status only after the window and the fake forge merges it, with one status-log line for the window's start and one for the auto-merge; an owner comment in the window leaves it unmerged and starts a feedback session; a spec PR is never merged; a failing pass is logged and the tick carries on; and without the reviewer's token script and login the loop's calls and status log are unchanged. *Verify:* `sh scheduler/loop-g15.test.sh`; the existing loop tests in the PR's CI run.
- **G15-AC-11** — On this repository after the owner's setup, a node PR's `autogate.py check` outputs in its states and, once its window ended with the five points holding, its auto-merge turned on, its `noodlebot/auto-gate` status and its merge by GitHub are recorded with the commands and outputs; or, if no node PR reaches the end of its window while G15's PR is open, the `check` outputs of the open node PRs with each one's reason are recorded and the first auto-merge is left to the owner to note on issue #175 (the node does not wait for it). *Verify:* the recorded commands and outputs in the PR.
- **G15-AC-12** — `.noodlebot/protected-paths` lists exactly the eleven globs of change 6, and the README's "Auto-merge of node PRs" section gives each setup step of change 6, the five points, the window and `SCHED_AUTOGATE_WINDOW`, `hold` and the protected-path list with the always-protected paths, and "Reviewing and merging PRs" no longer says the owner merges node PRs until the auto-gate is built. *Verify:* `sh scheduler/readme-g15.test.sh`.
- **G15-AC-13** — The job folder `reviewer.py prepare` writes for a node's PR, and the review session's prompt, hold nothing of that node's session transcript, handoffs or brief (a unique marker in each is absent from every file). *Verify:* `sh scheduler/autogate-act.test.sh`.

## Risks
- The gate is only as strict as the reviewer App's approval and the checks. A flaky test makes a PR wait for the owner
  (no re-run by design); issue #275's flake filing is what fixes the flake.
- Between the status being set and GitHub's merge, a push is a new head with no status, so GitHub cannot merge it; the
  next pass turns auto-merge off. The status is per sha, so a loop that is down never lets an unmarked head merge.
- The window counts from the forge's timestamps (the review's `submitted_at`, label events). A clock skew between the
  machine and the forge of minutes shifts the window by as much; `NOODLEBOT_NOW` fixes it in tests.
- The gate changes nothing in the owner's settings. If the owner's ruleset differs from the README's (no required
  approval, no stale dismissal), points 1 and 2 are still checked by the gate at the head, but a push that dismisses
  nothing relies on the per-sha status alone.
- Adding `hold` to `labels.py` may change what frozen L01 tests count; `labels.test.sh` must pass unchanged, so the
  tester checks that first and the label may need its own ensure call if a frozen case counts three.
- `scheduler/loop.sh` is a protected path, so G15's own PR, and every later change to the gate, waits for the owner.
