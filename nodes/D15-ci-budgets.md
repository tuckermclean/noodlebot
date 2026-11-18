# D15 — ci-budgets

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D10 | none | S |

**Owns:** in `.github/workflows/test.yml`: the values of `TEST_FILE_BUDGET` and `TEST_BUDGET` in both `make test`
steps and the comment on those steps; in `scheduler/check-ci-workflow.py`: the budget values it expects; the record
of CI times (change 1), in the node's PR. As D11 (its change 4) did, this spec allows, for this node only, changing
exactly these existing lines of the frozen test paths (line numbers as of `main` at `906abb5`); merging this spec is
the owner's approval of them:
- `scheduler/runtests-d08.test.sh:74–75`, `scheduler/runtests.test.sh:174` and
  `scheduler/check-ci-workflow.test.sh:65–66`, changed only in the numbers `60` (to the new `TEST_FILE_BUDGET`) and
  `360` (to the new `TEST_BUDGET`);
- the budget values of D10's failing fixtures f07, f10, f12 and h1 (`scheduler/check-ci-workflow.test.sh:141–142`,
  `:155`, `:165` and `:227`) and the comment at `scheduler/runtests.test.sh:162`, changed only in the numbers `60` and
  `360`, in the same way, so that each failing fixture stays the passing one with exactly one change. The `600` of f12
  (`:166`) stays.

No other frozen line changes: no other check, compared value, pattern or fixture.
**Resolves:** #190

## Purpose
After this node CI's time budgets come from measured runs. Today `.github/workflows/test.yml` runs `make test` on
every pull request with `TEST_FILE_BUDGET=60`, `TEST_BUDGET=360` and `TEST_BUDGET_ENFORCE=1`, and prints the same
budgets on pushes to `main` (D08). Those budgets came from fast runs. GitHub's runners have taken 263–530 s for the
`make test` step (runs of 2026-11-14 to 2026-11-18), and the S06 pair alone takes 41–78 s per file. On 2026-11-18,
four of six runs of the spec PRs #188 and #189 failed on time or on a known flake. After this node, the budgets
enforced on pull requests, and printed on pushes, are set from a record of measured CI times and cite it.

D15-AC-1 supersedes only the 60/360 values of D08-AC-1, D03-AC-5 and D10-AC-2; everything else those criteria say
stays in force, and `make test` still runs in CI on every pull request, as SPEC.md principle 5 says.

