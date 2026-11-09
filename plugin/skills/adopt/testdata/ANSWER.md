# Answers (by topic)

**Scope and non-goals.** tallyho counts lines, words and bytes of text files and prints a table. It is not a text-analysis suite: no stemming, no languages, no network, no GUI. It stays POSIX sh with no dependencies beyond coreutils and awk.

**Priorities and order.** First: skip binary files (the bug, issue 3), then `--json` output (issue 1), then `--top N` (issue 2); these are `track: now`. The configuration file (issue 4) can wait: `track: later`, and it depends on the options existing.

**Done versus planned.** Counting lines, words and bytes and the stdin mode are done and tested; they are not nodes. Everything under the README's "Planned" list is not started. The total row mentioned in the README is not actually printed yet; treat that as part of the `--json` work.

**Principles and constraints.** POSIX sh only, runs under dash. No new runtime dependencies. Default output format must not change byte for byte. Every option gets a test in `tests/`. Errors go to stderr, exit status non-zero only on unreadable input.

**Open decisions.** Config file format: use `key=value` lines, not shell code (default; do not source user files). Binary detection: a NUL byte in the first 8 KiB (default).

**Conflicts.** The README says a total row is printed; the code does not. Follow the README. Issue 4 mentions both formats; the answer above settles it.
