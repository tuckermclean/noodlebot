# A05 — node-owns

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | A04 | none | M |

**Owns:** `plugin/skills/node/check-owns-diff.py` (new), `plugin/skills/node/check-owns-diff.test.sh` (new) and its line
in the `Makefile`'s `TESTS`, its fixtures under `plugin/skills/node/testdata/owns-diff/`; in
`plugin/skills/node/SKILL.md`, the ownership and baseline checks before the PR, their evidence rows and the
`known_red` amendment; the same checks in `plugin/agents/reviewer.md`; the `known_red` line of the SMALL SPEC
AMENDMENTS rule in `scheduler/unattended.md` and `scheduler/unattended-followup.md`; their cases in
`plugin/skills/node/skill.test.sh`.

## Purpose
After this node a node built in an adopted repository stays inside the code it is about. Its PR changes only the files
it owns and the files of the nodes it depends on, every new file it adds is in its own `owns`, and the repository is
still fully covered afterwards. Its tests are judged against the failures the repository already had: an inherited
failure listed in `known_red` does not count against the node, a new one does, and a node that fixes an inherited
failure takes it off the list. In a repository without ownership, nothing changes.

## Tests
- `plugin/skills/node/check-owns-diff.test.sh` (new), fixture repositories from `testdata/owns-diff/`: a node changing
  only its own files; one also changing a dep's file (passes); one changing a non-dep's file (`NOT OWNED`, naming the
  path and its owner); one adding a file outside its `owns` (`NOT OWNED`, new); a deleted and a renamed file; a graph
  without ownership (`no ownership declared`, exit 0); an unknown commit (exit 2).
- `plugin/skills/node/skill.test.sh` (extended): the skill's and the reviewer's text name the two checks, the
  `known_red` rule and their evidence rows.

## Changes
1. **The checker.** `python3 -I plugin/skills/node/check-owns-diff.py [--repo DIR] <ID> <from> <to>` reads the graph at
   `<to>` and judges `git diff --name-status <from>...<to>`: each changed path must match the node's own `owns` or the
   `owns` of one of its direct deps; an added path must match its own. It prints the globs it used, then one
   `NOT OWNED <path> (owner: <ID or none>)` line per other path, and exits 0, 1, or 2 when git fails. A graph without
   ownership prints `no ownership declared` and exits 0. *A05-AC-1.*
2. **Before the PR.** In a repository whose graph has `owns`, the node skill runs `check-owns-diff.py` from the node's
   base to its head and `check-coverage.py` at its head. A `NOT OWNED` path follows the existing rule for files outside
   the node's **Owns:** (the owner's approval, asked as a question and recorded in the answer); a new file the node
   should own is a small amendment adding a glob to its own `owns` and **Owns:** line. Both outputs go in the PR's
   criterion → evidence table. *A05-AC-2.*
3. **The baseline.** Where the graph has a `gate`, the GREEN evidence is a run of `gate.command` whose failures are all
   in `known_red`; a failure not in the list is the node's to fix. A node whose change makes a `known_red` failure pass
   removes that entry from the graph as a small amendment in its node PR, named in its **Spec amendments** section. The
   session templates' SMALL SPEC AMENDMENTS rule says the same. *A05-AC-3.*
4. **The reviewer** checks both outputs and the gate run against `known_red`, and treats a `NOT OWNED` path without a
   recorded approval, or a coverage problem, as a finding. *A05-AC-2.*

## Gate
- **A05-AC-1** — `check-owns-diff.py` passes a node's own and its deps' files, names a non-dep's file and a new file outside the node's `owns` with their owner, and exits 0 with `no ownership declared` on a graph without ownership. *Verify:* `sh plugin/skills/node/check-owns-diff.test.sh`.
- **A05-AC-2** — The node skill and the reviewer require both checks before a PR in a repository with ownership, with their outputs as evidence, and send a `NOT OWNED` path through the owner's approval. *Verify:* `sh plugin/skills/node/skill.test.sh`.
- **A05-AC-3** — The skill, the reviewer and both session templates judge the gate run against `known_red` and let a node remove an entry it fixed as a small amendment. *Verify:* `sh plugin/skills/node/skill.test.sh`.

## Risks
- Direct deps only: a node that needs a file of a dep's dep lists that node as a dep too. That keeps the graph honest
  about what a change touches.
- A file shared by many features (a router, a registry) belongs to one node, so many planned nodes depend on it.
  That is the graph telling the truth; the reviewer watches for nodes that list deps only to get past the check.
- `known_red` matching is by the failure names the gate prints; a node whose run names failures differently from the
  adoption's run needs the reviewer's judgement, recorded in the PR.
