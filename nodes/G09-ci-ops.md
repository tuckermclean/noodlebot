# G09 — ci-ops

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G08, G11 | none | M |

**Owns:** in `scheduler/forge.py`, the `ci dispatch` and `ci artifact` operations, the `attempt` option of `ci logs`,
and the `ci_dispatch` and `ci_artifact` capabilities (their entries in the operation table and in `CAPABILITIES`); in
the GitHub backend (`scheduler/forges/github_misc.py`, or a new part file that `scheduler/forges/github.py` compiles),
the dispatch and the lookup of its run, the artifact's listing, download and unpacking, the jobs of a given attempt and
each job's `html_url`; the rows of `ci dispatch` and `ci artifact` in `scheduler/forges/README.md` and the attempt's
call in the `ci logs` row; in the fake forge `scheduler/testdata/forge/` (the world, `fake.py`, the fake `gh`
`fakegh.py`, and new fixtures), the dispatched runs, the artifacts, the jobs of each attempt and their web URLs; the new
conformance cases in `scheduler/forge.test.sh`, or in `scheduler/forge-g09.test.sh` (new) with its line in the
`Makefile`'s `TESTS` when `forge.test.sh` would pass its file budget; the recorded runs of G09-AC-6 in the node PR.
**Resolves:** #232

## Purpose
After this node a session can start a `workflow_dispatch` run, download a run's artifact and read the jobs and logs of
any attempt of a run through the forge CLI, with the App token the forge fetches itself. Today the forge CLI has
`ci runs`, `ci rerun` and G08's `ci logs` (the latest attempt only), so a node that needs more CI work either stops or
reaches for another client, and the only other login on the machine is the owner's own. A dispatch, an artifact or an
attempt the forge refuses is the capability being off, and a missing or expired artifact is an error that names it:
never an empty folder or a guessed run id.

