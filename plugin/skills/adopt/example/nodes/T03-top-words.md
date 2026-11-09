# T03 — top-words

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | none | T04 | M |

**Owns:** `bin/tallyho`, `lib/words.sh`, `tests/test_top.sh`, `README.md`
**Resolves:** #2

## Purpose

`tallyho --top N FILE...` shows the N most frequent words of each file: case-insensitive, ties broken
alphabetically. No stemming and no language handling (non-goals in `SPEC.md`).

## Tests

`tests/test_top.sh` runs `bin/tallyho --top N` on temporary files with known word frequencies.
`make test` runs every `tests/test_*.sh`.

## Changes

- `lib/words.sh`: a function printing the N most frequent words (`tr`, `sort`, `uniq -c`, `awk`).
- `bin/tallyho`: parse `--top N`; reject a missing or non-numeric N with a message on stderr.
- `README.md`: document `--top`.

## Gate

- **T03-AC-1** — `--top N` lists the N most frequent words of each file with their counts, most frequent first. *Verify:* `make test` runs `tests/test_top.sh`, which compares the exact output for a file with known frequencies.
- **T03-AC-2** — Words are compared case-insensitively and ties are ordered alphabetically. *Verify:* `make test` runs `tests/test_top.sh`, which uses a file with mixed case and a tie.
- **T03-AC-3** — A missing or non-numeric N prints a usage message on stderr and exits non-zero without counting. *Verify:* `make test` runs `tests/test_top.sh`, which checks both cases' stderr and exit status.
- **T03-AC-4** — Without `--top`, the output is unchanged byte for byte. *Verify:* `make test` still passes `tests/test_count.sh` unmodified.

## Risks

"Word" means a run of letters and digits after `tr` lowercases the text; punctuation handling must be
fixed in the test so the behaviour is explicit. The exit status rule (non-zero only on unreadable
input) conflicts with a bad N: a usage error is not an input error, and the criterion above says so.
