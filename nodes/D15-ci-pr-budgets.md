# D15 — ci-pr-budgets

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D10 | none | M |

**Owns:** `scheduler/ci-spec-only.sh` (new: the spec-only classifier), `scheduler/ci-spec-only.test.sh` (new) and its
line in the `Makefile`'s `TESTS`; in `.github/workflows/test.yml`: the history the checkout fetches, the classifier step,
the spec-checker step, the condition of the `pull_request` `make test` step and the values of `TEST_FILE_BUDGET` and
`TEST_BUDGET` in both `make test` steps; in `scheduler/check-ci-workflow.py`: the condition form it accepts on the
`pull_request` step, its checks of the classifier step, and its expected budget values; the cases this node adds to
`scheduler/check-ci-workflow.test.sh`; the record of CI times (change 1), in the node's PR. As D11 (its change 4) did,
this spec allows, for this node only, changing exactly these existing lines of the frozen test paths (line numbers as of
`main` at `c38bb52`); merging this spec is the owner's approval of them:
- `scheduler/runtests-d08.test.sh:52` (the `COND` pattern) and lines 65–71 (how a `make test` step's `if:` is read),
  changed only so that the `pull_request` step's condition of change 3 counts as running on `pull_request`, and every
  other condition the lines reject today is still rejected;
- `scheduler/runtests-d08.test.sh:74–75`, `scheduler/runtests.test.sh:174` and
  `scheduler/check-ci-workflow.test.sh:65–66`, changed only in the numbers `60` (to the new `TEST_FILE_BUDGET`) and
  `360` (to the new `TEST_BUDGET`).

No other frozen line changes: no other check, compared value, pattern or fixture.
**Resolves:** #190

## Purpose
After this node a red `test` run on a pull request says something about the pull request. Today
`.github/workflows/test.yml` runs the whole `make test` on every pull request with `TEST_FILE_BUDGET=60`,
`TEST_BUDGET=360` and `TEST_BUDGET_ENFORCE=1` (D08). Those budgets came from fast runs. GitHub's runners have
taken 263–506 s for commits whose code did not differ (runs of 2026-11-14 to 2026-11-18), and the S06 pair alone
takes 56–77 s per file. On 2026-11-18, four of six runs of the spec PRs #188 and #189 failed on time or on a known
flake, although those PRs change only `nodes/` and `docs/graph.yaml`, which no test reads. After this node:
- a pull request whose diff changes only `docs/graph.yaml` and files under `nodes/` skips `make test` and runs the
  spec checker instead. Its `test` run is green when the spec checker passes. Every other pull request, and every push
  to `main`, runs `make test` as before;
- every pull request runs the spec checker (`check-regime.py`, `PROBLEMS 0`);
- the budgets enforced on pull requests, and printed on pushes, are set from a record of measured CI times and cite it.

**Why skip rather than not enforce.** A spec-only diff leaves the merge ref's code identical to `main`'s, so `make test`
on it tests `main` again. Running it unenforced would still fail spec PRs on the flakes D13 plans for (S02-AC-2 and
G01-AC-6 failed two of the four runs) and would still cost a runner six to eight minutes. Skipping gives the owner a
check about the spec itself.

**Why `docs/graph.yaml` and `nodes/` and not D04's list.** D04's non-runtime list in `scheduler/deploy.sh` says what
the loop never reads from the live checkout. That is not what the tests never read. `README.md` is read by
`loop-w02.test.sh` and `loop-w05.test.sh`; `AGENTS.md` by `check-spec-diff.test.sh` and `quick-gate.test.sh`;
`SPEC.md` by `container/container.test.sh` (D06-AC-10); `.github/workflows/test.yml` by `runtests.test.sh`,
`runtests-d08.test.sh`, `check-ci-workflow.test.sh` and `site/site.test.sh`. Of D04's list, only `docs/graph.yaml` and
`nodes/` are read by no test. They are also exactly what a triage spec PR changes.

**Why raise the budgets.** Runner speed varies by a factor of about 1.6–1.9 for the same commit, and on slow runners
`main`'s own push runs take 349–468 s. Making the four over-budget files faster would not bring such totals under
360 s. The budgets still catch a test that becomes much slower than the slowest runner's normal time.

**How this fits #175 and D13.** The `test` job still runs and reports on every pull request. On a spec-only one it is
green with `make test` skipped, so the branch protection #175 plans can require `test` on every pull request without a
path rule or any spec-PR-only rule. Node PRs always change files outside `docs/graph.yaml` and `nodes/`, so they still
run the whole `make test`, which #175's green-CI condition relies on. Push runs, which D07's deploy gate reads, never
skip `make test`. D13 (the four flaky loop tests) is not touched here. Once this node is in, those flakes no longer reach
spec PRs, but node PRs still meet them until D13 is merged.

## Tests
- `scheduler/ci-spec-only.test.sh` (new). It makes scratch git repositories and runs `ci-spec-only.sh <base> <head>`
  with `GITHUB_OUTPUT` set to a scratch file. A diff that changes only `docs/graph.yaml` and files under `nodes/`
  (added, changed, deleted) writes `spec_only=true`. Each of the following writes `spec_only=false`: a diff that also
  changes `SPEC.md`, `AGENTS.md`, `README.md`, `.github/workflows/test.yml`, `Makefile`, `scheduler/x.sh`,
  `docs/other.md` or a file at `nodesx/a.md`; a rename from `nodes/` to `scheduler/`; a base or head the repository
  does not have; an empty `<base>`. In every case the script exits 0 and prints a line with its decision and reason.
  The test also reads `.github/workflows/test.yml` with PyYAML and checks the following. On `pull_request`, a step
  with an `id` runs the classifier before the `make test` step, and the `make test` step's condition reads that step's
  `spec_only` output. A spec-checker step runs `python3 -I plugin/skills/node/check-regime.py` on `pull_request` only,
  with a condition under which it also runs after a failed step. No step that runs on `push` has a condition naming
  `steps.`.
- `scheduler/check-ci-workflow.test.sh`: new cases, appended. Passing: a fixture whose `pull_request` step's `if:` is
  `github.event_name == 'pull_request' && steps.scope.outputs.spec_only != 'true'`, with the classifier step `scope`
  before it in the same job; `.github/workflows/test.yml` itself. Failing, one fixture each, with a problem line that
  names the job and the step: the same `&&` form on the `push` step; a condition naming a step id that does not exist,
  or that appears after the `make test` step or in another job; a classifier step whose `run` is not exactly the
  classifier command, or that has `continue-on-error: true`; `== 'true'` in place of `!= 'true'`; `||` in place of
  `&&`; an output name other than `spec_only`. D10's existing cases stay, apart from the two numbers on lines 65–66
  that **Owns:** names.
- `scheduler/runtests-d08.test.sh` (D08-AC-1) and `scheduler/runtests.test.sh` (D03-AC-5) pass with only the lines
  **Owns:** names changed. `site/site.test.sh` (W03-AC-6) is not changed and still passes.

## Changes
1. **The record of CI times.** From the public jobs API (step durations) and, where a run's log can be read, its
   `TIME` and `TOTAL` lines, the node records in its PR a table of at least 20 `test.yml` runs from at least two days.
   The table holds each run's ID, event, head SHA, conclusion, the `make test` step's duration and, where read, the
   slowest files' `TIME` lines. It includes the four runs issue #190 cites (44396696734, 44402025835, 44402594016 and
   44395308749), with the per-file times given there. The new budgets follow from it:
   - `TEST_FILE_BUDGET`: the slowest recorded file time × 1.2, rounded up to a multiple of 15 s;
   - `TEST_BUDGET`: the slowest recorded total (the `make test` step's duration where no `TOTAL` line was read) × 1.1,
     rounded up to a multiple of 30 s, and 630 if that gives 600 (D10's failing fixture `f12` uses 600).

   If `TEST_BUDGET` comes out over 720 s (the job's timeout is 900 s), the node stops and asks the owner rather than
   raise it that far. The PR shows the arithmetic from the slowest rows to each value. *D15-AC-4.*
2. **The classifier.** `scheduler/ci-spec-only.sh <base> <head>` runs
   `git diff --name-only --no-renames <base>...<head>`. If git succeeds and every path is `docs/graph.yaml` or under
   `nodes/`, it appends `spec_only=true` to `$GITHUB_OUTPUT`. Otherwise it appends `spec_only=false`; that covers a
   git failure, a missing argument and any other path. It prints its decision, and for `false` the first paths outside
   the list or the git error, as a line and as a `::notice::` annotation, so that the decision can be read from the
   public annotations API. It exits 0, so a mistake in it can only make `make test` run. The list is fixed in the
   script, with the reason (no test reads these paths) in its header comment. *D15-AC-1.*
3. **The workflow.** In `.github/workflows/test.yml`:
   - the checkout fetches the history the classifier needs, for example `fetch-depth: 0`;
   - a step with `id: scope` and `if: github.event_name == 'pull_request'` runs the classifier on the pull request's
     base and head SHAs, passed through the step's `env` from `github.event.pull_request.base.sha` and `.head.sha`;
   - the `pull_request` `make test` step's `if:` becomes
     `github.event_name == 'pull_request' && steps.scope.outputs.spec_only != 'true'`, and its `env` is otherwise
     D08's, with the new budget values;
   - the `push` `make test` step keeps `if: github.event_name == 'push'` and its `env`, with the new budget values;
   - after the `make test` steps, a spec-checker step runs on `pull_request` only, also after a failed step but not on
     a cancelled run, for example `if: github.event_name == 'pull_request' && !cancelled()`. It runs
     `python3 -I plugin/skills/node/check-regime.py` and fails the run unless it reports `PROBLEMS 0`.

   The triggers, the job, its runner and timeout, and the step that installs the tools do not change. The comment on
   the steps says why `make test` is skipped on a spec-only pull request and never on a push.
   *D15-AC-2, D15-AC-3, D15-AC-4.*
4. **The workflow check.** `scheduler/check-ci-workflow.py` accepts on a `make test` step the condition of change 3,
   with optional `${{ }}` and either kind of quote, only under these conditions:
   - the event is `pull_request`;
   - the step id it names belongs to an earlier step of the same job;
   - that step's `if:` is absent or `github.event_name == 'pull_request'`;
   - that step's `run` is exactly the classifier command, a form named once in the script;
   - that step's `continue-on-error` is absent or `false`;
   - the output it reads is `spec_only`, compared with `!= 'true'`.

   Every other condition is a problem, as D10 reads them today. The step that carries this condition counts as the one
   `make test` step that runs on `pull_request`. The expected `TEST_FILE_BUDGET` and `TEST_BUDGET` become those of
   change 1. Then the frozen lines that **Owns:** names change, and nothing else. *D15-AC-3, D15-AC-4.*
5. **Recorded checks.** The node's PR records:
   - its own CI run (a `pull_request` run, not spec-only): the classifier's annotation reads `spec_only=false` and
     names paths outside the list, not a git error; the `make test (pull_request)` step and the spec-checker step ran
     and passed; the run's step list;
   - one local run of the test files that name `graph.yaml` or `nodes/`
     (`grep -lE 'graph\.yaml|nodes/'` over the Makefile's `TESTS`), through `TEST_JOBS=2 make test TESTS="<files>"`,
     in a scratch worktree of the node's head where a commit has deleted `docs/graph.yaml` and `nodes/`. Every file
     passes, which shows that no test reads them. If a file fails there, the node stops before the PR and asks the
     owner, naming the file and the path it reads, whether to narrow the classifier's list or change that test.
     *D15-AC-5.*

## Gate
- **D15-AC-1** — `ci-spec-only.sh` writes `spec_only=true` for a diff that changes only `docs/graph.yaml` and files under `nodes/`, and `spec_only=false` for a diff that also changes any other path (`SPEC.md`, `AGENTS.md`, `README.md`, the workflow, the `Makefile`, `scheduler/`, `docs/` beyond the graph, a `nodesx/` path, a rename out of `nodes/`), for an unknown base or head and for a missing argument; it always exits 0 and prints its decision. *Verify:* `sh scheduler/ci-spec-only.test.sh`.
- **D15-AC-2** — On `pull_request`, `.github/workflows/test.yml` runs the classifier in a step with an id before the `make test` step, runs the `make test` step unless that step's `spec_only` output is `true`, and runs a spec-checker step (`python3 -I plugin/skills/node/check-regime.py`) on `pull_request` only, also after a failed step; no step that runs on `push` has a condition that reads a step output, so every push run runs `make test`; `check-regime.py` reports `PROBLEMS 0` on the repository. *Verify:* `sh scheduler/ci-spec-only.test.sh` and `python3 -I plugin/skills/node/check-regime.py`.
- **D15-AC-3** — `check-ci-workflow.py` reports `PROBLEMS 0` on `.github/workflows/test.yml` and on a fixture with the classifier step and the `pull_request` condition of change 3, and exits 1 with a problem line naming the job and the step for each failing fixture of the Tests (the condition on the `push` step; a missing, later or other-job step id; a classifier step with another `run` or with `continue-on-error: true`; `== 'true'`; `||`; another output name); D10's existing passing and failing cases still give their results. *Verify:* `sh scheduler/check-ci-workflow.test.sh`.
- **D15-AC-4** — Both `make test` steps of `test.yml` set the `TEST_FILE_BUDGET` and `TEST_BUDGET` that change 1 derives from the node's record, and `check-ci-workflow.py` expects the same values; the PR holds the record of at least 20 runs, the four runs issue #190 cites among them, and the arithmetic from the slowest rows to each value; `TEST_BUDGET` is at most 720 and is not 600. *Verify:* `sh scheduler/runtests-d08.test.sh`, `sh scheduler/runtests.test.sh`, `sh scheduler/check-ci-workflow.test.sh`, and the record in the PR, checked by the fresh reviewer against the jobs API for at least three of its rows.
- **D15-AC-5** — The frozen test paths differ from `main` only in the lines **Owns:** names, in the ways it allows, and in added lines, and `site/site.test.sh` is unchanged; the node's own CI run shows the classifier's `spec_only=false` annotation naming paths outside the list and the `make test (pull_request)` and spec-checker steps passed; the local run of the test files that name `graph.yaml` or `nodes/`, with both deleted, passes. *Verify:* `git diff origin/main...HEAD` over `scheduler/*.test.sh`, `site/site.test.sh` and `scheduler/testdata/`, checked by the fresh reviewer; the recorded CI run URL with its step list and annotations; and the recorded local run, in the PR.

## Risks
- A test added later that reads `docs/graph.yaml` or a file under `nodes/` would not run on the spec-only PR that
  breaks it. It would fail on `main`'s next push run, which D07 reads only for a runtime range. The classifier's header
  comment and D15-AC-5's recorded run name the rule. A node that adds such a test widens the classifier's exclusion,
  so that diff stops counting as spec-only.
- The first spec-only pull request after the merge is the first real proof that GitHub skips the step as intended.
  The owner should look at its step list: the classifier's `spec_only=true`, `make test (pull_request)` skipped, and the
  spec checker passed.
- A raised total budget catches only gross slowdowns of the whole suite. A slow new file is still caught by the
  per-file budget and by the `SLOW` lines that each run prints.
- The jobs API gives each step's duration, not each file's. Per-file times come only from logs that can be read. If
  the record has few of them, `TEST_FILE_BUDGET` rests mostly on the four runs that issue #190 cites.
- `.github/workflows/image.yml` (D06) still runs `make test` with `TEST_FILE_BUDGET=60`, `TEST_BUDGET=360` and
  `TEST_BUDGET_ENFORCE=1` on pushes to `main` and on container pull requests. This node leaves it as it is, as D08 did;
  its runs can still go red on time alone.
- With `fetch-depth: 0`, the checkout fetches the whole history, which takes a few seconds more. A shallower fetch
  that misses the base makes the classifier answer `false`, so `make test` runs; the mistake costs time but never skips
  `make test`.
