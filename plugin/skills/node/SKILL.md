---
name: node
description: Build one node of a graph-regime repository (docs/graph.yaml + nodes/<ID>-<name>.md) test-first - brief, tester RED, verified RED, implementer GREEN, independent review, CI evidence for criteria that need a build, a boot or GitHub, and a PR with the criterion → evidence table. Use for "/noodlebot:node <ID>" or when asked to implement, build or start a node such as F01 or B01.
argument-hint: "<node-id, e.g. F01> [AC ids to limit the slice] | --update <PR> [--dry-run]"
---

# /noodlebot:node $ARGUMENTS

Build a node: `/noodlebot:node <ID> [AC ids]`. Bring an open node PR up to date with `main`: `/noodlebot:node --update <PR> [--dry-run]` (the section after step 7).

You are the **orchestrator**. You never write tests or implementation yourself. You prepare context, dispatch fresh role agents (the repository's tester, implementer and reviewer), check their evidence, get the criteria that need a build, a boot or CI verified in CI, push, and open the PR. The owner merges.

**The repository's part.** Read the repository's `AGENTS.md` first, its **Building a node** section above all. It names the authority order of its documents, the role agents, the spec checker, the test, lint and CI commands, the frozen test paths, any extra precondition, and, if the repository ports code from a predecessor, its porting rules (what to port first, the baseline, the ledger). Where this skill says "the repository's …", use what that section says. Where the two differ, the repository wins.

**Role agents.** Dispatch the role agents the repository's `AGENTS.md` names. If it names none of its own (no role agents), dispatch the plugin's `noodlebot:tester`, `noodlebot:implementer` and `noodlebot:reviewer`. The plugin's guard (`plugin/hooks/`) holds them to their roles: the test and spec paths come from the repository's `.noodlebot/roles.yaml`, or from its defaults.

## 0. Preconditions
- The working tree is clean and `main` is current.
- The node is in `docs/graph.yaml`. Each node in its `deps` has a merged PR (`gh pr list --state merged --search "head:node/<dep>-"`, or its squash commit `<ID> <name>: …` on `main`). If one is missing, stop and say which.
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
Dispatch a **new** tester with the brief path and the slice's criterion IDs. Never resume an old agent.

The tester ports or keeps the existing tests first, then adds tests for the criteria they do not cover. A test block appended to a shared test file (one other nodes also append to) keeps all its scratch paths under a folder named after its node, `<ID>`: scratch folders, fake remotes, state directories and fake binaries. Two nodes' blocks then share no names or state. Verify the handoff yourself:
- `git show --stat <red>` touches only the repository's test and fixture paths;
- tests stay frozen for the whole node: `git diff <node-base>..<red> -- <test and fixture paths>` changes no test or fixture that an earlier RED commit of this node, or an earlier node, committed, apart from added lines (new cases). Changing or removing a frozen line needs the owner's explicit approval first, recorded in the brief and the PR (step 7);
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
- the repository's quick test gate passes, with every other test target the slice touched; targets that need a build, a boot or CI run in step 5;
- if the slice touched a workflow, the repository's workflow lint passes;
- `git diff <first-red>..HEAD -- <test and fixture paths>`, from the node's first RED commit, modifies or deletes no frozen test or fixture, ported or new; later RED commits only add (above);
- everything the repository's porting rules check at GREEN (ported files equal their source plus the numbered changes, the ledger on the node's last slice, provenance in commit messages only). A needed change to a ledger is a spec change (step 7).

Retries are bounded: **at most 4 implementer attempts per slice.** Attempts 1–3 use the agent's model. Attempt 4 uses the Agent tool's `model: "opus"` override and gets every earlier finding and failed diff SHA. After that, go to step 7.

## 4. Review
Dispatch a **new** reviewer with the brief path, the base, RED and head SHAs, and the evidence. On `request_changes`, give the findings to a new implementer (the retry budget applies). On `test_spec_conflict`, go to step 7. Never edit tests to satisfy a reviewer: a wrong test means a new RED commit from a new tester, and the owner approves that first.

## 5. Builds, boots and CI runs
Every test is reached by the repository's test entry point; some need a build, a boot, a build image or GitHub. **A criterion that needs a build, a boot, the gates or GitHub is verified in CI on GitHub Actions**, on clean runners: push the branch and let its workflows run (with whatever label or dispatch the repository's workflows need), and record the run URL. This covers package and image builds, every boot mode, artifact checks and gates, registry pushes, attestations, tag pipelines and anything that moves files between jobs. Builds that must be clean or separate run only in CI.

Local runs are for quick checks while you work, not evidence: the quick test gate, and one boot mode or one gate to try a fix before pushing. Keep their logs under `out/node/<ID>/`. Several nodes run at once on one small machine, so avoid local package or image builds; a local build is for diagnosing a CI failure that CI cannot show.

Record each command, exit code and log path or run URL. A criterion verified by a run is not met without a recorded CI run. When a check also ran locally, record both; a target that passes in one and fails in the other is a parity bug, so stop and report it (step 7).

