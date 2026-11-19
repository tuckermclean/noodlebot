---
name: node
description: Build one node of a graph-regime repository (docs/graph.yaml + nodes/<ID>-<name>.md) test-first - brief, tester RED, verified RED, implementer GREEN, independent review, CI evidence for criteria that need a build, a boot or the forge, and a PR with the criterion → evidence table. Use for "/noodlebot:node <ID>" or when asked to implement, build or start a node such as F01 or B01.
argument-hint: "<node-id, e.g. F01> [AC ids to limit the slice] | --update <PR> [--dry-run]"
---

# /noodlebot:node $ARGUMENTS

Build a node: `/noodlebot:node <ID> [AC ids]`. Bring an open node PR up to date with `main`: `/noodlebot:node --update <PR> [--dry-run]` (the section after step 7).

Feedback on one of the bot's open PRs (the feedback flag with a PR number): go straight to §8 and create no branch.

You are the **orchestrator**. You never write tests or implementation yourself. You prepare context, dispatch fresh role agents (the repository's tester, implementer and reviewer), check their evidence, get the criteria that need a build, a boot or CI verified in CI, push, and open the PR. The owner merges.

**The repository's part.** Read the repository's `AGENTS.md` first, its **Building a node** section above all. It names the authority order of its documents, the role agents, the spec checker, the test, lint and CI commands, the frozen test paths, any extra precondition, and, if the repository ports code from a predecessor, its porting rules (what to port first, the baseline, the ledger). Where this skill says "the repository's …", use what that section says. Where the two differ, the repository wins.

**The forge.** Every forge operation (PRs, issues, comments, labels, CI runs, pushes) goes through the forge CLI, written `<forge>` below: the command the run's environment and prompt name for it, used as `<forge> <family> <op> --opt value`, printing JSON. With none (a run by hand), use `<plugin dir>/../scheduler/forge-cli.sh --repo <kind>:<owner/name>` (for example `github:owner/name`), the same command with the repository named. It fetches credentials itself: never print, echo or log a token, and use no other forge client.

**Role agents.** Dispatch the role agents the repository's `AGENTS.md` names. If it names none of its own (no role agents), dispatch the plugin's `noodlebot:tester`, `noodlebot:implementer` and `noodlebot:reviewer`. The plugin's guard (`plugin/hooks/`) holds them to their roles: the test and spec paths come from the repository's `.noodlebot/roles.yaml`, or from its defaults.

## 0. Preconditions
- The working tree is clean and `main` is current.
- The node is in `docs/graph.yaml`. Each node in its `deps` is merged (`<forge> pr list --state merged`, a merged PR whose head branch starts `node/<dep>-`, or its squash commit `<ID> <name>: …` on `main`), imported or pinned (its `status` in the graph says `imported` or `pinned`; it has no PR). If one is none of these, stop and say which.
- Each open decision in the node's `decisions` is settled (the repository's decisions table), or the owner said to take its default. If not, ask.
- The repository's spec checker reports no problems, and its other preconditions pass.
- Create the branch `node/<ID>-<name>` from `main`.

## 1. Brief
Write `out/node/<ID>/brief.md` (`out/` is ignored by Git; if it is not, add it to `.git/info/exclude`). The brief contains:
- the node id, name, deps and decisions, from the graph;
- **every acceptance criterion in scope, copied verbatim** from the node spec's Gate, with its *Verify*;
- for each criterion, the numbered change in the node spec that produces it, as a pointer;
- the node spec's **Tests** section: the tests to port or keep, their listed adjustments, the tests to add and the baseline expectation;
- a coverage map: each criterion → the existing or ported test that covers it, or "new test", or "recorded run" (a build, a boot or a CI run);
- the `AGENTS.md` traps and doctrines that apply, and everything the repository's porting rules add to a brief;
- the repository's red-target command form.

Split a large node into **slices** of 3–8 related criteria. Order them so earlier slices build what later tests need.

