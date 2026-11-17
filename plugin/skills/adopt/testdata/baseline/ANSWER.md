# Answers (by topic)

**Scope and non-goals.** wrapit folds lines of text at spaces to a width. It is not a text formatter: no hyphenation, no justification, no languages. POSIX sh and awk only.

**Priorities and order.** Nothing is planned yet. The README names one known gap, a word longer than the width is not split; it is already red in the suite and stays listed as known red until it is fixed.

**Done versus planned.** Folding at spaces and the `-w` option are done and tested. Splitting an over-long word is not started.

**Principles and constraints.** POSIX sh and awk, no new dependencies. Every behaviour gets a test in `tests/`.

**Open decisions.** None.

**The gate command (question: gate).** Yes, take your recommendation: `make test`, which runs `sh tests/run.sh`. Its failure lines look like `FAIL <name>`; the summary line names no test. Use the failure pattern `^FAIL ` and list the failing test `t_narrow` in `known_red`.

**Out of scope (question: out of scope).** Yes: `vendor/` is third-party code we copy in and never change; reason: vendored code, not ours.

**Areas (question: areas).** Take the proposal, with these names: `wrap` for `bin/`, `lib/` and `README.md`; `tests` for `tests/`; `build` for `Makefile` and `.github/`.

**The quick gate.** The test runner takes a list of test files, so the quick gate is `sh tests/run.sh <test files>` for the red targets and the tests a change touches; it prints the same `FAIL <name>` lines. Yes, draft it that way.
