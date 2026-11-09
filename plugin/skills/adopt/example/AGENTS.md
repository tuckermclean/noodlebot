# AGENTS.md

## Building a node

- **Authority order:** `SPEC.md`, then `docs/graph.yaml`, then the node spec `nodes/<ID>-<name>.md`,
  then this file. A conflict is resolved in that order; a spec that needs changing goes through a
  `spec/<topic>` PR, not an edit inside a node's PR.
- **Role agents:** the plugin's tester, implementer and reviewer (this repository has none of its own).
  The tester writes the failing tests first; the implementer makes them pass without editing tests;
  the reviewer checks the criteria.
- **Spec checker:** `python3 -I <plugin dir>/skills/node/check-regime.py` must print `PROBLEMS 0`.
- **Commands that exist today:** `make test` (today it runs `tests/test_count.sh` and passes; node T01 makes it run every `tests/test_*.sh`) and CI,
  `.github/workflows/ci.yml`, which runs `make test` on every push and pull request. There is no linter.
- **Red target:** a command that exits non-zero before the node's change and 0 after, for example
  `sh tests/test_binary.sh`; the node's first commit adds it and shows it failing.
- **Tests and fixtures:** `tests/test_*.sh`, one script per feature, each building its inputs in a
  temporary directory; fixtures, if any, under `tests/fixtures/`.
- **Porting rules:** none.
- **CI evidence:** record the `make test` output (and the CI run's result) in the PR description.
- **Constraints for every change:** POSIX `sh` that runs under `dash`; no new runtime dependency; the
  default output stays byte for byte; errors to stderr, non-zero exit only on unreadable input.