## 2. RED (per slice)
### Pins (before the node's first RED commit)
In a repository whose graph has imported nodes, list the `unpinned` criteria of the node's imported deps whose files the node's change touches (from the node's **Changes** and the deps' `owns`). The node relies on their behaviour, and no test shows it yet.
- A criterion whose behaviour the node keeps is pinned: a tester writes a test that pins today's behaviour.
- A criterion the node changes is superseded, not pinned. The node's own criterion states the new behaviour. The test its *Verify* names is frozen like an earlier node's (the RED checks below): changing it to the new behaviour is a change to a frozen test, made on the node branch only with the owner's approval, asked for at step 7 and recorded in the answer.
- A pin passes as soon as it is written, so it is not a RED commit. It is a `pin(<ID>): …` commit that touches only test and fixture paths (a new test file only at a path a dep's glob matches, or in the node's own `owns` where no other node's glob and no `out_of_scope` glob matches) and carries one `Pin-Mutation: <DEP>-AC-<n>: <path>: <what is broken> -> <the case that fails>` trailer per pinned criterion, naming it. The tester returns each mutation as a diff in its handoff and does not edit the code.
- You, the orchestrator, write each mutation to `out/node/<ID>/pin-<n>.patch` and check it in three runs: the pinned cases pass at the pin commit; with the patch applied the named case fails; with the patch reverted they pass again. Keep the three runs as `out/node/<ID>/pin-<n>.log`. A pin that passes with its mutation applied goes back to a new tester.
- A pin's test lines are frozen like a RED commit's: a later commit may add cases, never change or remove one without the owner's approval.
- The pin's amendments to the dep's spec are small amendments (step 7). The patch and log of each pin are rows of the criterion → evidence table (step 6).

Then dispatch a **new** tester with the brief path and the slice's criterion IDs. Never resume an old agent.

The tester ports or keeps the existing tests first, then adds tests for the criteria they do not cover. A test block appended to a shared test file (one other nodes also append to) keeps all its scratch paths under a folder named after its node, `<ID>`: scratch folders, fake remotes, state directories and fake binaries. Two nodes' blocks then share no names or state. Verify the handoff yourself:
- `git show --stat <red>` touches only the repository's test and fixture paths;
- tests stay frozen for the whole node: `git diff <node-base>..<red> -- <test and fixture paths>` changes no test or fixture that an earlier RED commit of this node, or an earlier node, committed, apart from added lines (new cases). The tests an imported or pinned node's criteria name in their Verify are frozen like an earlier node's: add cases, never change or remove one without the owner's approval. Changing or removing a frozen line needs the owner's explicit approval first, recorded in the brief, the answer and the PR, and the change is made on the node branch, test-first (step 7);
- every test the node spec ports is in the commit, changed only as its **Tests** section lists, and the commit message lists each change (the repository's porting rules say how to diff against the source);
- every criterion in scope is covered by a ported or a new test, or by a recorded run; no ported case was dropped;
- the red target at `<red>` exits non-zero, and the harness runs to its end and reports each failure in its own `FAIL` lines. A missing implementation is a valid failure when reported that way. Not valid: the harness itself crashing (a syntax error, an uncaught exception or traceback, a missing test tool such as `grep` or `python3`), or a missing subject turned into a `SKIP` or a pass;
- tests that passed before still pass;
- the subject is `test(<ID>): …` and the message has one `TDD-Red-Target:` trailer.

`already_satisfied`: record it and drop those criteria. `blocked`: go to step 7.

**Baseline**, where the repository's porting rules define one and the node's **Tests** section says it is practical: run the red target against the source's implementation as those rules say. Expect the ported tests and the criteria of inherited behaviour to pass, and the criteria a numbered change produces to fail. Keep the log as `out/node/<ID>/baseline.log`. A defect test that passes on the baseline does not test the defect: send it back to a new tester. An inherited test that fails there is a broken adjustment or a wrong assumption: investigate, and go to step 7 if the spec is at fault. Where the baseline is not practical, record the reason the node spec gives.

## 3. GREEN
Dispatch a **new** implementer with the brief path, the RED SHA, the red target and the failing tests. Check its handoff:
- the red target passes at head;
- the quick test gate the repository's `AGENTS.md` names (the red targets and the touched files' tests) passes, run locally with every other test target the slice touched. With a `gate` in the graph, a run of the tests passes when it exits 0, or exits non-zero with at least one line `fail_pattern` matches and each such line containing a `known_red` entry; a non-zero exit with no matched line fails, and an empty `known_red` or no `fail_pattern` means it must exit 0. The evidence lists each failing line with the `known_red` entry it matched. A local quick gate whose output `fail_pattern` cannot read passes only on exit 0. Where the graph has no `gate`, it passes on exit 0. The whole suite is shown by the PR's CI run (step 5), not run locally; targets that need a build, a boot or CI run in step 5;
- if the slice touched a workflow, the repository's workflow lint passes;
- `git diff <first-red>..HEAD -- <test and fixture paths>`, from the node's first RED commit, modifies or deletes no frozen test or fixture, ported or new; later RED commits only add (above);
- everything the repository's porting rules check at GREEN (ported files equal their source plus the numbered changes, the ledger on the node's last slice, provenance in commit messages only). A needed change to a ledger is a spec change only when the ledger is one of the repository's spec files (the **Spec files:** line); otherwise the owner approves it as a question (step 7) and it is made on the node branch.

