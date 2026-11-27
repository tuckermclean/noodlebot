# G11 — forge-path-values

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G04, G08 | none | M |

**Owns:** in `scheduler/forge.py`, the check of the values that reach a request path, a query string, a web URL or a
git argument (run before the backend is called, for the Python interface, `forge.web_url`, `forge.commit_link` and the
CLI alike), its error `forge.BadValue`, the `path` kind of its operation table and the CLI's exit 2 for a value it
rejects; in the GitHub backend (`scheduler/forges/github.py` and its part files), only what the check needs there (no
other behaviour changes); the accepted form of each such value in `scheduler/forges/README.md`; in the fake forge
`scheduler/testdata/forge/` (`fake.py`, the fake `gh` `fakegh.py` and their fixtures), a record of the calls a test can
read, if it has none; `scheduler/forge-g11.test.sh` (new) and its line in the `Makefile`'s `TESTS`.
**Resolves:** #239

## Purpose
After this node a value given to a forge operation can never point its request at another endpoint. Today
`ci runs --workflow <value>` puts the value into the API path unchecked (`scheduler/forges/github_misc.py`), so a
value holding `/`, `..`, `?`, `#` or `%` reaches another endpoint, and after a `?` the rest becomes the query string.
`commit checks --sha`, `issue comments --since`, `site publish --target`, `label remove --name` (an empty name, `.`
and `..`), `repo url --ref` with `forge.web_url` and `forge.commit_link`, and `branch push --branch` (a refspec such
as `:main` or `+main` reaches `git push`) have the same kind of gap. Each such value now has one accepted form,
checked before any call, and anything else is a usage error: `forge.BadValue` in Python, exit 2 from the CLI.

