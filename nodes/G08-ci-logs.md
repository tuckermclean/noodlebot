# G08 — ci-logs

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G04, R02, A10 | G09 | M |

**Owns:** in `scheduler/forge.py`, the `ci logs` operation and the `ci_logs` capability (its entry in the operation
table and in `CAPABILITIES`); in the GitHub backend (`scheduler/forges/github_misc.py`, or a new part file that
`scheduler/forges/github.py` compiles), the fetch of a run's jobs and their logs and the mapping of a refused log read
to the capability off; the operation's row in `scheduler/forges/README.md`; in the fake forge `scheduler/testdata/forge/`
(the world, `fake.py`, the fake `gh` `fakegh.py` and their fixtures), the jobs and logs of a run and a refused log read;
the new conformance cases in `scheduler/forge.test.sh`; in `plugin/skills/node/SKILL.md`, step 5's reading of a red CI
run's job log and its evidence; the same check in `plugin/agents/reviewer.md` and in `scheduler/unattended-node-update.md`;
`plugin/skills/node/skill-g08.test.sh` (new) and its line in the `Makefile`'s `TESTS`; the recorded run of
G08-AC-4 in the node PR.
**Resolves:** #211

## Purpose
After this node a session can read the log of a CI run through the forge CLI, with the App token the forge fetches
itself. A CI run of `gate.command` that is red only with `known_red` failures is then shown from its log, stripped as
A10 says and judged by the gate's pass condition, and not taken on the session's word. Today the forge CLI's `ci`
operations give a run's conclusion only, an unauthenticated log read is refused, and the owner fetches such logs by
hand and posts the failing lines on the PR (most recently on #209). A log the forge refuses to give is the capability
being off. It is never read as an empty log, and so never as a pass.

## Tests
- `scheduler/forge.test.sh` (extended, cases added only), run against both backends as G04's conformance suite is:
  `ci logs --run <id>` returns the run's jobs, each with its id, name, conclusion and log text, the same from the GitHub
  backend over the fake `gh` and from the fake forge, through the Python interface and the CLI's JSON; `--job <name>`
  returns only that job; a run with no jobs returns an empty list, and a failed call exits 1 and never an empty list.
  A log read the forge refuses (a 403 from the fake `gh`, a refusal set in the fake forge's world) exits 3 with
  `forge <name> lacks ci_logs` and prints no result. A fake forge configured without `ci_logs` fails the same way before
  any call. The README row has four filled cells (G04-AC-8's check).
- `plugin/skills/node/skill-g08.test.sh` (new): step 5 of `plugin/skills/node/SKILL.md` says that a red CI run of
  `gate.command` is judged from its job log, read with `<forge> ci logs`, stripped and matched by the gate's pass
  condition, with each failing line and its `known_red` entry in the evidence next to the run URL; and that a log the
  forge will not give (exit 3) does not pass the run: the session says so with the run URL and asks the owner (step 7).
  The same in `plugin/agents/reviewer.md` and `scheduler/unattended-node-update.md`. Each case checks one statement
  within one sentence or one window of lines.
- The recorded run of G08-AC-4.

## Changes
1. **The operation.** `forge.py` gets `("ci logs", "ci_logs", {"run": "int!", "job": "str"})` and `ci_logs` in
   `CAPABILITIES`. The result is a list of `{"id", "name", "conclusion", "log"}`, one per job of the run (only the job
   named `--job` when it is given), `log` being the job's whole log text as the forge serves it, not stripped.
   *G08-AC-1.*
2. **The GitHub backend.** It lists the run's jobs and reads each job's log through the backend's authenticated
   calls. A 403 on a log read raises the capability-off error (exit 3, `forge github lacks ci_logs`), never an empty
   log or a partial list. Any other failure is a failed call (exit 1). The README's row gives GitHub's, GitLab's,
   Gitea's and Forgejo's call, or "none: capability off", each linked to its API documentation. *G08-AC-1, G08-AC-2.*
3. **The fake forge.** Its world holds a run's jobs and logs, and can refuse a log read. The fake `gh` serves the jobs
   and logs endpoints from fixtures and can answer a log read with 403. *G08-AC-1, G08-AC-2.*
4. **The node skill reads the log.** Step 5 says that when the CI run of `gate.command` is red, the session reads its
   jobs' logs with `<forge> ci logs --run <id>`, strips each line as the pass condition says (A10) and judges the run
   by that condition. The evidence lists each failing line with the `known_red` entry it matched, next to the run URL.
   A red run whose log the forge will not give (exit 3) does not pass: the session records that the log could not be
   read, with the run URL, and asks the owner (step 7). It does not record the run as red only with `known_red`
   failures. The reviewer's CI check and the node update template say the same. A green run needs no log.
   *G08-AC-3.*
5. **The live record.** One `ci logs` call through the session's forge CLI, on a real CI run of this repository,
   is recorded in the PR. *G08-AC-4.*

## Gate
- **G08-AC-1** — `ci logs --run <id>` (and with `--job <name>`) returns the run's jobs with id, name, conclusion and log text, the same from the GitHub backend over the fake `gh` and from the fake forge, through the Python interface and the CLI; a run with no jobs gives an empty list and a failed call exits 1, never an empty result; the README has the operation's row with four filled cells. *Verify:* `sh scheduler/forge.test.sh`.
- **G08-AC-2** — A log read the forge refuses (403 from the fake `gh`, a refusal in the fake forge) and a forge configured without `ci_logs` both exit 3 naming `ci_logs`, with no result on stdout. *Verify:* `sh scheduler/forge.test.sh`.
- **G08-AC-3** — Step 5 of `plugin/skills/node/SKILL.md`, `plugin/agents/reviewer.md` and `scheduler/unattended-node-update.md` say that a red CI run of `gate.command` is judged from its job log read with `<forge> ci logs`, stripped and matched by the gate's pass condition, with each failing line and its `known_red` entry in the evidence next to the run URL, and that a log the forge will not give does not pass the run but goes to the owner with the run URL. *Verify:* `sh plugin/skills/node/skill-g08.test.sh`.
- **G08-AC-4** — Through the session's forge CLI (the App token), `ci logs --run <id>` on a real CI run of this repository returns its jobs with non-empty log text; or, if the App may not read Actions logs, the call exits 3 naming `ci_logs`, that output is recorded and the owner is asked to grant the permission (the node does not wait for it). *Verify:* the recorded command, exit code and first lines of the output in the PR.

## Risks
- GitHub serves a job's log through a redirect to a short-lived download address. The backend must follow it with
  the token kept out of argv and logs (G04-AC-3). The redirect target needs no token, so it must not get one.
- Logs can be large (`make test` writes thousands of lines). The operation returns them whole, and the session reads
  only the lines the pattern matches. A size limit, if one is needed, is a later change.
- Logs expire after the forge's retention period, and an expired log is a failed call (exit 1), not a refusal. Step
  5 reads the log of the run it just recorded, so it should not meet one.
- GitHub also answers 403 for its secondary rate limit, not only for a missing permission. Change 2 reads every
  403 on a log read as the capability off. That is the safe direction, since it never passes a run, but an exit 3
  alone does not show that the App lacks the permission: a session that meets one does not assume so, and its
  question to the owner gives the run URL and both causes.
- The App's permissions are the owner's settings. If G08-AC-4 shows a refusal, sessions keep asking the owner for a
  red run, as today, until the permission is granted.
- `scheduler/agnostic.test.sh` keeps every `gh` call and GitHub URL in the backend, and the skill text names no forge
  (R02-AC-2).