Retries are bounded: **at most 4 implementer attempts per slice.** Attempts 1–3 use the agent's model. Attempt 4 uses the strongest model the harness offers, as an override of the agent's model, and gets every earlier finding and failed diff SHA. After that, go to step 7.

## 4. Review
Dispatch a **new** reviewer with the brief path, the base, RED and head SHAs, and the evidence. On `request_changes`, give the findings to a new implementer (the retry budget applies). On `test_spec_conflict`, go to step 7. Never edit tests to satisfy a reviewer: a wrong test means a new RED commit from a new tester, and the owner approves that first.

## 5. Builds, boots and CI runs
Every test is in the repository's whole suite, which the PR's CI run runs; some need a build, a boot, a build image or the forge. **A criterion that needs a build, a boot, the gates or the forge is verified in CI on the forge's runners**, on clean runners: push the branch and let its workflows run (with whatever label or dispatch the repository's workflows need), and record the run URL. This covers package and image builds, every boot mode, artifact checks and gates, registry pushes, attestations, tag pipelines and anything that moves files between jobs. Builds that must be clean or separate run only in CI.

Local runs are for quick checks while you work, not evidence: the quick test gate the repository's `AGENTS.md` names, and one boot mode or one gate to try a fix before pushing. The whole suite is not run locally: its evidence is the PR's CI run, recorded in the evidence table. Keep the local runs' logs under `out/node/<ID>/`. Several nodes run at once on one small machine, so avoid local package or image builds; a local build is for diagnosing a CI failure that CI cannot show.

Record each command, exit code and log path or run URL. A criterion verified by a run is not met without a recorded CI run. When a check also ran locally, record both; a target that passes in one and fails in the other is a parity bug, so stop and report it (step 7).

**The gate's pass condition.** With a `gate` in the graph, a run of the tests passes when it exits 0, or exits non-zero with at least one line `fail_pattern` matches and each such line containing a `known_red` entry; a non-zero exit with no matched line fails, and an empty `known_red` or no `fail_pattern` means it must exit 0. The evidence lists each failing line with the `known_red` entry it matched. The same rule judges the local quick gate and the CI run of `gate.command` alike. `fail_pattern` is written for `gate.command`'s output: a local quick gate whose output it cannot read passes only on exit 0. No local run of `gate.command` is required; the whole suite's evidence stays the PR's CI run. A CI job red only with `known_red` failures is not a parity problem: record it that way.

## 6. Pull request
Before the final CI run, merge `origin/main` again: other nodes merge while you work.
If the merge had conflicts, run the resolution review (below) on it before you continue. Do the same for any other merge of `origin/main` made while building.

**Ownership.** In a repository whose graph has `owns` (ownership), before the PR, run `python3 -I <plugin dir>/skills/node/check-owns-diff.py <ID> origin/main HEAD`, and `python3 -I <plugin dir>/skills/node/check-coverage.py` at the head and, with `--ref origin/main`, at `origin/main`: only the coverage problems at the head that are not at `origin/main` are the node's. A `NOT OWNED` path follows the rule below for a file outside the node's Owns: the owner's approval, asked as a question and recorded in the answer. Each output is a row of the criterion → evidence table. Without `owns` nothing changes.

