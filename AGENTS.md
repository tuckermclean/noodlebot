# AGENTS.md

Agent guidance for noodlebot. Architecture and principles are in `SPEC.md`; usage is in `README.md`.

## Where things are

- `scheduler/`: the loop and its helpers, each with a `*.test.sh` next to it; `scheduler/testdata/`.
- `plugin/`: the Claude Code plugin (skills `node` and `triage`, the regime checker).
- `docs/graph.yaml` and `nodes/`: this repository's planned work, under the graph regime.
- `.claude/agents/`: this repository's role agents.
- Never committed: `repos/`, `worktrees/`, `state/` (runtime) and anything under `~/.config/noodlebot/`
  (credentials).

## Commands

- `make test`: every test (ready, release-markers, report, issues, regime checker, and the end-to-end
  loop test with fake `gh` and `claude`). Offline, under a minute.
- `python3 -I plugin/skills/node/check-regime.py`: checks `docs/graph.yaml` against `nodes/`.
- `scheduler/status.sh [owner/name]`: one repository's scheduler at a glance.

## Building a node

Build a node with `/noodlebot:node <ID>`. This section is this repository's part of it.

- **Authority:** `SPEC.md`, `docs/graph.yaml`, the node spec `nodes/<ID>-<name>.md`, then this file.
- **Role agents:** `noodlebot-tester`, `noodlebot-implementer` and `noodlebot-reviewer`
  (`.claude/agents/`). No guard hook holds them to their roles yet (node R01): the orchestrator's
  checks of each handoff do (`git show --stat` of a RED commit touches only test paths, and so on).
- **Spec checker:** `python3 -I plugin/skills/node/check-regime.py` (PROBLEMS 0). **Decisions
  table:** SPEC §4.
- **Tests:** `make test` is both the quick gate and the whole suite. Tests are the `*.test.sh` files
  and `scheduler/testdata/` (the frozen paths). A red target has the form
  `sh scheduler/<name>.test.sh` (or `bash` for `loop.test.sh`). A new script gets its own
  `*.test.sh`, added to the `Makefile`'s `test` target.
- **Porting rules:** none; noodlebot ports nothing.
- **CI evidence:** `.github/workflows/test.yml` runs `make test` on the PR; record the run URL. Behaviour
  that needs a live loop, real GitHub or real Claude sessions is shown by the end-to-end test with fakes;
  where a criterion needs more, it says what to record.

## Constraints on every change

- Never edit a script in place that a running loop or session may be executing (`scheduler/*.sh`,
  `~/.config/noodlebot/token`): write a new file and rename it over the old one.
- Sessions work only in their worktree. They never change the live checkout `~/gitrepos/noodlebot`,
  never start, stop or restart a loop, and never read `~/.config/noodlebot/` except by running the
  token script.
- Nothing names one repository: take it from the loop's `owner/name` argument.
- The scheduler never depends on the status issue: `report.py`'s failures are logged and ignored.

## Traps

- **Bash reads scripts incrementally.** An in-place edit makes a running script resume at its old byte
  offset in the new text.
- **`pgrep -f` matches its own shell** and a session's prompt text. Find sessions through
  `state/<name>/node/<ID>/session.pid` and `/proc/<pid>/cmdline`.
- **App tokens expire after an hour.** A wait loop fetches a fresh token on every poll and treats a
  failed `gh` call as an error.
- **Container-made files** in worktrees belong to podman's subordinate ids; remove them with
  `podman unshare rm -rf` when plain `rm` fails.
- **Worktree sessions also load skills and agents from the clone's main checkout**, so the loop keeps
  that checkout on `origin/main`.
- **Closing keywords** ("closes #N" and the like) in a PR body or a commit message reaching `main` close
  the issue on merge.
