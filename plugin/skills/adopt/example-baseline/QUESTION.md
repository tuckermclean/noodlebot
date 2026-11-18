# Questions for the owner: wrapit

Facts are in `FACTS.md`. Short version: a small POSIX sh and awk tool (`bin/wrap`, `lib/wrap.sh`), three tests
under `tests/` run by `make test` (`sh tests/run.sh`), CI runs `make test`. `make test` fails today: `t_narrow`
(the README's known gap). A `vendor/` folder is tracked. No issues were read (offline).

Each recommendation is a proposal, not a fact; a bare "yes" accepts it.

1. **Scope and non-goals.** What is wrapit for, and what is it not? Proposal: it folds lines of text at spaces
   to a width; not a text formatter (no hyphenation, no justification, no languages); POSIX sh and awk only.
2. **Priorities and order.** Proposal: nothing is planned yet; the README's known gap (a word longer than the
   width is not split) stays listed as known red until it is fixed.
3. **Done versus planned.** Proposal: folding at spaces and `-w` are done and tested; splitting an over-long
   word is not started.
4. **Principles and constraints.** Proposal: POSIX sh and awk, no new dependencies; every behaviour gets a test
   in `tests/`.
5. **Open decisions.** Proposal: none.
6. **The gate command.** Proposal: `make test` (it runs `sh tests/run.sh`; CI runs the same). I ran it once in
   a copy: it prints `ok   <name>` or `FAIL <name>` per test and a summary line that names no test. Proposed
   `fail_pattern`: `^FAIL `. Failing today: `t_narrow`, to be listed in `known_red`.
7. **Out of scope.** Proposal: `vendor/` (the inventory's candidate: vendored dependencies), reason: vendored
   code, not ours, never changed here.
8. **Areas.** Proposal, the inventory's, with fewer and clearer names: `wrap` for `bin/`, `lib/` and
   `README.md`; `tests` for `tests/`; `build` for `Makefile` and `.github/`.
9. **The quick gate.** The test runner takes a list of test files and prints the same `FAIL <name>` lines.
   Proposal: the quick gate is `sh tests/run.sh <test files>` for the red targets and the tests a change
   touches, run locally; the whole `make test` stays the gate that runs in CI.