**Why not skip `make test` on spec-only pull requests.** A skip for pull requests that change only `docs/graph.yaml`
and `nodes/` was considered and declined, keeping principle 5. Spec PRs are merged by the owner, so an occasional red
run on one costs little, and D13 (its spec merged in #188) fixes the flaky tests behind two of the four failures in
#190 (S02-AC-2 and G01-AC-6).

**Why raise the budgets.** Runner speed varies by a factor of up to about 1.65 for the same commit, and on slow
runners `main`'s own push runs take 349–468 s. Making the four over-budget files faster would not bring such totals
under 360 s. The budgets still catch a test that becomes much slower than the slowest runner's normal time.

**How this fits D13.** D13's spec gives the CI budgets as 60 s and 360 s at its own base. This node is merged after
D13's spec, so when D13 is built its four files are held to the larger values this node sets; D13's spec needs no
change, and its criteria are not loosened by it (its unloaded 30 s bound stays).

## Tests
- `scheduler/runtests-d08.test.sh` (D08-AC-1), `scheduler/runtests.test.sh` (D03-AC-5) and
  `scheduler/check-ci-workflow.test.sh` (D10's criteria) pass with only the lines **Owns:** names changed, and only in
  the numbers it allows: they then read the new values in both `make test` steps of `test.yml` and in what
  `check-ci-workflow.py` expects. D10's existing passing and failing cases still give their results, f12's `600`
  still fails. `site/site.test.sh` (W03-AC-6) is not changed and still passes.
- No test file is added, so the `Makefile`'s `TESTS` does not change.

## Changes
1. **The record of CI times.** From the public jobs API (step durations) and the job logs
   (`actions/jobs/<id>/logs`: the `TIME` and `TOTAL` lines), the node records in its PR every attempt of every
   `test.yml` run started from 2026-11-14 up to the day before its PR whose `make test` step ran to its end (push and
   pull_request, failed attempts included), at least 20; for each, the run ID, attempt, event, head SHA, conclusion,
   the step's duration, its `TOTAL` line and its slowest `TIME` lines from the job log. A file's time counts toward
   `TEST_FILE_BUDGET` only from an attempt in which that file passed. The record includes the four runs issue #190
   cites (44396696734, 44402025835, 44402594016 and 44395308749). The new budgets follow from it:
   - `TEST_FILE_BUDGET`: the slowest recorded file time × 1.2, rounded up to a multiple of 15 s;
   - `TEST_BUDGET`: the largest recorded `TOTAL` × 1.1, rounded up to a multiple of 30 s, and 630 if that gives 600
     (D10's failing fixture `f12` uses 600).

   If `TEST_BUDGET` comes out over 720 s (the job's timeout is 900 s), the node stops and asks the owner rather than
   raise it that far. The PR shows the arithmetic from the slowest rows to each value. *D15-AC-1.*
2. **The workflow.** In `.github/workflows/test.yml`, both `make test` steps set the `TEST_FILE_BUDGET` and
   `TEST_BUDGET` of change 1, and the comment on the steps says where the values come from. The triggers, the job, its
   runner and timeout, the steps, their conditions and every other setting do not change: the `pull_request` step
   still sets `TEST_BUDGET_ENFORCE: 1` and runs on every pull request. *D15-AC-1, D15-AC-2.*
3. **The workflow check.** The expected `TEST_FILE_BUDGET` and `TEST_BUDGET` of `scheduler/check-ci-workflow.py`
   become those of change 1. Then the frozen lines that **Owns:** names change, and nothing else. *D15-AC-1.*
4. **Recorded check.** The node's PR records its own CI run: the `make test (pull_request)` step ran with the new
   budgets enforced and passed; the run's step list and its `TOTAL` line. *D15-AC-2.*

## Gate
- **D15-AC-1** — Both `make test` steps of `test.yml` set the `TEST_FILE_BUDGET` and `TEST_BUDGET` that change 1 derives from the node's record, and `check-ci-workflow.py` expects the same values; the PR holds the record of change 1 (every attempt from 2026-11-14 up to the day before the PR whose `make test` step ran to its end, push and pull_request, failed attempts included, at least 20, the four runs issue #190 cites among them, with their `TOTAL` and slowest `TIME` lines, a file's time counted only from an attempt in which it passed) and the arithmetic from the slowest rows to each value; `TEST_BUDGET` is at most 720 and is not 600. *Verify:* `sh scheduler/runtests-d08.test.sh`, `sh scheduler/runtests.test.sh`, `sh scheduler/check-ci-workflow.test.sh`, and the record in the PR, checked by the fresh reviewer against the jobs API and the job logs for at least three of its rows.
- **D15-AC-2** — The frozen test paths differ from `main` only in the lines **Owns:** names, only in their numbers `60` and `360`, and `site/site.test.sh` is unchanged; `test.yml` differs from `main` only in the four budget values and the comment on the `make test` steps, so `make test` still runs on every pull request with `TEST_BUDGET_ENFORCE: 1`; the node's own CI run shows the `make test (pull_request)` step ran with the new budgets and passed. *Verify:* `git diff origin/main...HEAD` over `scheduler/*.test.sh`, `site/site.test.sh`, `scheduler/testdata/` and `.github/workflows/test.yml`, checked by the fresh reviewer; the recorded CI run URL with its step list and `TOTAL` line, in the PR.

## Risks
- A raised total budget catches only gross slowdowns of the whole suite. A slow new file is still caught by the
  per-file budget and by the `SLOW` lines that each run prints.
- Spec PRs still run the whole `make test`, so they still cost a runner six to nine minutes and can still go red on a
  flake until D13 is built. The owner merges spec PRs and can rerun such a run.
- A record from a few days of runners may not hold the slowest runner GitHub gives. A later run over the budgets
  points at the runner first: compare it with the record before blaming the code.
- `.github/workflows/image.yml` (D06) still runs `make test` with `TEST_FILE_BUDGET=60`, `TEST_BUDGET=360` and
  `TEST_BUDGET_ENFORCE=1` on pushes to `main` and on container pull requests. This node leaves it as it is, as D08 did;
  its runs can still go red on time alone.
