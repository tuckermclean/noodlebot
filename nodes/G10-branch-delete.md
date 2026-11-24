# G10 — branch-delete

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G08 | none | M |

**Owns:** in `scheduler/forge.py`, the `branch delete` operation, the `branch_delete` capability (its entry in the
operation table and in `CAPABILITIES`), the throwaway prefix list and the check of a name against it before any backend
call; in the GitHub backend (`scheduler/forges/github_misc.py`, or a new part file that `scheduler/forges/github.py`
compiles), the checks of a branch (default, protected, head or base of an open PR, missing) and its deletion, and the
mapping of a refused deletion to the capability off; the operation's row in `scheduler/forges/README.md`; in the fake
forge `scheduler/testdata/forge/` (the world, `fake.py`, the fake `gh` `fakegh.py` and their fixtures), protected
branches, the deletion of a branch of `repo.git` and a refused deletion; the new conformance cases in
`scheduler/forge.test.sh`; in `plugin/skills/node/SKILL.md`, the naming and deletion of a criterion's throwaway branch
(next to the `branch push` line); `plugin/skills/node/skill-g10.test.sh` (new) and its line in the `Makefile`'s
`TESTS`; the recorded run of G10-AC-4 in the node PR.
**Resolves:** #237

## Purpose
After this node a session can delete a throwaway branch it pushed, through the forge CLI and with the token the forge
fetches itself. Today the forge CLI can push a branch but not delete one, so a criterion that proves CI by pushing a
probe branch leaves the branch on the forge for good (two `ci-probe/` branches of another repository's node are still
there). The operation is narrow on purpose: it deletes only a branch under the throwaway prefix `ci-probe/` of the
session's own repository, and refuses the default branch, a protected branch and a branch an open PR uses. A missing
branch is reported as already gone.

## Tests
- `scheduler/forge.test.sh` (extended, cases added only), run against both backends as G04's conformance suite is:
  `branch delete --branch ci-probe/<x>` deletes the branch (afterwards it is not in the fake forge's `repo.git`, or the
  fake `gh` recorded one delete of `refs/heads/ci-probe/<x>`) and prints `{"branch": "<name>", "result": "deleted"}`; a
  second call on the same name prints `"result": "gone"` and exits 0, as does a name that never existed. Each refusal
  exits 1 with one line on stderr naming the branch and the reason, prints nothing on stdout and makes no delete call
  (the fake `gh` recorded none, `repo.git` still has the branch): a name outside the prefix (`main`, `node/G10-x`,
  `ci-probe` without the slash, `ci-probe/../main`, an empty name), the default branch, a protected branch under the
  prefix, and a branch under the prefix that is the head or the base of an open PR. A branch whose PR is merged or
  closed is deleted. A failed check call exits 1 and deletes nothing.
