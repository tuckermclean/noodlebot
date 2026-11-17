# Facts: wrapit

Read offline from a directory. The input was built from the fixture `testdata/baseline/repo/` (copied to a
scratch folder), plus a `vendor/` folder made at run time (`vendor/shunit/shunit.sh`, `vendor/README`), then
`git init` and `git add -f -A`, so the vendored files are tracked. No issues file, so no issues. No credential
check: a dry run pushes nothing. The input was copied to a temporary folder first; every command below ran in
the copy.

- **Inventory** (`inventory.py --json --areas`). 11 files, mostly shell. Entrypoint `bin/wrap`; tests
  `tests/run.sh` and `tests/t_*.sh`; CI `.github/workflows/ci.yml`. One out-of-scope candidate: `vendor/`
  (vendored dependencies). One import link: `bin/wrap` sources `lib/wrap.sh`. Proposed areas: `github`, `root`,
  `lib`, `bin`, `tests`. Every file is in an area or under the candidate.
- **Docs.** `README.md` says `make test` runs the tests and names one known gap: a word longer than the width
  is not split (`tests/t_narrow.sh`). No `AGENTS.md`/`CLAUDE.md`.
- **Build and CI.** `Makefile` target `test` runs `sh tests/run.sh`; CI runs `make test` on push and pull
  request (not observed here).
- **Test paths vs the guard's defaults.** Tests live in `tests/`, which the defaults (`**/tests/**`) match, and
  `vendor/` holds no test the guard must treat specially. No `.noodlebot/roles.yaml` is needed.
- **Could not tell.** Scope, priorities, what is done, constraints, open decisions.

## The gate run (the confirmed command, run once in the temporary copy)

`make test` exited 2 (the runner exited 1):

```
sh tests/run.sh
ok   t_basic
ok   t_fold
FAIL t_narrow
summary: 2 passed, 1 failed
make: *** [Makefile:3: test] Error 1
```

`fail_pattern` `^FAIL ` matches one line, `FAIL t_narrow`; the summary line names no test and is not matched.
`known_red`: `t_narrow`. The quick gate `sh tests/run.sh tests/t_fold.sh` printed the same line format.
