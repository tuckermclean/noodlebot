# G11 — forge-path-values

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G04, G08 | none | M |

**Owns:** in `scheduler/forge.py`, the check of the values that reach a request path, a query string, a web URL or a
git argument (run before the backend is called, for the Python interface and the CLI alike) and the CLI's exit 2 for
a value it rejects; in the GitHub backend (`scheduler/forges/github.py` and its part files), only what the check needs
there (no other behaviour changes); the accepted form of each such value in `scheduler/forges/README.md`; in the fake
forge `scheduler/testdata/forge/` (`fake.py`, the fake `gh` `fakegh.py` and their fixtures), a record of the calls a
test can read, if it has none; `scheduler/forge-g11.test.sh` (new) and its line in the `Makefile`'s `TESTS`.
**Resolves:** #239

## Purpose
After this node a value given to a forge operation can never point its request at another endpoint. Today
`ci runs --workflow <value>` puts the value into the API path unchecked (`scheduler/forges/github_misc.py`), so a
value holding `/`, `..`, `?`, `#` or `%` reaches another endpoint, and after a `?` the rest becomes the query string.
`commit checks --sha`, `issue comments --since`, `site publish --target`, `label remove --name` (`.` and `..`),
`repo url --ref` and `branch push --branch` (a refspec such as `:main` reaches `git push`) have the same kind of gap.
Each such value now has one accepted form, checked before any call, and anything else is a usage error (exit 2).

## Tests
- `scheduler/forge-g11.test.sh` (new), run against both backends as G04's conformance suite is (the GitHub backend
  over the fake `gh`, which records each call, and the fake forge), through the Python interface and the CLI:
  - `ci runs --workflow`: `test.yml`, `a-b_c.1.yaml` and `12345` make the same call as on `main`. `../pulls/1?x=`,
    `a/b.yml`, `ci.yml?x=1`, `ci.yml#x`, `%2e%2e.yml`, `ci.yml/`, `ci.txt` and an empty value exit 2, with one stderr
    line naming `--workflow`, nothing on stdout and no call recorded.
  - Each value of change 2, with an accepted and a rejected example each, the same way.
  - The sweep of change 3: for every operation `forge.py ops` lists and each of its string arguments except those
    naming a local file (`site publish --input`, `branch push --path`), every hostile value either exits 2 with no
    call, or reaches the forge's calls only in a request body, a `-f` field or a GraphQL variable, as one
    percent-encoded path segment or query value, or not at all (a filter such as `ci logs --job`). It reads the
    operation table, so an operation added later is swept too.
  - The README names the accepted form of each checked value.
- The existing `scheduler/forge.test.sh` and every other test pass unchanged (the callers' values, such as
  `deploy.sh`'s workflow and `report.py`'s `since`, already have the accepted forms).

## Changes
1. **The workflow.** `ci runs --workflow` accepts a workflow file name (`[A-Za-z0-9._-]+` ending in `.yml` or
   `.yaml`) or a numeric workflow id, the rule G09 gives `ci dispatch --workflow`. Anything else is a usage error
   before any call: the CLI exits 2 with one stderr line naming the option and prints nothing, and the Python
   interface raises before the backend is called. The check is in the interface (`scheduler/forge.py`), so both
   backends get it. *G11-AC-1.*
2. **The other values that reach a path, a query, a web URL or git.** Checked the same way, in the same place:
   `commit checks --sha` is 7 to 64 hex digits. `issue comments --since` is a UTC timestamp as the forge gives
   `created_at` (`YYYY-MM-DDTHH:MM:SSZ`, with optional fractional seconds). `site publish --target` is a gist id
   (letters and digits only). `label remove --name` may not be `.` or `..` (any other name stays percent-encoded as
   one path segment). `repo url --ref` is a number for `issue`, `pr` and `run`, and 7 to 64 hex digits for `commit`.
   `branch push --branch` is a name that `git check-ref-format --branch` accepts and that holds no `:` and does not
   start with `-`; a rejected one makes no git call. *G11-AC-2.*
