# AGENTS.md

## Building a node

- **Building.** Build a node with `/noodlebot:node <ID>`. The role guard needs no `.noodlebot/roles.yaml`
  here, because `tests/` matches its default test globs.
- **Authority order.** `SPEC.md`, then `docs/graph.yaml`, then the node spec `nodes/<ID>-<name>.md`, then this
  file. When two disagree, the earlier one wins and the later one is fixed by a spec PR.
- **Roles.** The plugin's tester writes the failing tests, the implementer makes them pass, the reviewer
  judges the result. This repository has no role agents of its own.
- **Spec checkers.** `python3 -I <plugin dir>/skills/node/check-regime.py` and
  `python3 -I <plugin dir>/skills/node/check-coverage.py` from the repository root must print `PROBLEMS 0`
  before a spec PR is opened.
- **Gate command.** `make test` runs the whole suite (`sh tests/run.sh`); it runs in CI on the PR
  (`.github/workflows/ci.yml`). Its failure lines are `FAIL <name>`, which `fail_pattern` in the graph matches.
- **Quick gate.** In a session, run locally `sh tests/run.sh <test files>`: the red targets and the test files
  of what a change touches. It is the gate's own runner, so it prints the same `FAIL <name>` lines.
- **Known red.** The graph's `gate.known_red` lists the tests that fail today (`t_narrow`). A failing test
  that is not listed is a failure of the change. A node that fixes a listed test removes it from the list in
  its own PR.
- **Owns.** A node changes only the files it owns (its `owns` globs) and its direct deps' files, and places
  every file it adds in an area or in a node.
- **Red target.** A command that exits non-zero before the node's change and 0 after, normally
  `sh tests/run.sh tests/<test file>` for the node's own test file.
- **Tests and fixtures.** Tests are POSIX sh files `tests/t_<topic>.sh` run by `tests/run.sh`. There are no
  other fixtures. `vendor/` is third-party code and never changed.
- **Spec files:** `SPEC.md`, `docs/graph.yaml`, `nodes/` (a trailing slash marks a folder); a spec PR changes only these.
- **Porting rules.** None.
- **CI evidence.** In the node's PR, record the `make test` output of the `ci` workflow run on the PR's head
  commit, and the red target's output before and after.
