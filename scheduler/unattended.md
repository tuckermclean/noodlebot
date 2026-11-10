UNATTENDED RUN. The noodlebot scheduler (@LOOP@) started this session to build node @ID@
(@NAME@) of @REPO@. Nobody can answer until morning.

- At a step 7 stop of the node skill, write the question, your proposed amendment and what is blocked to
  @STATE@/node/@ID@/QUESTION.md, then end the run. Never continue on a guess. A SPEC §10 default
  for an open decision is the owner's standing choice, not a guess: take it and record it in the PR.
  Number the questions (Q1, Q2, ...) and give your recommendation for each, so the owner can answer
  in a line. End the file with: "To answer: write ANSWER.md next to this file."
- You are in the worktree @WT@ on branch node/@ID@-@NAME@. Your brief and logs go in this
  worktree's out/node/@ID@/. The scheduler's own files are under @STATE@/.
- First, bring the branch up to date: git fetch origin && git merge --no-edit origin/main. Do the
  same before the final CI run: other nodes run in parallel and merge while you work.
  MERGE CONFLICTS: resolve them yourself, keeping both sides' intent (another node's merged work
  stays), unless a conflicted file is a frozen test or fixture (in the repository's test and fixture
  paths, committed by an earlier RED commit or node) or a spec file (SPEC.md, nodes/, docs/graph.yaml,
  docs/migration.tsv, docs/capabilities.md). For those, git merge --abort, write QUESTION.md and end
  the run. After resolving, rerun the quick test gate and every red target of this node, and list
  each resolved file in the PR under Deviations.
@RESUME-BEGIN@
- RESUMING AFTER A STOP. This branch already has work (commits past origin/main: @COMMITS@), and the
  worktree may hold out/node/@ID@/.
@REASON-BEGIN@
  The last session ended: @REASON@.
@REASON-END@
  - Read out/node/@ID@/ (brief, logs) and git log origin/main..HEAD first. Keep the existing brief and
    add to it rather than rewrite it. Carry on from the last reviewed slice; do not redo a slice that
    is already committed and reviewed.
  - The earlier session may have started CI runs on this branch. Run gh run list --branch @BR@ and wait
    for or read those before starting a new one.
@PATCH-BEGIN@
  - The uncommitted changes the dead session left were saved as the patch
    @PATCH@ and the worktree was reset to HEAD. Examine that patch (git apply --stat, read it);
    never apply or commit it unexamined. List it in the PR under Deviations with what you did with it.
@PATCH-END@
@RESUME-END@
- RESUMING. If @STATE@/node/@ID@/answered/ exists, an earlier run of this node stopped. Read every
  file in it, oldest first (the names start with a UTC timestamp): <ts>-QUESTION.md is what a run
  asked, <ts>-ANSWER.md is the owner's answer, <ts>-SPEC-PR holds the number of a spec PR the owner
  has merged. Read out/node/@ID@/ (brief, logs) and the commits on this branch too. Continue from
  where the last run stopped; do not redo slices that are already committed and reviewed.
  - ANSWER.md is the owner's decision, written by the owner. An approval in it is the explicit owner
    approval /node asks for, including for changing a frozen test line. Quote the answer in the
    brief and in the PR (Deviations / open questions) wherever you act on it.
  - "Recommended", "your recommendation" or "as proposed" means the recommendation in the matching
    question.
  - If the answer does not settle a blocking question, or contradicts itself, write a new
    QUESTION.md that says exactly what is still open, and end the run.
- SMALL SPEC AMENDMENTS (the node skill's step 7: this node's spec only, every criterion's meaning
  intact, such as a clearer Verify line or an added path) need no question and no spec PR: commit
  them on the node branch and list them in the PR under "Spec amendments".
- SPEC CHANGES. When an answer approves any other change to SPEC.md, a node spec, docs/graph.yaml,
  docs/migration.tsv or anything else the node skill's step 7 says is a spec change, do not put it
  on the node branch. Instead:
  1. git worktree add -b spec/@ID@-<short-topic> @WT@-spec origin/main (pick a new topic name if
     the branch exists), and make exactly the approved change there.
  2. The repository's spec checker must report PROBLEMS 0 (AGENTS.md names it: scripts/check-spec.py,
     or .claude/skills/node/check-spec.py in older checkouts).
  3. Commit (subject "Spec: ..."), push the branch, open the PR with gh pr create. The body says
     what changes and quotes the question and the owner's answer it carries out.
  4. Remove the spec worktree (git worktree remove @WT@-spec). Write only the PR number to
     @STATE@/node/@ID@/WAITING-PR, and end the run. The scheduler starts this node again after the
     owner merges that PR.
  Approvals that need no spec change (a frozen test line, a deviation to record) apply straight away
  on the node branch. If the answers include both, first open the spec PR and stop; do the rest after.
- GitHub: the gh CLI's stored account is suspended. Authenticate every gh call with the GitHub App:
  GH_TOKEN=$(~/.config/noodlebot/token @REPO@) gh ... --repo @REPO@
  Push with: GIT_TOKEN=$(~/.config/noodlebot/token @REPO@) git -c credential.helper= -c credential.helper='!f() { echo username=x-access-token; echo "password=$GIT_TOKEN"; }; f' push -u origin HEAD
  Edit a PR body with gh api -X PATCH repos/@REPO@/pulls/N -F body=@file.
  Never print, echo or log a token.
  App tokens expire after 1 hour. A wait or poll loop calls ~/.config/noodlebot/token inside the loop,
  on every poll, never once before it, and treats a failed gh call as an error it reports, not as "not
  done yet": a loop that caches the token spins forever once it expires and never sees the run end.
- GitHub closes an issue when a PR description, or a commit message that reaches main, contains a
  closing keyword (close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved, with or
  without a colon) followed by its number. Write one only where closing is intended (a node PR's
  "Fixes #N" lines); everywhere else write "issue #N" or "Refs #N", and never quote a spec's
  Resolves: line or describe what "closes" an issue next to its number.
- Never merge, approve, push to main, or change branch protection or repository settings.
- CI flakes seen so far: snapshot.debian.org outages while building the toolbox (the toolbox image
  is now pulled from GHCR, so rare), and an intermittent perl segfault in rc1's uefi boot test. Re-run
  a failed job once (gh run rerun <id> --failed) before treating it as real.
- If the node's spec has a **Resolves:** line (issues it was created or amended for), the PR body
  says "Fixes #N" for each issue on it, so GitHub closes them when the PR merges. If an issue turns
  out not to be resolved by this node, say so in the PR and write "Refs #N" instead.
- When the PR is open, CI is green and the fresh reviewer's comment is on it (/node step 6), or
  you have written QUESTION.md or WAITING-PR, end the run.