3. **The sweep.** The new test feeds each string argument of each operation (except the local file arguments
   `site publish --input` and `branch push --path`) the hostile values `../x`, `a/b`,
   `x?y=1`, `x#y`, `x&y=1`, `%2e%2e`, `.` and `..` (with plain values for the other required arguments), and
   checks the outcome of the Tests list. A value that reaches an endpoint through a path the check does not cover
   fails the sweep, naming the operation and the argument. *G11-AC-3.*
4. **The README.** `scheduler/forges/README.md` names, for each checked value, its accepted form, next to the
   operation's row or in a paragraph the table links to. *G11-AC-4.*

## Gate
- **G11-AC-1** — `ci runs --workflow` with a workflow file name (`[A-Za-z0-9._-]+` ending in `.yml` or `.yaml`) or a numeric id makes the same call as before, and any other value (among them `../pulls/1?x=`, `a/b.yml`, `ci.yml?x=1`, `ci.yml#x`, `%2e%2e.yml`, `ci.yml/` and an empty value) exits 2 with one stderr line naming `--workflow`, nothing on stdout and no call made, on the GitHub backend over the fake `gh` and on the fake forge, through the CLI and the Python interface (which raises before the backend is called). *Verify:* `sh scheduler/forge-g11.test.sh`.
- **G11-AC-2** — `commit checks --sha` (7 to 64 hex digits), `issue comments --since` (`YYYY-MM-DDTHH:MM:SSZ`, optional fractional seconds), `site publish --target` (letters and digits), `label remove --name` (not `.` or `..`), `repo url --ref` (a number for issue, pr and run; 7 to 64 hex digits for commit) and `branch push --branch` (accepted by `git check-ref-format --branch`, no `:`, no leading `-`) each accept their form as before and reject anything else with exit 2, naming the option, before any call or git command, on both backends, through the CLI and the Python interface. *Verify:* `sh scheduler/forge-g11.test.sh`.
- **G11-AC-3** — For every operation of `forge.py ops` and each of its string arguments other than a local file (`site publish --input`, `branch push --path`), each of the hostile values `../x`, `a/b`, `x?y=1`, `x#y`, `x&y=1`, `%2e%2e`, `.` and `..` either exits 2 with no call, or reaches the GitHub backend's recorded calls only in a request body, a `-f` field or a GraphQL variable, as one percent-encoded path segment or query value, or not at all; the sweep reads the operation table, so an added operation is swept. *Verify:* `sh scheduler/forge-g11.test.sh`.
- **G11-AC-4** — `scheduler/forges/README.md` names the accepted form of each value of G11-AC-1 and G11-AC-2, and every existing case of `scheduler/forge.test.sh` and the other tests passes unchanged. *Verify:* `sh scheduler/forge-g11.test.sh` (the README check), and `make test` in CI.

## Risks
- G09 (planned, open spec PR #235) is asked to give `ci dispatch --workflow` the same rule. Whichever node lands
  second uses the first one's check instead of a second copy, and the sweep of G11-AC-3 then covers G09's operations
  too: a G09 merged after G11 meets the sweep in CI.
- A caller passing a value the new forms reject (a branch name for `commit checks`, a workflow given by its display
  name) would now fail with exit 2 where it reached GitHub before. The node checks every caller in `scheduler/` and
  the session templates before it narrows a form, and a caller that needs another form is a question for the owner,
  not a widened rule.
- The sweep runs every operation with eight values on two backends. Run in one Python process where it can, it must
  stay under the 30 s file budget; each call through the fake `gh` is a process.
- `branch push --branch` reaches `git push`, not an API path. It is in scope because a refspec such as `:main` or
  `src:dst` would delete or overwrite another branch through the same CLI. Sessions push `node/*` and `spec/*`
  branches (and G10, planned, `ci-probe/*` ones), which the accepted form keeps.
- The check limits what a caller of the forge CLI can reach through it; it is not a boundary against a session that
  holds the token, which can call the API directly. What a token may do is set by the App's permissions.