**Pins.** Each pin commit (step 2) has rows in the criterion → evidence table: its `pin-<n>.patch` and its `pin-<n>.log` (the three runs), and the dep amendments that name it.

Push with `<forge> branch push --path . --branch <branch>`. A push that changes `.github/workflows/*` needs a credential with workflow permission; if the forge refuses it, ask the owner to push the branch.

**Files a merged spec PR carried.** When the `answered/` of the state directory the run names has merged spec PRs (`<ts>-SPEC-PR`), run the checker on each PR's merge commit (`<forge> pr view --number <N>`, its `merge_commit`): `python3 -I <plugin dir>/skills/node/check-spec-diff.py <sha>^ <sha>`. Every file outside the spec files that it prints as `NOT SPEC <path>` gets a row in the criterion → evidence table, naming the spec PR. The whole-node fresh reviewer gets those diffs too: it reviews them as part of the node.

Open the PR with `<forge> pr create --head <branch> --base main --title <title> --body-file <file>`. The body has:
- what the node delivers, in two or three sentences;
- the files ported or brought in, with their source and the numbered changes applied, tests first;
- the baseline result (`out/node/<ID>/baseline.log` summary), or why it was not practical;
- the criterion → evidence table: criterion, test or command, where it ran (CI URL, or local for quick checks), result;
- the RED → GREEN → review SHAs for each slice;
- **Spec amendments** (step 7), each with its commit and reason, or "none";
- files that a merged spec PR of this node carried outside the spec files (above), or "none";
- deviations and open questions.

**Fresh review on the PR.** Once the PR is open, dispatch a **new** reviewer over the whole node: the brief, the node's base (the `origin/main` commit the branch started from), every slice's RED SHA, the head SHA, the PR URL, the evidence table and the diffs of any merged spec PR's files outside the spec files (above). It has seen none of the slice reviews. On `request_changes` its review is not posted as a final review: the session acts on the findings (next paragraph). Otherwise post it as the final review with `<forge> pr comment --number <N> --body-file <file>`, headed `Fresh review (<verdict>) at <sha>`. This is a comment, never an approval. On `test_spec_conflict`, go to step 7.

**The final review is the last thing on the PR.** On `request_changes`, give the findings to a new implementer and fix them first, test-first, under the slice retry budget
(a new tester's RED, a new implementer's GREEN, the slice review), and the session pushes, and then a new reviewer reviews the whole node at the new head, the final head.
Only that final review is posted on the PR, its first line headed `Fresh review (<verdict>) at <sha>`,
where `<sha>` is the head it reviewed (seven or more hex characters).
A review whose findings will still be acted on is never posted headed `Fresh review (`:
it stays in the session's notes (`out/node/<ID>/`), or is posted as a comment
whose first line says the PR is not ready to merge.
The session posts nothing to the PR after its final review but its own end (CI on that head, `QUESTION.md`).
Every review comment the skill posts (the fresh review, the resolution review, a review posted as not ready)
names on its first line the commit it covers, as `at <sha>`.

**A push after the final review** (a CI fix, a resumed session after an answer): first comment on the PR
that the review at `<sha>` no longer covers the head and the PR is not ready to merge, then push, then post a new
`Fresh review (<verdict>) at <new head>` from a new reviewer. It reviews the whole node when the node's own code
changed since the reviewed head; else it is given the diff from the reviewed head to the new head and checks
that it changes nothing of the node's beyond that.

Give the owner the PR URL. You never approve or merge.

## 7. Stop and ask the owner
Stop for:
- a false unverified claim in the node spec;
- an ambiguous or contradictory criterion;
- a `test_spec_conflict`;
- an exhausted retry budget;
- a needed change to the repository's spec, a node spec or the graph, except a small amendment (below).

Propose the amendment. Do not continue on a guess. A spec change is the owner's, made on its own branch; run the spec checker after it.