## 6. Pull request
Before the final CI run, merge `origin/main` again: other nodes merge while you work.
If the merge had conflicts, run the resolution review (below) on it before you continue. Do the same for any other merge of `origin/main` made while building.

Push with `git push -u origin HEAD`. A push that changes `.github/workflows/*` needs a token with workflow permission; use the credential your run provides, transiently, or ask the owner to push the branch.

Open the PR with `gh pr create`. The body has:
- what the node delivers, in two or three sentences;
- the files ported or brought in, with their source and the numbered changes applied, tests first;
- the baseline result (`out/node/<ID>/baseline.log` summary), or why it was not practical;
- the criterion → evidence table: criterion, test or command, where it ran (CI URL, or local for quick checks), result;
- the RED → GREEN → review SHAs for each slice;
- **Spec amendments** (step 7), each with its commit and reason, or "none";
- deviations and open questions.

**Fresh review on the PR.** Once the PR is open, dispatch a **new** reviewer over the whole node: the brief, the node's base (the `origin/main` commit the branch started from), every slice's RED SHA, the head SHA, the PR URL and the evidence table. It has seen none of the slice reviews. Post its verdict and findings on the PR with `gh pr comment <N> --body-file <file>`, headed `Fresh review (<verdict>)`. This is a comment, never an approval. On `request_changes`, give the findings to a new implementer (the slice retry budget applies), push, then run a new reviewer and post a new comment. On `test_spec_conflict`, go to step 7.

Give the owner the PR URL. You never approve or merge.

## 7. Stop and ask the owner
Stop for:
- a false unverified claim in the node spec;
- an ambiguous or contradictory criterion;
- a `test_spec_conflict`;
- an exhausted retry budget;
- a needed change to the repository's spec, a node spec or the graph, except a small amendment (below).

Propose the amendment. Do not continue on a guess. A spec change is the owner's, made on its own branch; run the spec checker after it.

**Small spec amendments go in the node PR.** A change to this node's spec that leaves the meaning of every criterion intact needs no stop and no spec PR: a clearer or corrected *Verify* line, an added or corrected path (**Owns:**, the files a change names), a stale fact in Purpose or Risks, a typo. Commit it on the node branch on its own (`spec(<ID>): …`), run the spec checker, and list it in the PR's **Spec amendments** section with its reason; the owner reviews it with the PR, and the fresh reviewer checks that no criterion's meaning changed. Anything that adds, removes or weakens a criterion, changes what a criterion requires, touches another node's spec, the graph or the repository's main spec, or changes a frozen test still gets its own spec PR, after you stop and ask.

## Update a node PR: `/noodlebot:node --update <PR> [--dry-run]`
Bring an open node PR up to date with `main` when it conflicts. Work in a worktree checked out on the PR's named branch, not a detached HEAD. Change nothing else.
1. Read the PR with `gh pr view <PR> --json headRefName,body`: its branch, and the body with the criterion → evidence table. `git fetch origin`, bring the branch to `origin/<branch>` (a fast-forward), then merge `origin/main`: a merge commit, never a rebase, never a force push.
2. If the merge would change a frozen test or fixture line, or a spec file, run `git merge --abort`, push nothing, and write `QUESTION.md` (in the state directory the run names, else `out/node/pr-<N>/QUESTION.md`) with the conflicting files and lines and your recommendation. End.
3. Otherwise resolve by keeping both sides. Add test lines only to keep appended test blocks apart (distinct names, a scratch folder named after each node); change no existing line. Leave no conflict markers.
4. Run the repository's test entry point (`make test`) and each red target the PR's table names. A failing test the resolution cannot fix: `git merge --abort` if the merge is uncommitted, push nothing, write `QUESTION.md` with the failure and end.
5. Run the resolution review (above) with a new reviewer. Push only after it approves.
6. Rerun the whole-node fresh review (step 6) only when the resolution changed the node's own code beyond keeping both sides.
7. With `--dry-run`, stop before the push and write `out/node/pr-<N>/result.md`: the merge result, each resolved file and how, each added test line, the test results and the review's verdict; or that it wrote `QUESTION.md` and left no merge commit. No push, no comment.
8. Push the branch. Comment on the PR with each resolved file and how, each added test line, the test results and the review's verdict.

### Resolution review
Run after any merge of `origin/main` that had conflicts, before anything is pushed. Dispatch a **new** reviewer (a resolution review) with the merge commit and its diffs against both parents. It checks that:
- the resolution keeps the intent of both sides;
- the test blocks of different nodes share no names or state;
- no frozen test line was changed, removed or renamed.

Its verdict is posted on the PR as `Resolution review (<verdict>)` with `gh pr comment <N> --body-file <file>`: a comment, never an approval. Nothing is pushed until it approves. On `request_changes`, fix the findings and run one more new reviewer. A second rejection pushes nothing: write `QUESTION.md` with the findings and end.

## Cost discipline
- Hand agents file paths and section pointers, not pasted documents.
- One fresh agent per role per attempt. Never resume long transcripts.
- At most 2–3 agents at a time, and only for independent slices.
