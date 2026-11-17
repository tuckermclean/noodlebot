# A05 — node-owns

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | A04 | A08 | M |

**Owns:** `plugin/skills/node/check-owns-diff.py` (new), `plugin/skills/node/check-owns-diff.test.sh` (new) and its line
in the `Makefile`'s `TESTS`, its fixtures under `plugin/skills/node/testdata/owns-diff/`; in
`plugin/skills/node/SKILL.md`, the ownership and baseline checks before the PR, their evidence rows, and the `owns` and
`known_red` amendments in step 7's small-amendment rule and the `--update` step's resolution of them, the freezing of
imported tests, and the gate's pass condition wherever the skill requires the
repository's tests to pass (GREEN, the `--update` step that stops on a failing test, the feedback steps); the same in
`plugin/agents/tester.md`, `plugin/agents/implementer.md` and `plugin/agents/reviewer.md` (its checks and its GREEN
re-run); the gate's pass condition in `scheduler/unattended-node-update.md`; the `owns` and `known_red` lines of the
SMALL SPEC AMENDMENTS rule in `scheduler/unattended.md` and `scheduler/unattended-followup.md`; their cases in
`plugin/skills/node/skill.test.sh`.

## Purpose
After this node a node built in an adopted repository stays inside the code it is about. Its PR changes only the files
it owns and the files of the nodes it depends on, every file it adds is placed (in its own `owns`, or in a folder a dep
owns), and the repository is still fully covered afterwards. Its tests are judged against the failures the repository
already had: an inherited failure listed in `known_red` does not count against the node, a new one does, and a node
that fixes an inherited failure takes it off the list. In a repository without ownership, nothing changes.

## Tests
- `plugin/skills/node/check-owns-diff.test.sh` (new), fixture repositories from `testdata/owns-diff/` whose branches
  merge their main branch in partway: a node changing only its own files (exit 0); one also changing a dep's file
  (exit 0); one changing a non-dep's file (exit 1, `NOT OWNED` naming the path and its owner); one adding a file in a
  folder a dep owns (exit 0); one adding a file that nothing covers (exit 1); a deleted file judged by its old path; a
  renamed file judged by both paths; files that came from main through the merge (not judged); a branch that adds a dep
  to its own graph entry (judged with the deps at main, so the dep's file is `NOT OWNED`); changes to the regime's own
  files (exempt); a graph without ownership (`no ownership declared`, exit 0); an unknown commit (exit 2).
- `plugin/skills/node/skill.test.sh` (extended): the skill's and the reviewer's text name the two checks (coverage
  judged against `origin/main`), the gate's pass condition including a non-zero exit with no matched line, its
  evidence, the three amendments and their conflict resolution, and the freezing of imported tests, in the skill, the
  agents and the templates.

## Changes
1. **The checker.** `python3 -I plugin/skills/node/check-owns-diff.py [--repo DIR] <ID> <from> <to>` judges
   `git diff --name-status <from>...<to>` (from their merge base, so files merged in from main are not the node's).
   Run as `<ID> origin/main HEAD`. It reads the node's deps from the graph at `<from>`, so a branch cannot widen them,
   and its own `owns` from the graph at `<to>`. Each changed path must match the node's own `owns` or a direct dep's;
   an added path must match its own `owns` or lie under a dep's; a deleted path is judged by its old path, a renamed
   one by both. The regime's own files are exempt, as in A04. It prints the globs it used, then one
   `NOT OWNED <path> (owner: <ID or none>)` line per other path, and exits 0, 1, or 2 when git fails. A graph without
   ownership prints `no ownership declared` and exits 0. The regime's own files come from A02's `owns.py`.
   *A05-AC-1.*
2. **Before the PR.** In a repository whose graph has `owns`, the node skill runs `check-owns-diff.py <ID> origin/main
   HEAD`, and `check-coverage.py` at its head and at `origin/main`: only the coverage problems at the head that are not
   at `origin/main` are the node's. A `NOT OWNED` path follows the existing rule for files outside the node's
   **Owns:** (the owner's approval, asked as a question and recorded in the answer). Both outputs go in the PR's
   criterion → evidence table. *A05-AC-2.*
3. **The amendments.** In step 7's small-amendment rule and the templates' SMALL SPEC AMENDMENTS, these are small
   amendments in the node PR, named in its **Spec amendments** section, and the graph changes a node PR may make:
   adding a glob to the node's own `owns` (and its **Owns:** paragraph) for an added path no other node's glob matches;
   removing a `known_red` entry its change makes pass; and removing a dep's glob that the node's change (a deleted or
   moved file) leaves matching nothing. A conflict with `main` in these lines is resolved by keeping both sides,
   without a question. *A05-AC-3.*
4. **The baseline.** Where the graph has a `gate`, "the repository's tests pass" means, everywhere the skill, the
   agents and the templates require it (the tester's and implementer's own checks, GREEN, the reviewer's re-run, an
   update's or a feedback session's test run): `gate.command` exits 0; or it exits non-zero, `fail_pattern` matches at
   least one line of its output, and each matched line contains a `known_red` entry. With an empty `known_red` (or no
   `fail_pattern`) it must exit 0; a non-zero exit with no matched line (a crash, a missing tool) fails. The evidence lists each failing line with the entry it
   matched. A failing line no entry matches is the node's to fix. *A05-AC-3.*
5. **The reviewer** checks both outputs, the gate run's failing lines against `known_red`, and the amendments, and
   treats a `NOT OWNED` path without a recorded approval, a new coverage problem or an unmatched failure as a finding.
   *A05-AC-2.*
6. **Imported tests are frozen.** The tests an imported or pinned node's criteria name in their *Verify* are frozen like
   an earlier node's tests: a node may add cases, not change or remove one, without the owner's approval. *A05-AC-3.*

## Gate
- **A05-AC-1** — `check-owns-diff.py` passes a node's own and its deps' files and an added file under a dep's folder, names a non-dep's file and an uncovered new file with their owner, ignores files merged in from main, reads deps at `<from>`, exempts the regime's files, and exits 0 with `no ownership declared` on a graph without ownership. *Verify:* `sh plugin/skills/node/check-owns-diff.test.sh`.
- **A05-AC-2** — The node skill and the reviewer require both checks before a PR in a repository with ownership, with their outputs as evidence, and send a `NOT OWNED` path through the owner's approval. *Verify:* `sh plugin/skills/node/skill.test.sh`.
- **A05-AC-3** — Wherever the skill, the tester, the implementer, the reviewer and the update template require the tests to pass, a gate run passes when it exits 0, or exits non-zero with at least one line `fail_pattern` matches and each such line containing a `known_red` entry (a non-zero exit with no matched line fails), with the matches as evidence; the skill and both session templates allow the three amendments of change 3, resolve their conflicts by keeping both sides, and freeze the tests imported nodes name. *Verify:* `sh plugin/skills/node/skill.test.sh`.

## Risks
- Direct deps only: a node that needs a file of a dep's dep lists that node as a dep too, which keeps the graph honest
  about what a change touches.
- A file shared by many features (a router, a registry) belongs to one node, so many planned nodes depend on it. The
  reviewer watches for deps added only to get past the check.
- `known_red` matching is by text within the lines `fail_pattern` picks; an entry too short to be specific would hide
  new failures. A06 records whole test names, and the reviewer reads the matches.