## Tests
- `scheduler/forge.test.sh` (extended, cases added only; or the new `scheduler/forge-g09.test.sh`, see Risks), run
  against both backends as G04's conformance suite is, through the Python interface and the CLI's JSON:
  - `ci dispatch --workflow <file> --ref <ref> --input k=v ...` makes one dispatch with those inputs (as the fake `gh`
    records it, and in the fake forge's world) and prints `{"id": <the new run's id>}`, both when the forge's answer
    names the run and when it does not and the run is found by listing; an input without `=` or with an empty key,
    or a key given twice, exits 2 with no call made; a dispatch the forge rejects (404, 422) exits 1 with nothing on
    stdout; a dispatch whose run cannot be found within the bound exits 1 saying the dispatch was accepted and its
    run was not found, and prints no id; two new runs of the workflow on the ref exit 1 naming both, and print no id.
  - A `--workflow` that is neither a file name (`[A-Za-z0-9._-]+` ending in `.yml` or `.yaml`) nor a numeric workflow
    id exits 2 with no call made, for example `../pulls/1/merge?x=`, `a/b.yml`, `ci.yml?x=`, `ci.yml#x`, `ci%2fx.yml`
    and `ci`; through the Python interface each raises `forge.BadValue` before the backend is called. `ci.yml`,
    `ci.yaml` and `12345` are accepted.
  - The dispatch's `ref` and `inputs` reach the fake `gh` as one JSON body on stdin (`--input -`), never as `-f` or
    `-F` fields: the fake `gh` records the body and its argv, and for inputs whose values start with `@` (naming a
    file that exists), are `true`, are `123`, hold `=`, hold a newline, or are empty, each value in the recorded body
    is the exact string given, and no argv of the call holds an input's value.
  - `ci artifact --run <id> --name <name> --dir <path>` writes the artifact's files under `<path>` (created when
    missing) and prints `{"id", "name", "dir", "files"}`, `files` listing every file written, relative to `<path>`;
    a missing artifact and an expired one each exit 1 with a message naming the artifact and the run, write no file
    and leave no folder the call created; an existing non-empty `<path>` exits 1 before any download; an archive entry
    that is absolute, contains `..` or is a link exits 1 with nothing written. The fake's archive holds a file whose
    bytes are not valid UTF-8, and the file written under `<path>` has exactly those bytes; no temporary file of the
    call is left behind, in `<path>` or elsewhere, after a success or a failure. A `--name` of `x&y=1` or `a/b` reaches
    the fake `gh` only as a `-f` field of the listing's `GET` (or not at all, when the listing is filtered locally),
    never in a request path or query string.
  - `ci logs --run <id> --attempt <n>` returns the jobs of that attempt (the fixture's run has two attempts whose jobs
    and logs differ), in G08's shape; without `--attempt` the latest attempt's jobs, as G08's cases already check;
    every job of both forms has an `html_url`; an attempt the run does not have exits 1, never an empty list; an
    attempt below 1 exits 2.
  - A dispatch, an artifact read or download, and an attempt's job listing the forge refuses (a 403 from the fake
    `gh`, a refusal set in the fake forge's world) exit 3 with `forge <name> lacks ci_dispatch`, `forge <name> lacks
    ci_artifact` and `forge <name> lacks ci_logs`, and print no result. A fake forge configured without `ci_dispatch`
    or `ci_artifact` fails the same way before any call.
  - The token is in no argv, stdout or stderr of the new calls, and the artifact's download address gets no token
    (G04-AC-3's checks for the new operations).
  - The README's rows of `ci dispatch` and `ci artifact` have four filled cells (G04-AC-8's check); `forge.py ops`
    lists both operations; `forge.CAPABILITIES` has `ci_dispatch` and `ci_artifact`.
- `scheduler/forge-g11.test.sh` (G11's, unchanged) passes with the new operations in the operation table: its sweep
  covers the `str` and `list` arguments of `ci dispatch` and `ci artifact` and skips `ci artifact`'s `dir`, of kind
  `path`.
- The recorded runs of G09-AC-6.

## Changes
1. **The operations.** `forge.py` gets `("ci dispatch", "ci_dispatch", {"workflow": "str!", "ref": "str!",
   "input": "list"})`, `("ci artifact", "ci_artifact", {"run": "int!", "name": "str!", "dir": "path!"})` (`dir` a
   required argument of G11's kind `path`, a local folder, so G11's sweep skips it), an `"attempt": "int"` option on
   `ci logs`, and `ci_dispatch` and `ci_artifact` in `CAPABILITIES`. Each `--input` is
   one `key=value` (split at the first `=`, the value a string, which may be empty or hold `=`); a malformed or
   repeated key is a usage error (exit 2) before any call. `--workflow` goes into a request path, so it uses G11's
   workflow check (the one `ci runs --workflow` has, in `Forge`'s wrapper), not a copy of its own: only a workflow
   file name (`[A-Za-z0-9._-]+` ending in `.yml` or `.yaml`) or a numeric workflow id (digits only) is accepted, and
   anything else (a `/`, `..`, `?`, `#`, `%`, or no `.yml`/`.yaml` ending) raises `forge.BadValue` from the Python
   interface before the backend is called, and the CLI exits 2 with no call made. Being in the interface, it holds
   for every backend.
   *G09-AC-1, G09-AC-3.*
2. **Dispatch.** The GitHub backend notes the ids of the workflow's `workflow_dispatch` runs on the ref, then posts
   the dispatch (`actions/workflows/<workflow>/dispatches`) with `ref` and `inputs` as one JSON body on stdin
   (`--input -`, as `_api` sends a body), never as `-f` or `-F` fields: `gh api -F` reads a value starting with `@`
   as a file and turns `true` and numbers into other types, and every input must arrive as the string given. When
   the answer names the new run, that id is the result. Otherwise it
   lists those runs again, with a fresh token on each poll, until exactly one id not in its first list appears, for
   at most 60 seconds. None in time is a failed call (exit 1) saying that the dispatch was accepted, that no run was
   found, and that the caller should look with `ci runs` before dispatching again. More than one is a failed call
   naming the ids. A 403 on the dispatch is the capability off (exit 3, `forge github lacks ci_dispatch`). Any other
   failure is a failed call. The fake forge's world records each dispatch with its ref and inputs and adds a run for
   it. The fake `gh` serves the dispatch endpoint, records the body it was sent, and can answer with the run's id,
   with no body, with a run that never appears, with two runs, or with 403, 404 or 422. *G09-AC-1, G09-AC-2.*
