# Questions for the owner: tallyho

Facts are in `FACTS.md`. Short version: four open issues (#1 `--json`, #2 `--top N`, #3 binary files
counted as text, #4 `~/.tallyhorc`); one test file, `tests/test_count.sh`, which `make test` runs
(it passes today); CI runs `make test`. The README promises a total row; the code prints none.
Test paths match the guard's defaults, so no `.noodlebot/roles.yaml` is needed.

Each recommendation is a proposal, not a fact; a bare "yes" accepts it.

1. **Scope and non-goals.** What is tallyho for, and what is it not? Proposal: it counts lines,
   words and bytes of text files and prints a table; not a text-analysis suite (no stemming, no
   languages, no network, no GUI); POSIX sh with coreutils and awk only.
2. **Priorities and order.** Proposal: skip binary files (#3), then `--json` (#1), then `--top N`
   (#2) as `track: now`; the config file (#4) as `track: later`, after the options exist.
3. **Done versus planned.** Proposal: counting and the stdin mode are done and tested, so they are
   not nodes; everything in the README's "Planned" list is not started.
4. **Principles and constraints.** Proposal: POSIX sh (runs under dash); no new runtime
   dependencies; default output of a text file does not change; every option gets a test in
   `tests/`; errors to stderr, exit non-zero only on unreadable input.
5. **Open decisions.** (a) Config file format; proposal `key=value` lines, never sourced.
   (b) What counts as binary; proposal a NUL byte in the first 8 KiB. (c) Anything else the issues
   leave open (JSON shape, the `--top` format, ties): I propose a default for each and list it in
   `SPEC.md` for you to change.
6. **Conflicts.** (a) The README promises a total row; the code prints none. Proposal: follow the
   README. (b) `make test` runs only `tests/test_count.sh`, so a new test file would not run in CI.
   Proposal: one small node makes `make test` run every `tests/test_*.sh`.
