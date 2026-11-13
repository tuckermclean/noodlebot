# AGENTS.md

## Building a node

- **Building.** Build a node with `/noodlebot:node <ID>`. The role guard needs no
  `.noodlebot/roles.yaml` here, because `tests/` matches its default test globs.
- **Authority order.** `SPEC.md`, then `docs/graph.yaml`, then the node spec `nodes/<ID>-<name>.md`,
  then this file. When two disagree, the earlier one wins and the later one is fixed by a spec PR.
- **Roles.** The plugin's tester writes the failing tests, the implementer makes them pass, the
  reviewer judges the result. This repository has no role agents of its own.
- **Spec checker.** `python3 -I <plugin dir>/skills/node/check-regime.py` from the repository root
  must print `PROBLEMS 0` before a spec PR is opened.
- **Commands that exist today.** `make test` (runs `tests/test_count.sh`; after node T01, every
  `tests/test_*.sh`). `dash tests/test_<topic>.sh` runs one test under dash. There is no linter; use
  `sh -n <file>` on every shell file touched. CI (`.github/workflows/ci.yml`) runs `make test` on push
  and pull request.
- **Red target.** A command that exits non-zero before the node's change and 0 after, normally
  `sh tests/test_<topic>.sh` for the node's own test file (the node spec's Tests section names it).
- **Tests and fixtures.** Tests are POSIX sh files `tests/test_<topic>.sh` that make their own files in
  a `mktemp -d` directory and remove it on exit. There are no other fixtures. Every option gets a
  test.
- **Spec files:** `SPEC.md`, `docs/graph.yaml`, `nodes/` (a trailing slash marks a folder); a spec PR changes only these.
- **Porting rules.** None.
- **Constraints.** POSIX sh, runs under dash; no new runtime dependency beyond coreutils and awk;
  the default output of a text file never changes; errors to stderr and exit non-zero only on
  unreadable input; user files are never sourced.
- **CI evidence.** In the node's PR, record the `make test` output of the `ci` workflow run on the
  PR's head commit, and the red target's output before and after.