**A spec PR changes only the repository's spec files.** These are the paths in backticks on the **Spec files:** line of the "Building a node" section of the repository's `AGENTS.md`, else `SPEC.md`, `docs/graph.yaml` and `nodes/`; `check-spec-diff.py` (next to this skill, `skills/node/check-spec-diff.py` under the plugin directory) reads the same list. Changing a frozen test line, or a file outside the node's **Owns:**, needs the owner's approval, asked for as a question and recorded in the answer (quote it in the spec PR when there is one). The change itself is made on the node branch, test-first, where the node's review and the criterion → evidence table cover it; it never goes in a spec PR.

**Before pushing a spec branch**, run the checker against `origin/main`: `python3 -I <plugin dir>/skills/node/check-spec-diff.py origin/main HEAD`. On exit 1 it names each path outside the spec files as `NOT SPEC <path>`: remove those changes from the spec branch, and stop if you cannot; on exit 2 (git failed) stop.

**Small spec amendments go in the node PR.** A change to this node's spec that leaves the meaning of every criterion intact needs no stop and no spec PR: a clearer or corrected *Verify* line, an added or corrected path (**Owns:**, the files a change names), a stale fact in Purpose or Risks, a typo. Adding a path to the node's own **Owns:** is such a small amendment: it stays in the node PR. Commit it on the node branch on its own (`spec(<ID>): ...`), run the spec checker, and list it in the PR's **Spec amendments** section with its reason; the owner reviews it with the PR, and the fresh reviewer checks that no criterion's meaning changed. In a graph with `owns` or a `gate`, these are small amendments too, committed and listed the same way, and they are the graph changes a node PR may make: adding, correcting or removing a glob of this node's own `owns` (and its Owns paragraph), an added glob only for paths no other node's glob and no `out_of_scope` glob matches; removing a `known_red` entry the change makes pass; and removing a dep's glob that the change (a deleted or moved file) leaves matching nothing, unless it is the dep's last glob (that takes a spec PR). Without `owns` and `gate` nothing changes. A dep amendment for a pin is a small amendment too, listed in the PR's Spec amendments: replacing `unpinned` in a pinned dep criterion with the pin's test; replacing a changed dep criterion's *Verify* with `superseded by <ID>-AC-<n>`; and setting the dep's `status` to `pinned` in the graph when no `unpinned` criterion is left. These are exceptions to "another node's spec or the graph needs a spec PR". A conflict in `owns` globs or `known_red` entries is resolved without a question by applying both sides' changes, each line taking the side that changed it. A line both sides changed (the same glob or entry, changed differently) is not resolved: write QUESTION.md. A conflict in the pin, superseded or status lines is resolved the same way (see the `--update` step). Anything that adds, removes or weakens a criterion, changes what a criterion requires, or touches another node's spec, the repository's main spec or the graph beyond these amendments still gets its own spec PR, after you stop and ask, and that PR holds spec files only.

