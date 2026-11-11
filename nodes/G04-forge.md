# G04 — forge

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G02, G03 | R02 | L |

**Owns:** `scheduler/forge.py` (the forge interface, its CLI, backend selection, the capability rule), `scheduler/forge.test.sh` (the conformance suite) and its line in the `Makefile`'s `test` target; `scheduler/forges/` (the GitHub backend `github.py` with the token script call, gist publishing and the GitHub web and clone URLs; `README.md`, the operation table across forges); the fake forge and its fixtures `scheduler/testdata/forge/`; `scheduler/agnostic.test.sh` (the forge rules of the core check) and its line in the `Makefile`'s `test` target; every forge call and forge URL in core code, converted to the interface: in `scheduler/loop.sh` (the loop's `[<forge>:]<path>` argument, the clone, the PR lists, the visibility record, the token fetches, G02's update step and G03's feedback step), `scheduler/report.py`, `scheduler/issues.py`, `scheduler/labels.py`, `scheduler/feedback.py`, `scheduler/site.py`, `scheduler/api.py`, `scheduler/nbctl.py`, `scheduler/status.sh`, `scheduler/version.sh`, `scheduler/loops.sh` (passing the argument through) and `plugin/skills/triage/nodes.py`; the export of the forge CLI to sessions in `scheduler/run-session.sh`; the forge part of the README's usage; their cases in the existing `*.test.sh` files.
**Resolves:** #84

## Purpose
After this node the scheduler's code reaches the code forge only through one interface, `scheduler/forge.py`, and GitHub is its first backend instead of being wired in everywhere. A loop names its forge in its argument (`github:owner/name`; a bare `owner/name` still means GitHub). A fake forge passes the same conformance suite as the GitHub backend and runs the loop end to end with no `gh` at all. A table records how GitLab, Gitea and Forgejo would do each operation, so adding one of them later is a backend, not a rewrite. The skills and session templates keep their text until R02 converts them; this node gives them the CLI they will use.

## Tests
- `scheduler/forge.test.sh` (new), the conformance suite: one set of cases run twice, once against the GitHub backend (with the fake `gh` of `scheduler/testdata/lib/`, recording each call) and once against the fake forge (state in a folder under `scheduler/testdata/forge/`). Cases: every operation of change 2, through the Python interface and through the CLI, gives the same normalised result from the fixtures for both backends; a failed backend call exits non-zero and never reads as an empty list; the token script is run once per GitHub call and no token appears in output, logs or argv; a capability the fake forge is configured without reports itself as off, and its operation fails with a message naming it.
- `scheduler/agnostic.test.sh` (new): the core check of change 4 passes on the tree, and fails, naming file and line, on each planted form in a scratch copy: a `gh` command (at line start, after a pipe, `;`, `&&`, `$(`, a backquote, or as `"gh"` in an argument list) and a `github.com` URL, in a `.sh` and a `.py` file; a comment that names them does not fail.
- `scheduler/loop.test.sh` (extended): the argument forms `owner/name`, `github:owner/name` and `fake:<path>` choose the backend, and an unknown forge name exits 2 with a message; a loop on `owner/name` and on `github:owner/name` use the same `state/<name>/`; one end-to-end case runs a tick that starts a node, sees its PR and stops it on merge against the fake forge with a `gh` on `PATH` that fails on any call; with the fake forge lacking site publishing, the publish step logs one line and is skipped.
- The existing `*.test.sh` files: every case passes with its expectations unchanged (they run the GitHub backend over the fake `gh`), so the GitHub behaviour is unchanged.

## Changes
1. **Inventory.** The node starts from a list, in `scheduler/forges/README.md`, of every forge operation core performs once G02 and G03 are merged: each call site, the operation, and what it reads. The interface (change 2) covers exactly that list; nothing is added for a future backend. *G04-AC-1.*
2. **The interface.** `scheduler/forge.py` defines the operations core uses, in families:
   - the repository: visibility, default branch, clone URL, web URLs for the repository, an issue, a PR and a commit, the bot's and the owner's identities;
   - pull requests: list by state (number, head branch and commit, author, mergeable, merge and close times), view, create, edit title and body, comment; reviews and line comments, replies, resolving a thread;
   - issues: list by label, view with comments, create, edit, comment, close and reopen, pin and unpin;
   - labels: ensure one exists, add and remove;
   - publishing the status site (W02's gist);
   - an authenticated push of a branch.

   Results are plain data (dicts and lists, the same field names for every backend). Each backend declares its capabilities; an operation outside them raises a named error. Credentials are the backend's: the GitHub backend runs `~/.config/noodlebot/token <owner/name>` once per call and passes the token only through the environment of that call. The CLI (`forge.py <family> <operation> ...`) prints JSON for shell scripts and sessions; it takes the forge and path from `--repo [<forge>:]<path>` or from `NOODLEBOT_FORGE_REPO`. *G04-AC-2, G04-AC-3.*
3. **The GitHub backend and the converted callers.** `scheduler/forges/github.py` holds every `gh` call and every `github.com` URL that core used, with the same arguments and the same handling of failures (a failed list stops the tick, as today). Every caller in the Owns line calls the interface. `run-session.sh` exports `NOODLEBOT_FORGE_REPO` and the CLI's path (`NOODLEBOT_FORGE`) to the session; `nodes.py` uses them, and without them uses the default forge with the repository taken from `origin`. *G04-AC-4, G04-AC-6.*
4. **The core check.** `scheduler/agnostic.test.sh` scans the tracked `.sh` and `.py` files under `scheduler/` and `plugin/`, outside comments, `*.test.sh`, `scheduler/testdata/` and `scheduler/forges/github.py`, and fails on a `gh` command or a `github.com` URL, naming file and line. The session templates and skill texts are R02's and are not scanned here. *G04-AC-5.*
5. **Choosing the forge.** `loop.sh` and `loops.sh` take `[<forge>:]<path>`. `owner/name` means `github:owner/name`, and both use `state/<name>/`, `repos/<name>` and `worktrees/<name>/` as today, so no runtime folder moves. An unknown forge exits 2 with a message. *G04-AC-6.*
6. **Turning a capability off.** When the loop's backend lacks a capability core uses (site publishing, pinning, resolving threads, the visibility record), the feature is skipped and the status log says so once per loop start (`forge <name> lacks <capability>: <feature> off`); the rest carries on. *G04-AC-7.*
7. **The fake forge.** `scheduler/testdata/forge/` holds a backend that keeps PRs, issues, comments and labels as files and serves every operation of change 2, with its capabilities set per test. It is the second backend of the conformance suite and drives the end-to-end case. *G04-AC-3, G04-AC-6.*
8. **Other forges, on paper.** `scheduler/forges/README.md` has a table with one row per operation of change 2 and columns GitHub, GitLab, Gitea and Forgejo, giving each forge's API call (or "none: capability off") with a link to its API documentation. The starting point, by family:

   | Family | GitHub | GitLab | Gitea / Forgejo |
   |---|---|---|---|
   | pull requests | pulls | merge requests (`iid`, `opened`/`merged`/`closed`) | pulls (`merged` flag on closed) |
   | reviews, line comments | reviews, review comments, threads | MR discussions (resolvable) | pull reviews and their comments |
   | issues, comments | issues, issue comments | issues, notes | issues, comments (shared with pulls) |
   | labels | repository labels | project labels | repository labels |
   | visibility | `private` | `visibility` | `private` |
   | site publishing | gist | snippet | none known: capability off |
   | credentials | App token script | project or personal token | personal or app token |

   *G04-AC-8.*

## Gate
- **G04-AC-1** — `scheduler/forges/README.md` lists every forge call site of core on this node's merge base (after G02 and G03), each with its operation, and every listed operation is exported by the interface. *Verify:* `scheduler/forge.test.sh` (each operation the README lists is exported), and the list in the PR.
- **G04-AC-2** — Each operation of change 2 returns the same normalised result from the GitHub backend over the fake `gh` and from the fake forge, through the Python interface and the CLI's JSON. A failing backend call exits non-zero and never reads as an empty result. *Verify:* `scheduler/forge.test.sh`.
- **G04-AC-3** — The GitHub backend runs the token script once per call and passes the token only through that call's environment: it never appears in output, logs, argv or Git configuration. An operation outside a backend's capabilities fails with an error naming the capability. *Verify:* `scheduler/forge.test.sh`.
- **G04-AC-4** — Every existing case of the scheduler's and `nodes.py`'s tests passes with its expectations unchanged against the GitHub backend. *Verify:* `make test`.
- **G04-AC-5** — The core check passes on the tree and fails, naming file and line, on each planted form of a `gh` command and a `github.com` URL in a `.sh` and a `.py` file under `scheduler/` or `plugin/`, outside the GitHub backend; a mention in a comment passes. *Verify:* `scheduler/agnostic.test.sh`.
- **G04-AC-6** — `owner/name` and `github:owner/name` run the GitHub backend with the same runtime folders, `fake:<path>` the fake forge, and an unknown forge exits 2 with a message. A tick against the fake forge, with a `gh` on `PATH` that fails on any call, starts a node, sees its PR and stops its session when the PR is merged. *Verify:* `scheduler/loop.test.sh`.
- **G04-AC-7** — With the loop's forge lacking a capability core uses, the feature it serves is skipped, the status log says so once per loop start, and the tick carries on. *Verify:* `scheduler/loop.test.sh` (site publishing off on the fake forge).
- **G04-AC-8** — `scheduler/forges/README.md` has one row per operation of the interface, with GitHub's, GitLab's, Gitea's and Forgejo's call or "none: capability off", each linked to that forge's API documentation. *Verify:* `scheduler/forge.test.sh` (every interface operation has a row with four filled cells), and the table in the PR.

## Risks
- This rewrites the call sites of the busiest files (`loop.sh`, `report.py`). Behaviour is held by the existing tests, which keep their fake `gh`; a call whose arguments change without a test noticing would show only in production. The PR lists every converted call with its old and new form.
- The interface is shaped by GitHub's calls; the table of change 8 is the check against that, but nothing runs against GitLab, Gitea or Forgejo until a backend node for one of them.
- Sessions still run `gh` by their prompt and skills until R02. A non-GitHub loop works only for the scheduler's own calls until then.
- `site/` (the status site's page) builds GitHub links of its own; SPEC §1's principle 7 covers the scheduler, the skills and the session templates, so the page is not converted here.
- Nodes merged after this one that call the forge must use the interface: the core check fails them in `make test` otherwise.