3. **Artifact.** The backend lists the run's artifacts by name, the name passed as a `-f` field of the listing's
   `GET` (as `ci runs` passes `head_sha`) or matched locally against the listing, never pasted into the request path
   or query string. No artifact of that name, or one the forge marks
   expired, is a failed call (exit 1) whose message names the artifact and the run, and says "expired" for an expired
   one. It downloads the archive (following the redirect without the token, as G08's log read does) into a temporary
   file outside `--dir`, as bytes that are never decoded: not through `_run`, which decodes stdout as UTF-8, holds it
   in memory and stops at 60 seconds, but with the child's stdout written straight to that file and a timeout of its
   own (300 seconds). It then checks the archive entry by entry (no absolute path, no `..`, no link) before unpacking
   anything, unpacks it into the folder, and removes the temporary file on success and on failure. A 403 on the listing or the download is the capability
   off (exit 3, `forge github lacks ci_artifact`). On any failure the call writes no file and removes a folder it
   created; a folder that already exists and is not empty is refused before the download. The fake forge's world
   holds artifacts (live and expired) with their files; the fake `gh` serves the listing, the archive and a refusal.
   *G09-AC-3, G09-AC-4.*
4. **Attempts and job links.** `ci logs --attempt <n>` lists the jobs of that attempt (on GitHub
   `actions/runs/<id>/attempts/<n>/jobs`) and reads each job's log as G08 does. Each job, with or without
   `--attempt`, gets `html_url`: the job's web page as the forge gives it. An attempt the run does not have is a
   failed call (exit 1); a 403 on the attempt's job listing is `ci_logs` off (exit 3). The fake forge's world holds
   the jobs of each attempt and their web URLs, and the fake `gh` serves the attempt's endpoint. G08's fixtures and
   cases stay as they are: the attempts, the URLs and the second attempt's jobs come from new fixture files.
   *G09-AC-5.*
5. **The README.** Rows for `ci dispatch` and `ci artifact`, each giving GitHub's, GitLab's, Gitea's and Forgejo's
   call or "none: capability off", linked to its API documentation, and the attempt's call added to the `ci logs`
   row. *G09-AC-1, G09-AC-3.*
6. **The live record.** Through the session's forge CLI on this repository: one `ci logs --attempt` call and one
   `ci artifact` call, recorded in the PR. The node dispatches no workflow on this repository, because every
   workflow here that has `workflow_dispatch` deploys something. *G09-AC-6.*

## Gate
- **G09-AC-1** — `ci dispatch --workflow <file> --ref <ref>` with `--input key=value` options makes one dispatch with that ref and those inputs and prints the new run's id, from the GitHub backend over the fake `gh` (whether or not the answer names the run) and from the fake forge, through the Python interface and the CLI; a malformed or repeated input, and a `--workflow` that is neither a file name (`[A-Za-z0-9._-]+` ending in `.yml` or `.yaml`) nor a numeric id (e.g. `../pulls/1/merge?x=`, `a/b.yml`), exits 2 with no call made, and through the Python interface raises `forge.BadValue` (G11's check) before the backend is called; `ref` and `inputs` reach the fake `gh` as a JSON body on stdin and each input as the exact string given (values starting with `@` and naming a real file, `true`, `123`, holding `=` or a newline, and empty); a rejected dispatch (404, 422), a run not found within 60 seconds (the message saying the dispatch was accepted and its run not found) and two new runs each exit 1 with nothing on stdout, never a guessed id; `forge.CAPABILITIES` and `forge.py ops` have the operation and the README its row with four filled cells. *Verify:* `sh scheduler/forge.test.sh` (or `sh scheduler/forge-g09.test.sh`).
- **G09-AC-2** — A dispatch the forge refuses (403 from the fake `gh`, a refusal in the fake forge) and a fake forge configured without `ci_dispatch` exit 3 naming `ci_dispatch`, with nothing on stdout and, for the unconfigured forge, no call made. *Verify:* `sh scheduler/forge.test.sh` (or `sh scheduler/forge-g09.test.sh`).
- **G09-AC-3** — `ci artifact --run <id> --name <name> --dir <path>` writes the artifact's files under `<path>` and prints its id, name, folder and the files written, from both backends, a file of bytes that are not valid UTF-8 written byte for byte, with no temporary file left behind, through the Python interface and the CLI; a missing artifact and an expired one exit 1 naming the artifact and the run (the expired one saying so), with no file written and no folder the call created left behind; a non-empty existing folder and an archive entry that is absolute, holds `..` or is a link exit 1 with nothing written; the token is in no argv, output or download request of the call; a `--name` such as `x&y=1` reaches the listing only as a `-f` field or not at all, never in a request path or query string; the README has the operation's row with four filled cells. *Verify:* `sh scheduler/forge.test.sh` (or `sh scheduler/forge-g09.test.sh`).
- **G09-AC-4** — An artifact listing or download the forge refuses (403 from the fake `gh`, a refusal in the fake forge) and a fake forge configured without `ci_artifact` exit 3 naming `ci_artifact`, with nothing on stdout and no file written. *Verify:* `sh scheduler/forge.test.sh` (or `sh scheduler/forge-g09.test.sh`).
- **G09-AC-5** — `ci logs --run <id> --attempt <n>` returns that attempt's jobs, each with id, name, conclusion, log text and `html_url`, from both backends, and differs from the latest attempt's on a run with two; `ci logs` without `--attempt` gives each job an `html_url` too; an attempt the run lacks exits 1 and never an empty list, an attempt below 1 exits 2, and a refused attempt listing exits 3 naming `ci_logs`; G08's cases pass unchanged. *Verify:* `sh scheduler/forge.test.sh` (or `sh scheduler/forge-g09.test.sh`).
- **G09-AC-6** — Through the session's forge CLI (the App token) on this repository: `ci logs --run <id> --attempt 1` on a real run with two or more attempts returns that attempt's jobs with non-empty log text and an `html_url` each; and `ci artifact` on a real artifact of this repository writes its files, or, when every artifact the repository has is expired, the call on one exits 1 naming it as expired. A call that exits 3 is recorded with its output and the record names the exact permission to grant: the GitHub App's repository permission "Actions" at "Read-only" (for `ci logs` and `ci artifact`), and says that it applies to every repository the App is installed on (the node does not wait for it). *Verify:* the recorded commands, exit codes and first lines of output in the PR.