## Update a node PR: `/noodlebot:node --update <PR> [--dry-run]`
Bring an open node PR up to date with `main` when it conflicts. Work in a worktree checked out on the PR's named branch, not a detached HEAD. Change nothing else.
A restarted update first reads the owner's answer: every file in `answered/` of the state directory the run's prompt names, oldest first. `answered/` builds up across update cycles: only the newest QUESTION/ANSWER pair is the owner's decision for this run. Older pairs are context from earlier cycles, not approval. An owner's approval in that newest answer permits exactly the change it approves, quoted in the PR comment; anything else the rules below forbid still ends in `QUESTION.md`.
1. Read the PR with `<forge> pr view --number <PR>`: its branch (`head`), and the body with the criterion → evidence table. `git fetch origin`, bring the branch to `origin/<branch>` (a fast-forward), then merge `origin/main`: a merge commit, never a rebase, never a force push.
2. If resolving a conflict would change a frozen test or fixture line, or a spec file (except the `owns` globs, `known_red` entries and dep pin, superseded and status lines of step 7's amendments, which step 3 resolves), run `git merge --abort`, push nothing, and write `QUESTION.md` (in the state directory the run names, else `out/node/pr-<N>/QUESTION.md`) with the conflicting files and lines and your recommendation. End.
3. Otherwise resolve by keeping both sides. A conflict in `owns` globs or `known_red` entries is resolved without a question by applying both sides' changes, each line taking the side that changed it. A line both sides changed (the same glob or entry, changed differently) is not resolved: as in step 2, run `git merge --abort`, push nothing, write `QUESTION.md` and end.
    A conflict in the dep amendments of step 7 (the pin named in an `unpinned` criterion, a criterion's *Verify* set to `superseded by <ID>-AC-<n>`, a dep's `status`) is resolved the same way: apply both sides' changes, each line taking the side that changed it, with no question (one side's pin and the other's both kept, nothing one side replaced coming back). After the resolution, set the dep's `status` to `pinned` when no `unpinned` criterion is left, even when neither side set it. When both sides change the same criterion's *Verify* or set the same dep's `status` differently, it is not resolved: as in step 2, run `git merge --abort`, push nothing, write `QUESTION.md` and end.
    Add test lines only to keep appended test blocks apart: lines between the blocks, e.g. clearing the first block's scratch paths; never rename or change an existing line. Leave no conflict markers. Commit the merge with its resolution now, before the tests and the review.
4. Run the quick test gate the repository's `AGENTS.md` names (e.g. `make test TESTS="<files>"`) for the files the merge touched, and each red target: from the PR body's criterion → evidence table, else the `TDD-Red-Target:` trailers in `git log origin/main..HEAD`. With a `gate` in the graph, a run of the tests passes when it exits 0, or exits non-zero with at least one line `fail_pattern` matches and each such line containing a `known_red` entry; a non-zero exit with no matched line fails, and an empty `known_red` or no `fail_pattern` means it must exit 0. The evidence lists each failing line with the `known_red` entry it matched. A local quick gate whose output `fail_pattern` cannot read passes only on exit 0. A failing test the resolution cannot fix: push nothing, write `QUESTION.md` with the failure, run `git reset --hard origin/<branch>` (no merge commit left) and end.
5. Run the resolution review (below) with a new reviewer. Push only after it approves.
6. Rerun the whole-node fresh review (build step 6, Fresh review on the PR) only when the resolution changed the node's own code beyond keeping both sides. With `--dry-run` this fresh review posts nothing on the PR: its verdict goes into `result.md`, like the resolution review's.
   A push to a PR with a posted `Fresh review` follows build step 6's rule for a push after the final review: before the push, comment on the PR
   that the review at `<sha>` no longer covers the head and the PR is not ready to merge; after it, post a new
   `Fresh review (<verdict>) at <new head>` from a new reviewer. It reviews the whole node when the node's own code changed since the reviewed head;
   else (the resolution kept both sides) it is given the diff from the reviewed head to the new head and checks that it changes nothing of the node's beyond that.
7. With `--dry-run`, stop before the push and write `out/node/pr-<N>/result.md`: the merge result, each resolved file and how, each added test line, the test results and each review's verdict; or that it wrote `QUESTION.md` and left no merge commit. No push, no comment.
8. Push the branch. Comment on the PR with each resolved file and how, each added test line, the test results and the review's verdict. Then take the whole suite's result from the PR's CI run, and say it on the PR.

### Resolution review
Run after any merge of `origin/main` that had conflicts, before anything is pushed. Dispatch a **new** reviewer (a resolution review) with the merge commit and its diffs against both parents; these inputs and this checklist replace the reviewer's usual brief, criteria and SHA inputs. It checks that:
- the resolution keeps the intent of both sides;
- the test blocks of different nodes share no names or state;
- no frozen test line was changed, removed or renamed.

Its verdict is posted on the PR as `Resolution review (<verdict>)`, its first line `Resolution review (<verdict>) at <sha>` for the merge commit it reviewed, with `<forge> pr comment --number <N> --body-file <file>`: a comment, never an approval; with `--dry-run` the verdict goes into `result.md` and is not posted. In a node build with no PR yet, it goes into the PR body's deviations and is posted as that comment once the PR is open. Nothing is pushed until it approves. On `request_changes`, fix the findings as new commits and run one more new reviewer on the result. A second rejection pushes nothing: write `QUESTION.md` with the findings and leave the branch as it was. With `--update`, run `git reset --hard origin/<branch>` (no merge commit left). In a node build's own merge of `origin/main` (build step 6), undo only the merge (`git reset --hard` to the merge's first parent, or `ORIG_HEAD`), never losing the node's commits. Then end.

## 8. Feedback on a PR: `/noodlebot:node --feedback <PR> [--dry-run]`
Run by the loop for one of the bot's own open node PRs that has new feedback from the owner. This session acts as the node's orchestrator for this PR, on the PR's branch, not a new one. Work in a worktree checked out on the PR's branch, brought to `origin/<branch>` (a fast-forward), and read `FEEDBACK.md` in your state folder: each item has its kind, URL, author, body and, for a line comment, its file, line and thread.
1. Sort the points. A point that changes behaviour goes through the usual test-first steps: a new tester's RED commit (verified RED), a new implementer's GREEN, then the review (§2–§4). A point that is a question, a nit or a wording fix needs no tester. A point that would change, remove or rename a frozen test or fixture line, or change a spec file, is not made: collect those points, with your recommendation, for QUESTION.md (item 4 or 5 says when it is written).
2. Never rebase or force-push; add commits and merge `origin/main` if the PR needs it. A merge that had conflicts gets the resolution review (see "Resolution review") before anything is pushed; on a second rejection push nothing, write `QUESTION.md` with the findings and undo only the merge (the branch as it was), never losing the PR's commits, then end. Never edit a frozen test or fixture line.
3. Rerun the quick test gate the repository's `AGENTS.md` names (e.g. `make test TESTS="<files>"`) for the files the change touched, and the red targets that the PR's criterion → evidence table names. With a `gate` in the graph, a run of the tests passes when it exits 0, or exits non-zero with at least one line `fail_pattern` matches and each such line containing a `known_red` entry; a non-zero exit with no matched line fails, and an empty `known_red` or no `fail_pattern` means it must exit 0. The evidence lists each failing line with the `known_red` entry it matched. A local quick gate whose output `fail_pattern` cannot read passes only on exit 0. The whole suite's result is the PR's CI run after the push. When the node's code changed, rerun the whole-node fresh review (§6) and post it as a new `Fresh review (<verdict>)` comment; update the PR body's table when its evidence changed.
   A push to a PR with a posted `Fresh review` is preceded by a PR comment that the review at `<sha>` no longer covers the head
   and the PR is not ready to merge, and followed by a new `Fresh review (<verdict>) at <new head>` from a new reviewer.
   It reviews the whole node when the node's own code changed since the reviewed head; else it is given the diff from the reviewed head to the new head.
4. With `--dry-run`: no push, no reply, no comment, no PR edit, no thread resolved. Write `out/node/pr-<N>/result.md` holding the commits (SHA and subject, e.g. the RED and GREEN commits) and one reply per item, each naming the commit (or why nothing changed) and, for a fixed line comment, the thread it would resolve; and write QUESTION.md for the points of item 1 that need the owner, with your recommendation (the loop posts it; the answer comes back as ANSWER.md). QUESTION.md goes in the state folder the loop gives; with none (a dry run by hand), next to result.md as `out/node/pr-<N>/QUESTION.md`. Stop there.
5. Otherwise push, then reply to each point: a line comment in its own thread, every other point in one PR comment that links each of them. Each reply says what changed, with the commit, or why nothing did. Resolve the line threads you fixed (`<forge> pr resolve-thread --thread <id>`, and `pr reply --number <PR> --to <comment id> --body-file <file>` for the reply in its own thread); leave the others open. Write QUESTION.md last, for the points of item 1 that need the owner, with your recommendation.
6. Never approve or merge the PR, and never dismiss a review. Write no closing keyword before an issue number.

## Cost discipline
- Hand agents file paths and section pointers, not pasted documents.
- One fresh agent per role per attempt. Never resume long transcripts.
- At most 2–3 agents at a time, and only for independent slices.
