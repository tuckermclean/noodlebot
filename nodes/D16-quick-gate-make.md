# D16 — quick-gate-make

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D09, D11, G04 | none | S |

**Owns:** in the `Makefile`'s `test` target, the clearing of the outer make's variables (`MAKEFLAGS`, `MAKEOVERRIDES`,
`MFLAGS`, `MAKELEVEL`) beside G04's clearing of the forge variables; `scheduler/runtests-d16.test.sh` (new) and its
line in the `Makefile`'s `TESTS`; the record of the frozen paths' diff in the node's PR.
**Resolves:** #173

## Purpose
After this node a test file that runs `make` itself gives the same result under the quick gate
(`TEST_JOBS=2 make test TESTS="<files>"`, D09) as when it is run directly. Today GNU make passes its command-line
variables and flags to every recipe in `MAKEFLAGS`, so the `TESTS=<files>` of the quick gate reaches the `make test`
that `scheduler/deploy.sh` runs inside `scheduler/deploy-d04.test.sh`. That inner make then runs the outer list
instead of its fixture's, and 13 D04 checks fail under the quick gate while `sh scheduler/deploy-d04.test.sh` passes
(seen on `main` at d75a5fe and 906abb5). CI runs a plain `make test` and is not affected. Afterwards the `Makefile`'s
`test` target starts `scheduler/runtests.sh` without the outer make's variables, so no test file inherits them.

## Tests
- `scheduler/runtests-d16.test.sh` (new). It runs every `make` of its own with `MAKEFLAGS`, `MAKEOVERRIDES`, `MFLAGS`
  and `MAKELEVEL` removed from the environment, so its result does not depend on how it is run itself.
  - A fake test file in a scratch folder runs `make -s -C <fixture> test` on a fixture Makefile whose own `TESTS` is
    `fixture-list` and whose recipe prints `TESTS=[$(TESTS)] OUTER=[$(D16_OUTER)] MAKEFLAGS=[$(MAKEFLAGS)]`. The fake
    also prints whether `MAKEFLAGS`, `MAKEOVERRIDES`, `MFLAGS` and `MAKELEVEL` are set in its own environment. The test
    runs the repository's `test` target on it, `make -k -C <checkout> test TESTS="<fake>" D16_OUTER=1`. It checks that
    the inner make prints `TESTS=[fixture-list]` and an empty `OUTER`, that `k` is not among the inner make's flags
    (only the flag word of the printed `MAKEFLAGS` is read, the part before any ` -- `: the fake's path contains a `k`,
    and in the control the overrides are printed in the same variable), and that none of the four variables is set in
    the fake's environment.
  - The control: a planted Makefile in the scratch folder whose `test` recipe is `sh scheduler/runtests.sh $(TESTS)`
    (no clearing), run from the checkout as `make -k -f <planted Makefile, absolute path> -C <checkout> test
    TESTS="<fake>" D16_OUTER=1`, so that the recipe's relative `scheduler/runtests.sh` is the checkout's. The control
    passes only when the inner make's output line itself is found and shows the outer list (`TESTS=[<fake>]` and
    `OUTER=[1]`), so a run that never reaches the inner make cannot count as the control passing. This proves that the
    check can fail.
  - `TEST_JOBS=2 make -C <checkout> test TESTS="scheduler/deploy-d04.test.sh"` exits 0 and prints no `FAIL` line.

## Changes
1. **The `test` target clears the outer make's variables.** The recipe of the `Makefile`'s `test` target removes
   `MAKEFLAGS`, `MAKEOVERRIDES`, `MFLAGS` and `MAKELEVEL` from the environment of `scheduler/runtests.sh`, for example
   by adding `-u` options to the `env` that already clears the forge variables (G04). The outer make still expands
   `$(TESTS)` itself, so `make test TESTS="<files>"` runs the same files. The forge variables stay cleared. No test
   file and nothing under `scheduler/testdata/` changes (they are frozen paths). *D16-AC-1, D16-AC-2, D16-AC-3.*
2. **The test.** `scheduler/runtests-d16.test.sh` as above, added to the `Makefile`'s `TESTS`, under its 30 s
   `TEST_FILE_BUDGET`. *D16-AC-1, D16-AC-2.*

## Gate
- **D16-AC-1** — The `Makefile`'s `test` target, run as `make -k test TESTS="<fake test file>" D16_OUTER=1`, starts the test files with none of `MAKEFLAGS`, `MAKEOVERRIDES`, `MFLAGS` and `MAKELEVEL` in their environment, so the fake test file's own `make -s -C <fixture> test` sees its fixture Makefile's `TESTS`, no `D16_OUTER` and no `k` among its flags (the flag word of its `MAKEFLAGS`, before any ` -- `); the control, the same fake run through a planted Makefile whose recipe is `sh scheduler/runtests.sh $(TESTS)` as `make -k -f <planted Makefile, absolute path> -C <checkout> test TESTS="<fake>" D16_OUTER=1`, finds the inner make's output line and it shows `TESTS=[<fake>]` and `OUTER=[1]`, so a run that never reaches the inner make does not pass the control. *Verify:* `sh scheduler/runtests-d16.test.sh`.
- **D16-AC-2** — `TEST_JOBS=2 make test TESTS="scheduler/deploy-d04.test.sh"` exits 0 with no `FAIL` line, as `sh scheduler/deploy-d04.test.sh` does. *Verify:* `sh scheduler/runtests-d16.test.sh`.
- **D16-AC-3** — The node changes no existing line of a frozen test path: its diff from `origin/main` under `*.test.sh` and `scheduler/testdata/` adds `scheduler/runtests-d16.test.sh` and nothing else. *Verify:* a recorded run of `git diff --name-status origin/main...HEAD -- '*.test.sh' scheduler/testdata` in the node's PR.

## Risks
- Only a test run through the `Makefile`'s `test` target is fixed. A test file run by `sh scheduler/runtests.sh`
  from inside some other make still inherits that make's variables. The quick gate, CI and `deploy.sh` all run
  `make test`.
- Clearing `MAKEFLAGS` also drops the outer make's flags (`-k`, `-s`, the jobserver of `-j`) for every test file. No
  test file relies on them today (`plugin/skills/adopt/adopt.test.sh` already clears them for its own make). A later
  test that wants a flag passes it to its own make.
- Other test files that run `make` (`scheduler/deploy.test.sh`, `scheduler/deploy-d07.test.sh`,
  `scheduler/loop-d04.test.sh`) pass under the quick gate today, because their stub Makefiles do not read `TESTS`.
  They gain nothing they can show, and lose nothing either.
- `deploy.sh`'s own `make test` in production runs outside any make and is unchanged.
