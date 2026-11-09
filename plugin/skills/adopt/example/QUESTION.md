# Questions for the owner: tallyho

Facts found (from the directory, offline; `issues.json` stood in for `gh issue list`):
- `bin/tallyho` calls `count_stream` from `lib/count.sh` for each file, or for stdin when no file is
  given. Each row is `lines words bytes name`. `README.md` says it prints "a total row"; the code
  prints none.
- One test, `tests/test_count.sh`; `make test` runs only that file and passes today. CI
  (`.github/workflows/ci.yml`) runs `make test` on push and pull request. There is no linter and no
  `AGENTS.md`.
- Open issues: #1 `--json`, #2 `--top N`, #3 binary files counted as text (bug), #4 `~/.tallyhorc`
  (the body does not say shell or key=value).
- The README's "Planned" list repeats the four issues. No other docs.

I could not tell: scope, order, what is done, constraints, the formats the issues leave open.

1. **Scope and non-goals.** What is tallyho for, and what is it not? Recommendation: it counts lines,
   words and bytes of text files and prints a table; not a text-analysis suite (no stemming, no
   languages, no network, no GUI); POSIX sh with coreutils and awk only.
2. **Priorities and order.** Which work first, which can wait? Recommendation: skip binary files (#3),
   then `--json` (#1), then `--top N` (#2) as `track: now`; the config file (#4) as `track: later`,
   after the options exist.
3. **Done versus planned.** Recommendation: counting and the stdin mode are done and tested, so they
   are not nodes; everything in the README's "Planned" list is not started.
4. **Principles and constraints.** Recommendation: POSIX sh (runs under dash); no new runtime
   dependencies; default output of a text file does not change; every option gets a test in
   `tests/`; errors to stderr, exit non-zero only on unreadable input.
5. **Open decisions with a default.** (a) Config file format; recommendation `key=value` lines, never
   sourced. (b) What counts as binary; recommendation a NUL byte in the first 8 KiB. (c) Anything
   else the issues leave open (JSON shape, the `--top` format, ties); recommendation: I propose a
   default for each and list it in `SPEC.md` for you to change.
6. **Conflicts or unclear facts.** (a) The README promises a total row; the code prints none. Which
   wins? Recommendation: follow the README. (b) Issue #4 does not say which format; see 5a.
   (c) `make test` runs only `tests/test_count.sh`, so a new test file would not run in CI unless the
   Makefile changes. Should a node make `make test` run every `tests/test_*.sh`? Recommendation: yes,
   one small node.