## Tests
- `scheduler/forge-g11.test.sh` (new), run against both backends as G04's conformance suite is (the GitHub backend
  over the fake `gh`, which records each call, and the fake forge), through the Python interface and the CLI:
  - `ci runs --workflow`: `test.yml`, `a-b_c.1.yaml` and `12345` make the same call as on `main`. `../pulls/1?x=`,
    `a/b.yml`, `ci.yml?x=1`, `ci.yml#x`, `%2e%2e.yml`, `ci.yml/`, `ci.txt` and an empty value exit 2, with one stderr
    line naming `--workflow`, nothing on stdout and no call recorded; in Python they raise `forge.BadValue`, which is a
    `forge.ForgeError`.
  - Each value of change 2, with its accepted and rejected examples, the same way: among the rejected ones an empty
    `label remove --name` and `site publish --target`, and `:main`, `+main`, `@`, `x#y`, `%2e%2e` and `-x` for
    `branch push --branch`. `forge.web_url` and `forge.commit_link` reject a bad ref or SHA with `forge.BadValue`, and
    `forge.py remote-commit-link URL <bad SHA>` exits 2; `forge.web_url` takes an issue number as an int and as a
    digit string, and a commit ref of 4 hex digits.
  - The sweep of change 3: for every operation `forge.py ops` lists and each of its `str` and `list` arguments
    (`forge.py`'s operation table; an argument of kind `path` is skipped), every hostile value either exits 2 with no
    call, or reaches the forge's calls only in a request body, a `-f` field or a GraphQL variable, as one
    percent-encoded path segment or query value, or not at all (a filter such as `ci logs --job`). It reads the
    operation table, so an operation added later is swept too, and a local path it adds is skipped once the table
    marks it `path`.
  - The README names the accepted form of each checked value.
- The existing `scheduler/forge.test.sh` and every other test pass unchanged (the callers' values, such as
  `deploy.sh`'s workflow, `report.py`'s `since`, the issue numbers `site.py` and `api.py` give `forge.web_url` as ints,
  and the six-digit commit ref of `scheduler/testdata/forge/iface.py`, already have the accepted forms).

## Changes
1. **The workflow and the error.** `ci runs --workflow` accepts a workflow file name (`[A-Za-z0-9._-]+` ending in
   `.yml` or `.yaml`) or a numeric workflow id, the rule G09 gives `ci dispatch --workflow`. Anything else is a usage
   error before any call. The Python interface raises `forge.BadValue` (new, in `scheduler/forge.py`) with a message
   naming the option, before the backend is called. `BadValue` subclasses `ForgeError`, so a caller that catches
   `ForgeError` (`report.py`'s ticks) records a bad value as a failed call and goes on, never a traceback. The CLI
   catches `BadValue` before `ForgeError` and exits 2 with the message as its one stderr line, printing nothing on
   stdout. The check is in the interface (`Forge`'s wrapper), so both backends get it. *G11-AC-1.*
2. **The other values that reach a path, a query, a web URL or git.** Checked the same way, raising the same
   `BadValue`:
   - `commit checks --sha` is 4 to 64 hex digits (4 is git's shortest abbreviation).
   - `issue comments --since` is a UTC timestamp as the forge gives `created_at` (`YYYY-MM-DDTHH:MM:SSZ`, with
     optional fractional seconds).
   - `site publish --target` is a gist id: one or more letters and digits.
   - `label remove --name` is not empty, not `.` and not `..`; any other name stays percent-encoded as one path
     segment. An empty name would reach `DELETE .../issues/N/labels`, which removes every label.
   - `repo url --ref` is a number (an int or a digit string) for `issue`, `pr` and `run`, and 4 to 64 hex digits for
     `commit`. `forge.web_url(spec, kind, ref)` and `forge.commit_link(url, sha)` (and so the CLI's
     `remote-commit-link URL SHA`, exit 2) make the same check themselves, since they do not go through `Forge`'s
     wrapper.
   - `branch push --branch` holds only the characters `[A-Za-z0-9._/-]`, is accepted by
     `git check-ref-format --branch` and does not start with `-`. That excludes `+`, `:`, `@`, `#` and `%`, so neither
     a force push (`+main`) nor a refspec (`:main`, `src:dst`) reaches `git push`. A rejected one makes no git call.
   *G11-AC-2.*
3. **Local paths in the table, and the sweep.** `forge.py`'s operation table marks an argument that names a local
   file or folder with the kind `path` (`site publish --input`, `branch push --path`); the CLI parses it as a string,
   as now. The new test feeds each `str` argument of each operation, and each `list` argument as a one-item list
   (`pr list --fields`, `issue create --labels`), the hostile values `../x`, `a/b`, `x?y=1`, `x#y`, `x&y=1`,
   `%2e%2e`, `.` and `..` (with plain values for the other required arguments), skipping the `path` ones, and checks
   the outcome of the Tests list. A value that reaches an endpoint through a path the check does not cover fails the
   sweep, naming the operation and the argument. *G11-AC-3.*
4. **The README.** `scheduler/forges/README.md` names, for each checked value, its accepted form, next to the
   operation's row or in a paragraph the table links to, and says that a rejected value is `forge.BadValue` (exit 2)
   and that a local path argument has the kind `path`. *G11-AC-4.*

## Gate
- **G11-AC-1** — `ci runs --workflow` with a workflow file name (`[A-Za-z0-9._-]+` ending in `.yml` or `.yaml`) or a numeric id makes the same call as before, and any other value (among them `../pulls/1?x=`, `a/b.yml`, `ci.yml?x=1`, `ci.yml#x`, `%2e%2e.yml`, `ci.yml/` and an empty value) exits 2 with one stderr line naming `--workflow`, nothing on stdout and no call made, on the GitHub backend over the fake `gh` and on the fake forge, through the CLI and the Python interface (which raises `forge.BadValue`, a subclass of `forge.ForgeError`, before the backend is called). *Verify:* `sh scheduler/forge-g11.test.sh`.
- **G11-AC-2** — `commit checks --sha` (4 to 64 hex digits), `issue comments --since` (`YYYY-MM-DDTHH:MM:SSZ`, optional fractional seconds), `site publish --target` (one or more letters and digits), `label remove --name` (not empty, `.` or `..`), `repo url --ref` (a number, int or digit string, for issue, pr and run; 4 to 64 hex digits for commit) and `branch push --branch` (only `[A-Za-z0-9._/-]`, accepted by `git check-ref-format --branch`, no leading `-`; `:main`, `+main`, `@`, `x#y` and `%2e%2e` rejected) each accept their form as before and reject anything else with exit 2 (`forge.BadValue` in Python), naming the option, before any call or git command, on both backends, through the CLI and the Python interface; `forge.web_url` and `forge.commit_link` check the same ref and SHA forms (`remote-commit-link` exits 2 on a bad SHA). *Verify:* `sh scheduler/forge-g11.test.sh`.
- **G11-AC-3** — For every operation of `forge.py ops`, each of its `str` arguments and each `list` argument (given as a one-item list), other than those the operation table marks with the kind `path` (`site publish --input`, `branch push --path`), each of the hostile values `../x`, `a/b`, `x?y=1`, `x#y`, `x&y=1`, `%2e%2e`, `.` and `..` either exits 2 with no call, or reaches the GitHub backend's recorded calls only in a request body, a `-f` field or a GraphQL variable, as one percent-encoded path segment or query value, or not at all; the sweep reads the operation table, so an added operation is swept and an added `path` argument skipped. *Verify:* `sh scheduler/forge-g11.test.sh`.
- **G11-AC-4** — `scheduler/forges/README.md` names the accepted form of each value of G11-AC-1 and G11-AC-2, `forge.BadValue` and the `path` kind, and every existing case of `scheduler/forge.test.sh` and the other tests passes unchanged. *Verify:* `sh scheduler/forge-g11.test.sh` (the README check), and `make test` in CI.

## Risks
- G09 (planned, open spec PR #235) gives `ci dispatch --workflow` the same rule and adds `ci artifact --dir`, a local
  folder. The intended order is G11 first: G09 then depends on G11, uses its check and `forge.BadValue` (one copy,
  already in the sweep) and marks `--dir` with the kind `path`. If G09 is built first anyway, G11 reuses G09's check
  instead of writing a second one, and the sweep covers G09's operations in CI. G10 (#242) may raise the same
  `BadValue` for its branch name check, so the forge CLI keeps one exit code for one kind of error.
- A caller passing a value the new forms reject (a branch name for `commit checks`, a workflow given by its display
  name) would now fail with exit 2 where it reached GitHub before. The node checks every caller in `scheduler/` and
  the session templates before it narrows a form, and a caller that needs another form is a question for the owner,
  not a widened rule.
- `BadValue` is a `ForgeError`, so a caller that catches `ForgeError` sees a bad value as a failed call: the loop keeps
  going, but a caller bug shows only as a failed call in its record, not as a traceback.
- The sweep runs every operation with eight values on two backends. Run in one Python process where it can, it must
  stay under the 30 s file budget; each call through the fake `gh` is a process.
- `branch push --branch` reaches `git push`, not an API path. It is in scope because a refspec such as `:main` or
  `src:dst`, or a force push such as `+main`, would delete or overwrite another branch through the same CLI. Sessions
  push `node/*` and `spec/*` branches (and G10, planned, `ci-probe/*` ones), which the accepted form keeps.
- The check limits what a caller of the forge CLI can reach through it; it is not a boundary against a session that
  holds the token, which can call the API directly. What a token may do is set by the App's permissions.
