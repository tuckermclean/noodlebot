---
name: triage
description: Fit one GitHub issue into a graph-regime repository's plan (docs/graph.yaml + nodes/<ID>-<name>.md) as a spec change - amend an unmerged node, add a follow-up or new node, or answer without a change. Produces a spec PR or an issue comment, never code or tests. Use for "/triage <issue>" or when asked where an issue belongs in the node graph.
---

# /triage <issue number> [--dry-run]

You turn one issue into **plan**, not code. The graph is the only work queue: once your spec PR is
merged, the scheduler builds the node with `/node` as usual, and that node's PR fixes the issue.

**Never** write implementation or tests, edit a merged node's criteria, or change the repository's
principles. With `--dry-run`, do everything up to a local commit, then stop: no push, no PR, no
comment; write your result to `out/triage/<issue>/result.md` and print it.

## The graph regime (what every such repository has)
- `docs/graph.yaml`: `nodes:` with `id` (letter + two digits), `name`, `deps`, `track`, `summary`,
  and optionally `decisions` (open decisions the owner settles first).
- `nodes/<ID>-<name>.md`: one spec per node, following the repository's template, with acceptance
  criteria `<ID>-AC-<n>` (each with *Verify*, numbered from 1, never reused) and an **Owns:** line.
- A spec checker that must report no problems after any spec change, and branch conventions:
  `node/<ID>-<name>` for node work, `spec/<topic>` for spec changes.
- The repository's own facts come from the repository: read its `AGENTS.md` (or `CLAUDE.md`)
  first, especially how to edit the spec, which document wins in a conflict, the spec checker's
  command and the node template (usually in `SPEC.md`). Follow them over anything here.
If the repository has no `docs/graph.yaml`, stop and say so: bringing a repository into the regime is
a separate job.

## 1. Facts first (deterministic)
- Work in a fresh worktree of `origin/main`, never in someone's checkout:
  `git fetch origin && git worktree add -b spec/triage-<issue>-<topic> <dir> origin/main`.
- Read the issue with its comments: `gh issue view <issue> --comments`. Follow its links (PRs, runs,
  logs) far enough to know what it is about.
- Run `python3 -I <this skill's dir>/nodes.py --grep <term> ...` from the worktree root, with the
  paths, tools and words the issue is about as terms. It prints every node's state (merged, open PR,
  none), deps, what it unlocks and what it **Owns**, and which specs mention each term.
- Read the specs of the 1–3 candidate nodes in full.

## 2. Decide where it fits
Pick the first that holds, and write down why the earlier ones do not:
1. **No change.** Already covered by a criterion of some node (merged or not), a duplicate, not
   actionable, or a question. Reply on the issue with the node/criterion that covers it.
2. **Amend an unmerged node** whose Purpose and Owns already cover the area, and which has **no open
   PR**: add criteria (next free AC numbers), the matching Tests and Changes items, and Risks.
   A node with an open PR or a running session is in flight: do not move its goalposts; use 3.
3. **Follow-up node** when the area belongs to a merged node, or to one in flight: a new node with
   that node in its `deps`. A merged node's spec is history; never add criteria to it.
4. **New node** when nothing owns the area.

For a new node: the next free number in the letter family whose nodes do similar work (`ids in use`
in the helper's output); a short kebab-case `name`; minimal `deps` (only what its gate truly needs);
`track` by the repository's rule; a one-sentence `summary`; a full spec from the template; and add it
to the deps of any node that must not pass without it. Size it honestly.

Every node you create or amend gets the issue on a **Resolves:** line in its spec, right after the
**Owns:** line: `**Resolves:** #<issue>` (append `, #<issue>` if the line exists). The session that
builds the node puts `Fixes #<issue>` in its PR for each one, so merging the node closes the issue.

Criteria state observable outcomes, each testable as the template requires. When the cause is not
known yet (an intermittent failure, say), the criteria are the outcome (e.g. "passes N consecutive
CI runs, recorded") plus a diagnosis criterion with a recorded run; do not guess the fix.
Every criterion must be achievable whatever the investigation finds: give a diagnosis criterion an
explicit way out (e.g. "or, if N recorded runs show no failure, that record, and the issue is closed as
not reproduced"), so a node can never block its dependants forever on something that may not recur.
Use the latest facts, not only the issue text: later runs and comments may have changed the picture.

Stop and ask the owner instead of choosing when the answer turns on a judgment only they can make:
a principle or scope change, two placements that are both reasonable and lead to different work, or
a new open decision. Interactive: ask. Unattended: follow the run's instructions for questions.

## 3. Write the change
- Edit `docs/graph.yaml` first, then the specs, as the repository's spec-editing rules say (header
  rows from the graph, current-state wording, no revision history in specs).
- Run the spec checker until it reports no problems.
- One commit, subject `Spec: <what changes>, for #<issue>`, body: the placement (1–4) and why, the
  alternatives you rejected, the nodes touched.
- Push the branch and open the PR (`gh pr create`). Body: the placement and reasoning, the new or
  changed criteria, `Refs #<issue>` (not `Fixes`: the node's PR fixes it). Remove the worktree.
- Comment on the issue: the placement in one or two sentences and the PR link. For placement 1, the
  comment is the whole result.

**Closing keywords.** GitHub closes an issue when a PR description, or a commit message that reaches main, contains a
closing keyword (close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved, with or
without a colon) followed by its number. Write one only where closing is intended (a node PR's
"Fixes #N" lines); everywhere else write "issue #N" or "Refs #N", and never quote a spec's
Resolves: line or describe what "closes" an issue next to its number.

## 4. Report
End with: the issue, the placement, the PR (or comment) URL, the nodes touched, and anything the
owner should check first.