## Risks
- **No live dispatch here.** This repository's only workflow with `workflow_dispatch` deploys the site, so the node
  does not dispatch on it (the owner's choice); the dispatch path is shown over the fake `gh` only. The first real
  dispatch is the run that asked for it (O04's resumed run, issue #232). If it fails, that run asks the owner, and the
  fix is a follow-up node.
- **Finding the dispatched run.** GitHub's dispatch answer can name the new run (`return_run_details`); older
  answers and other forges give no id. The listing fallback can see another dispatch of the same workflow and ref
  made at the same moment. Change 2 then fails naming both ids and never picks one. The 60-second bound is a guess:
  a busy queue can create the run later, and the message then sends the caller to `ci runs`, not to a second dispatch.
- **The real boundary is the App's permission.** The forge CLI does not stop a session from dispatching: a session
  that runs the token script has the token and can call the API itself. What G09 opens up is set by the App's
  repository permission "Actions": "Read and write" lets a caller dispatch any `workflow_dispatch` workflow on any
  ref, on every repository the App is installed on, not only this one. What keeps a deploy workflow from running an
  unreviewed branch is its environment's deployment branch policy (here, `github-pages` has custom branch policies),
  not the forge CLI and not this node. Granting Actions write is the owner's decision with that reach.
- **App permissions.** A dispatch needs Actions "Read and write", and an artifact or a log needs Actions
  "Read-only". These are the owner's settings. G08-AC-4 showed whether logs can be read; G09-AC-6 shows artifacts. A
  403 is read as the capability off, and GitHub's secondary rate limit also answers 403 (G08's risk): an exit 3 does
  not prove the permission is missing.
- **Archives.** An artifact is a zip served through a redirect to a short-lived address that needs no token, and it
  is binary and can be large: Change 3 keeps it out of `_run` (no decode, no in-memory copy, its own timeout) and in a
  temporary file outside `--dir`. Unpacking checks every entry first (no absolute paths, no `..`,
  no links), so a crafted archive cannot write outside the folder.
- **Budget.** `forge.test.sh` runs both backends per case, and G08 already added many cases. If the new cases take
  the file past `TEST_FILE_BUDGET` (30 s), they go in `scheduler/forge-g09.test.sh` with its line in `TESTS`.
- **Frozen fixtures.** `ci_jobs.json` and G08's cases are frozen. The attempts, the second attempt's jobs and the
  jobs' web URLs come from new fixture files and the world, and a G08 case that would need a change is a question
  to the owner (U05).
- `scheduler/agnostic.test.sh` keeps every `gh` call and GitHub URL in the backend (R02-AC-2).