- The same file: a deletion the forge refuses (a 403 from the fake `gh`, a refusal set in the fake forge's world) exits
  3 with `forge <name> lacks branch_delete` and prints no result; a fake forge configured without `branch_delete` fails
  the same way before any call. The README row has four filled cells (G04-AC-8's check). G08's and G04's cases pass
  unchanged.
- `plugin/skills/node/skill-g10.test.sh` (new): `plugin/skills/node/SKILL.md` says that a branch a criterion pushes
  only to start a CI run (never a PR's head) is named `ci-probe/<ID>-<topic>`; that once its run is recorded in the
  evidence the session deletes it with `<forge> branch delete --branch <name>`; that a session of the node (a build, an
  update or a feedback session) also deletes each `ci-probe/<ID>-*` branch its PR's evidence names that is still on the
  forge; and that a deletion the forge refuses is recorded in the PR next to the branch's name and does not stop the
  session. Each case checks one statement within one sentence or one window of lines. Run under `dash` and `bash`.
- The recorded run of G10-AC-4.

## Changes
1. **The operation.** `forge.py` gets `("branch delete", "branch_delete", {"branch": "str!"})` and `branch_delete` in
   `CAPABILITIES`. It holds the throwaway prefix list (`ci-probe/` only) and refuses, before the backend is called, a
   name that does not start with a listed prefix, has nothing after it, or has a `..` or empty path segment. The
   result is `{"branch", "result"}` with `result` `deleted` or `gone`. *G10-AC-1.*
2. **The GitHub backend.** Through its authenticated calls it reads the repository's default branch, the branch
   (`.protected`; a 404 is `gone` with no delete call) and the open PRs whose head or base is the branch, refuses as
   change 1 says (exit 1), and only then deletes the branch's ref. A 422 or 404 on the delete itself (the branch went
   meanwhile) is `gone`. A 403 on the delete is the capability off (exit 3, `forge github lacks branch_delete`). Any
   other failure is a failed call (exit 1). The README's row gives GitHub's, GitLab's, Gitea's and Forgejo's calls,
   each linked to its API documentation. *G10-AC-1, G10-AC-2.*
3. **The fake forge.** Its world can list protected branches and refuse a deletion; a deletion removes the branch from
   `repo.git`. The fake `gh` serves the branch, open-PR and delete endpoints from fixtures, records each delete, and
   can answer a delete with 403. *G10-AC-1, G10-AC-2.*
4. **The node skill deletes its throwaway branches.** Next to the `branch push` line, `plugin/skills/node/SKILL.md`
   says how a criterion's throwaway branch is named and deleted, as the Tests section above says. The rule needs
   nothing from the owner: another repository's node that left such branches (the case that raised the issue) has them
   deleted by its next session once this node is merged. *G10-AC-3.*
5. **The live record.** Through the session's forge CLI on this repository: a push of `ci-probe/G10-live` (a commit of
   the node's branch, no PR), its deletion, a second deletion of the same name, and a deletion of `main`; each command,
   exit code and output is recorded in the PR. This repository's CI does not run on a push to such a branch.
   *G10-AC-4.*

## Gate
- **G10-AC-1** — `branch delete --branch <name>` deletes a branch under `ci-probe/` and prints its name with `deleted`, and prints `gone` (exit 0) for a branch that does not exist, the same from the GitHub backend over the fake `gh` and from the fake forge, through the Python interface and the CLI; it refuses (exit 1, one stderr line naming the branch and the reason, nothing on stdout, no delete call) a name outside the prefix or with an empty or `..` segment, the default branch, a protected branch and a branch that is the head or base of an open PR, and deletes one whose PR is merged or closed; a failed check call exits 1 and deletes nothing; the README has the operation's row with four filled cells. *Verify:* `sh scheduler/forge.test.sh`.
- **G10-AC-2** — A deletion the forge refuses (403 from the fake `gh`, a refusal in the fake forge) and a forge configured without `branch_delete` both exit 3 naming `branch_delete`, with no result on stdout, and G04's and G08's cases pass unchanged. *Verify:* `sh scheduler/forge.test.sh`.
- **G10-AC-3** — `plugin/skills/node/SKILL.md` says that a branch a criterion pushes only to start a CI run is named `ci-probe/<ID>-<topic>` and never heads a PR, that the session deletes it with `<forge> branch delete` once its run is recorded, that every session of the node also deletes each `ci-probe/<ID>-*` branch its PR's evidence names that is still on the forge, and that a refused deletion is recorded in the PR without stopping the session. *Verify:* `sh plugin/skills/node/skill-g10.test.sh`.
- **G10-AC-4** — Through the session's forge CLI (the App token) on this repository, `branch delete --branch ci-probe/G10-live` after a push of that branch prints `deleted` and the branch is gone from the forge, a second call prints `gone`, and `branch delete --branch main` exits 1 with `main` still on the forge; or, if the App may not delete branches, the first call exits 3 naming `branch_delete`, that output is recorded and the owner is asked to grant the permission, and the branch left on the forge is named in the PR for a later session to delete (the node does not wait for it). *Verify:* the recorded commands, exit codes and outputs in the PR, with a `git ls-remote` of `refs/heads/ci-probe/` after them.

## Risks
- The prefix list is a constant in `forge.py`. A repository whose criteria need another kind of throwaway branch gets
  it through a later node that widens the list, never by a session passing a prefix.
- A branch can be protected by a ruleset that `.protected` does not show. The delete then fails at the forge: a 403
  reads as the capability off and a 422 for a branch that still exists is a failed call, so nothing is deleted that
  the forge protects, but the error may not name the rule.
- The open-PR check and the deletion are two calls. A PR opened on the branch between them loses its head. Throwaway
  branches never head a PR (change 4), so this needs a session to break that rule first.
- The App needs the repository's contents write permission to delete a branch, which pushes already use. G10-AC-4
  records the answer; a refusal leaves throwaway branches on the forge, as today, until the owner grants it.
- `scheduler/agnostic.test.sh` keeps every `gh` call and GitHub URL in the backend, and the skill text names no forge
  (R02-AC-2).
