# D02 — runtime-dir

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | none | none | M |

**Owns:** the runtime paths in `scheduler/loop.sh`, `scheduler/status.sh` and `scheduler/report.py` (`--worktrees` default), the loop path in `scheduler/unattended.md` and `scheduler/unattended-triage.md`, `scheduler/move-runtime.sh`, `scheduler/move-runtime.test.sh`, their cases in `scheduler/loop.test.sh` and `scheduler/report.test.sh`, the runtime-layout wording in `SPEC.md` §2, `AGENTS.md`, `README.md` and `.gitignore`.
**Resolves:** #3

## Purpose
After this node the scheduler keeps its runtime folders (`repos/`, `worktrees/`, `state/`) outside any repository checkout, under one runtime root: `$NOODLEBOT_DATA`, by default `~/.local/share/noodlebot`. No session's working folder has noodlebot's checkout among its parent folders, so no session loads noodlebot's `CLAUDE.md` or `AGENTS.md` as its own. A one-time `move-runtime.sh` moves an existing installation there while nothing runs, and repairs its worktrees.

## Tests
- `scheduler/loop.test.sh` (extended): the end-to-end loop run with `NOODLEBOT_DATA` unset (the root under the test's `HOME`) and once with it set; the fake `claude` records its working folder; afterwards the test checks the scheduler checkout for runtime folders, walks the parent folders of every recorded working folder, reads the rendered session prompts and runs `status.sh`. A run with the root inside a Git working tree must refuse to start.
- `scheduler/report.test.sh` (extended): `report.py` without `--worktrees` finds a node's worktree under the runtime root.
- `scheduler/move-runtime.test.sh` (new, added to the `Makefile`'s `test` target): a fixture installation in a temporary checkout (a clone with two worktrees and a state folder with markers); the move, a second run, and the refusals with a held `loop.lock`, a live `session.pid` and an existing target.

## Changes
1. **One runtime root.** `loop.sh` and `status.sh` take the root from `NOODLEBOT_DATA`, defaulting to `$HOME/.local/share/noodlebot`, and use `<root>/repos/<name>`, `<root>/worktrees/<name>` and `<root>/state/<name>`, where `<name>` comes from the loop's `owner/name` argument. `report.py`'s `--worktrees` defaults to `<root>/worktrees/<name>` by the same rule. Nothing creates a runtime folder in the checkout the scripts run from. *AC-1, AC-2.*
2. **Refuse a root inside a checkout.** `loop.sh` exits 2 before starting anything when the runtime root lies inside a Git working tree, and names that working tree. *AC-3.*
3. **Session prompts.** `loop.sh` renders the loop's actual path into `unattended.md` and `unattended-triage.md` (a placeholder alongside `@STATE@` and `@WT@`), so neither template names `~/gitrepos/noodlebot`. *AC-4.*
4. **`move-runtime.sh <checkout>`.** Moves `<checkout>/repos/`, `worktrees/` and `state/` to the runtime root, then runs `git worktree repair` in each moved clone with its moved worktrees, so each clone and its worktrees find each other at the new paths. It moves nothing, and says why, while a loop holds a `loop.lock` of the installation, while a process recorded in any `session.pid` is alive, or when the root already has a folder it would move onto. A run with nothing left to move says so and exits 0. *AC-5, AC-6.*
5. **Docs.** `SPEC.md` §2, `AGENTS.md`, the `README.md` and `loop.sh`'s header describe the runtime root, `NOODLEBOT_DATA` and the one-time move; `.gitignore` keeps ignoring the old folders. *AC-1.*

## Gate
- **D02-AC-1** — With `NOODLEBOT_DATA` unset, a loop run keeps its clone, worktrees and state under `$HOME/.local/share/noodlebot/{repos,worktrees,state}/<name>`; with it set, under `$NOODLEBOT_DATA/{repos,worktrees,state}/<name>`; in both runs `status.sh` and `report.py` (without `--worktrees`) read that same state and worktrees, and the checkout the scripts run from gains no `repos/`, `worktrees/` or `state/` folder. *Verify:* `scheduler/loop.test.sh`, `scheduler/report.test.sh`.
- **D02-AC-2** — The working folder of every session the loop starts, node and triage, has no Git working tree, `CLAUDE.md` or `AGENTS.md` in any of its parent folders. *Verify:* `scheduler/loop.test.sh` (the fake `claude` records `pwd -P`).
- **D02-AC-3** — `loop.sh` exits 2 and starts no session when the runtime root lies inside a Git working tree, and its message names that working tree. *Verify:* `scheduler/loop.test.sh`.
- **D02-AC-4** — The rendered prompt of a node session and of a triage session names its worktree and state folder under the runtime root and the loop by the path it runs from, and neither template contains `~/gitrepos/noodlebot`. *Verify:* `scheduler/loop.test.sh`.
- **D02-AC-5** — `move-runtime.sh <checkout>` moves an installation's clones, worktrees and state to the runtime root: afterwards `git worktree list` in each moved clone lists every worktree at its new path, `git status` succeeds in each worktree, the state's files are unchanged, and the checkout has no `repos/`, `worktrees/` or `state/` left. A second run moves nothing, says so and exits 0. *Verify:* `scheduler/move-runtime.test.sh`.
- **D02-AC-6** — `move-runtime.sh` moves nothing and exits non-zero, naming the reason, while a loop holds a `loop.lock` of the installation, while a process recorded in a `session.pid` is alive, or when the runtime root already has a folder it would move onto. *Verify:* `scheduler/move-runtime.test.sh`.

## Risks
- The move of the live installation is a step the owner takes on the machine, since sessions never stop loops: stop the loops (`touch ~/STOP`), wait until no session runs, run `move-runtime.sh ~/gitrepos/noodlebot`, start the loops again. The live checkout stays held before PR #1 until then, and D01's deploying must not be switched on before it: a deploy fast-forwards the live checkout, and while the runtime folders are still inside it, every session would load noodlebot's `CLAUDE.md` and `AGENTS.md`.
- D01 and M01 are being built at the same time and also change `scheduler/loop.sh` (and M01 the `README.md`); whichever merges second rebases. A runtime path either of them adds (D01's `state/deploy/`, M01's `loop.lock` lookup) must live under the runtime root; AC-1's check of the checkout catches one only where `loop.test.sh` runs that path.
- Every loop, `status.sh` and `move-runtime.sh` must see the same `NOODLEBOT_DATA`. A loop started from a shell with another value (a tmux server keeps its own environment) uses another root and another `loop.lock`, so two loops for one repository could run.
- A home folder that is itself a Git working tree (dotfiles kept in Git) makes the default root refused by AC-3; such a machine sets `NOODLEBOT_DATA` outside it.
- `git worktree repair` needs Git 2.30 or later. A session's working folder cannot move while it runs; the move refuses rather than leave a session in a folder that no longer exists.
