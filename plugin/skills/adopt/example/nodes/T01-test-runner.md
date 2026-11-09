# T01 — test-runner

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | none | none | S |

**Owns:** `Makefile`, `tests/test_runner.sh`

## Purpose

`make test` runs only `tests/test_count.sh`, and CI runs `make test`. Principle 3 says every option gets
a test in `tests/`; without this node the tests of the option nodes would pass locally and never run
in CI. This node makes `make test` run every `tests/test_*.sh` and fail if any does (open decision D7).

## Tests

`tests/test_runner.sh` builds a scratch directory holding a copy of the `Makefile` and a `tests/`
with two stub tests, one passing and one failing, and runs `make test` in it. Red target:
`sh tests/test_runner.sh` (exits non-zero before the change, because the copied Makefile runs
neither stub).

## Changes

1. `Makefile`: the `test` target runs each `tests/test_*.sh` with `sh`, keeps going after a failure,
   and exits non-zero if any failed. *T01-AC-1.* *T01-AC-2.*
2. `tests/test_runner.sh`: the scratch-directory test above. *T01-AC-1.* *T01-AC-2.* *T01-AC-3.*

## Gate

- **T01-AC-1** — `make test` fails when any `tests/test_*.sh` fails. *Verify:* `sh tests/test_runner.sh` exits 0; it runs `make test` in a scratch copy with a stub `tests/test_zz.sh` containing `exit 1` and expects a non-zero status.
- **T01-AC-2** — `make test` runs every test file, not only `test_count.sh`. *Verify:* `sh tests/test_runner.sh` exits 0; its stubs print `RAN a` and `RAN b` and it expects both in the output of `make test`.
- **T01-AC-3** — The runner uses POSIX sh only. *Verify:* `grep -c bash Makefile tests/test_runner.sh` prints `0` for both files, and `make test` exits 0 on the repository.

## Risks

The test must not copy `tests/test_runner.sh` into the scratch directory, or `make test` would run
itself without end. Existing tests that print `FAIL` but exit 0 would pass silently; the runner
trusts exit status only.
