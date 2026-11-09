# Questions for the owner: tallyho

Facts found: a POSIX sh tool (`bin/tallyho`, `lib/count.sh`) that prints lines, words and bytes per
file or for stdin; one test (`tests/test_count.sh`, passes today via `make test`); CI runs `make test`
on push and pull request; four open issues (#1 `--json`, #2 `--top N`, #3 binary files counted as text,
#4 read defaults from `~/.tallyhorc`). Not clear from the code: what is in scope, the order of the work,
and two decisions (config format, binary detection). Reply with `ANSWER.md`; a bare "yes" accepts the
recommendation.

1. **Scope and non-goals.** Is this a small counting tool (lines, words, bytes, a table) and not a
   text-analysis suite? *Recommendation: yes; no stemming, languages, network or GUI; POSIX sh with
   only coreutils and awk.*
2. **Priorities and order.** Which issues come first? *Recommendation: #3 (the bug) first, then #1
   `--json`, then #2 `--top N`, all `track: now`; #4 (config file) `track: later`, after the options
   it configures exist.*
3. **Done versus planned.** Counting and the stdin mode look done and tested, so they are not nodes;
   everything in the README's "Planned" list is not started? *Recommendation: yes.*
4. **Principles and constraints.** *Recommendation: POSIX sh that runs under dash; no new runtime
   dependencies; the default output stays byte for byte; every option gets a test in `tests/`;
   errors to stderr, non-zero exit only on unreadable input.*
5. **Open decisions.** (a) Config file format (issue #4 leaves it open). *Default: `key=value` lines,
   never sourced shell.* (b) How to tell a binary file. *Default: a NUL byte in the first 8 KiB.*
6. **Conflicts.** The README says a total row is printed; `bin/tallyho` prints none. *Recommendation:
   follow the README, and build the total row with `--json`.* Issue #4 mentions both shell and
   `key=value`; question 5(a) settles it.
