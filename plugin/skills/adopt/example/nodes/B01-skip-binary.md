# B01 — skip-binary

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | none | none | S |

**Owns:** `lib/binary.sh`, `bin/tallyho`, `tests/test_binary.sh`
**Resolves:** #3

## Purpose

Issue 3: tallyho prints nonsense counts for a PNG. The owner's first priority. A file with a NUL
byte in its first 8 KiB is binary (open decision D5); it is skipped with a warning on stderr. The
counting this builds on is done and tested. Open decision D8: the exit status on unreadable input
is not changed here.

## Tests

`tests/test_binary.sh` makes files in a temporary directory (`printf 'a\0b\n'`, a text file, an 8192-byte
text prefix followed by a NUL) and runs `bin/tallyho` on them. Red target: `sh tests/test_binary.sh`.

## Changes

1. `lib/binary.sh`: `is_binary FILE` succeeds when a NUL byte is in the first 8192 bytes. *B01-AC-1.* *B01-AC-4.*
2. `bin/tallyho`: for each file named on the command line, skip it with `tallyho: skipping binary file: NAME` on stderr when `is_binary` succeeds, and count the rest as before. *B01-AC-1.* *B01-AC-2.* *B01-AC-3.* *B01-AC-5.*
3. `tests/test_binary.sh`: the cases in the Gate. *B01-AC-1.* *B01-AC-2.* *B01-AC-3.* *B01-AC-4.* *B01-AC-5.* *B01-AC-6.*

## Gate

- **B01-AC-1** — A file with a NUL byte in its first 8 KiB gets no row. *Verify:* `sh tests/test_binary.sh` exits 0; it runs `bin/tallyho` on `printf 'a\0b\n'` and expects empty stdout.
- **B01-AC-2** — The skip is reported on stderr and names the file. *Verify:* `sh tests/test_binary.sh` exits 0; it expects stderr to contain `skipping binary file` and the file's name.
- **B01-AC-3** — A skipped file does not change the exit status and does not stop the others. *Verify:* `sh tests/test_binary.sh` exits 0; `bin/tallyho binary.dat text.txt` prints only the text file's row and exits 0.
- **B01-AC-4** — Only the first 8 KiB decides: a NUL at byte 8193 or later is counted as text. *Verify:* `sh tests/test_binary.sh` exits 0; it counts a file of 8192 `a` bytes followed by a NUL and expects a row.
- **B01-AC-5** — Standard input is not checked, and the default output of a text file is unchanged. *Verify:* `sh tests/test_count.sh` exits 0, and `sh tests/test_binary.sh` expects `printf 'a b\n' | bin/tallyho` to print one row.
- **B01-AC-6** — A file that cannot be read is never reported as binary. *Verify:* `sh tests/test_binary.sh` exits 0; stderr of `bin/tallyho /no/such/file` does not contain `binary`.

## Risks

Detecting NUL with POSIX tools only: `tr` and `wc` on a prefix read by `dd` work under dash, but a
locale can change `tr` behaviour; the test runs with `LC_ALL=C`. `bin/tallyho` is also edited by
F01, F02 and F03; expect small merge conflicts there.
