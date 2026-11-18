# D15 — ci-pr-budgets

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D10 | none | M |

**Owns:** `scheduler/ci-spec-only.sh` (new: the spec-only classifier), `scheduler/ci-spec-only.test.sh` (new) and its
line in the `Makefile`'s `TESTS`; in `.github/workflows/test.yml`: the history the checkout fetches, the classifier
step, the spec-check step, the condition of the `pull_request` `make test` step and the values of `TEST_FILE_BUDGET`
and `TEST_BUDGET` in both `make test` steps; in `scheduler/check-ci-workflow.py`: the condition form it accepts on the
`pull_request` step, its checks of the classifier step, and its expected budget values; the cases this node adds to
`scheduler/check-ci-workflow.test.sh`; the `make test` row of `README.md`'s table (change 6); the record of CI times
(change 1), in the node's PR. As D11 (its change 4) did, this spec allows, for this node only, changing exactly these
existing lines of the frozen test paths (line numbers as of `main` at `c38bb52`); merging this spec is the owner's
approval of them:
- `scheduler/runtests-d08.test.sh:52` (the `COND` pattern) and lines 65–71 (how a `make test` step's `if:` is read),
  changed only so that the `pull_request` step's condition of change 3 counts as running on `pull_request`, and every
  other condition the lines reject today is still rejected;
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
After this node a red `test` run on a pull request says something about the pull request. Today
`.github/workflows/test.yml` runs the whole `make test` on every pull request with `TEST_FILE_BUDGET=60`,
`TEST_BUDGET=360` and `TEST_BUDGET_ENFORCE=1` (D08). Those budgets came from fast runs. GitHub's runners have
taken 263–530 s for the `make test` step (runs of 2026-11-14 to 2026-11-18), and the S06 pair alone takes 41–78 s
per file. On 2026-11-18, four of six runs of the spec PRs #188 and #189 failed on time or on a known flake, although
those PRs change only `nodes/` and `docs/graph.yaml`, which only the two spec-check test files read. After this node:
- a pull request whose diff changes only `docs/graph.yaml` and files under `nodes/` skips `make test` and runs the
  spec checks instead. Its `test` run is green when the spec checks pass. Every other pull request, and every push to
  `main`, runs `make test` as before;
- every pull request runs the spec checks (`check-regime.test.sh`, `check-coverage.test.sh`);
- the budgets enforced on pull requests, and printed on pushes, are set from a record of measured CI times and cite it.

D15-AC-2 and D15-AC-4 supersede D08-AC-1's one `make test` step on every `pull_request` (none on a spec-only one) and
the 60/360 values of D08-AC-1, D03-AC-5 and D10-AC-2. SPEC.md principle 5 says which pull requests run `make test`.

**Why skip rather than not enforce.** A spec-only diff leaves the merge ref's code identical to `main`'s, so `make test`
on it tests `main` again. Running it unenforced would still fail spec PRs on the flakes D13 plans for (S02-AC-2 and
G01-AC-6 failed two of the four runs) and would still cost a runner six to eight minutes. Skipping gives the owner a
check about the spec itself.

**Why `docs/graph.yaml` and `nodes/` and not D04's list.** D04's non-runtime list in `scheduler/deploy.sh` says what
the loop never reads from the live checkout. That is not what the tests never read. `README.md` is read by
`loop-w02.test.sh` and `loop-w05.test.sh`; `AGENTS.md` by `check-spec-diff.test.sh` and `quick-gate.test.sh`;
`SPEC.md` by `container/container.test.sh` (D06-AC-10); `.github/workflows/test.yml` by `runtests.test.sh`,
`runtests-d08.test.sh`, `check-ci-workflow.test.sh` and `site/site.test.sh`. Of D04's list, only `docs/graph.yaml` and
`nodes/` are read by no test other than `check-regime.test.sh` and `check-coverage.test.sh`, which the spec-check step
runs: A02-AC-3 runs `check-regime.py` on this repository and A04-AC-3 `check-coverage.py`. They are also exactly what a
triage spec PR changes.

**Why the base's classifier decides.** A `pull_request` run executes the merge ref's files. If the pull request's own
copy of the classifier decided, a pull request that changes the classifier could make it answer `true` for itself and
skip `make test`, the classifier's own tests with it. The step runs the classifier as it is at the pull request's base,
so a change to the classifier only takes effect for the pull requests after it is merged.

**Why raise the budgets.** Runner speed varies by a factor of up to about 1.65 for the same commit, and on slow
runners `main`'s own push runs take 349–468 s. Making the four over-budget files faster would not bring such totals
under 360 s. The budgets still catch a test that becomes much slower than the slowest runner's normal time.

**How this fits #175 and D13.** The `test` job still runs and reports on every pull request. On a spec-only one it is
green with `make test` skipped, so the branch protection #175 plans can require `test` on every pull request without a
path rule or any spec-PR-only rule. Node PRs always change files outside `docs/graph.yaml` and `nodes/`, so they still
run the whole `make test`, which #175's green-CI condition relies on. Push runs, which D07's deploy gate reads (it lists
only `--event push` runs), never skip `make test`. D13 (the four flaky loop tests) is not touched here. Once this node
is in, those flakes no longer reach spec PRs, but node PRs still meet them until D13 is merged. D13's spec names the
CI budgets 60 s and 360 s; whichever of D13 and D15 is merged second brings those numbers in line with the other.

## Tests
- `scheduler/ci-spec-only.test.sh` (new). It makes scratch git repositories and runs `ci-spec-only.sh <base> <head>`
  with `GITHUB_OUTPUT` set to a scratch file. A diff that changes only `docs/graph.yaml` and files under `nodes/`
  (added, changed, deleted) writes `spec_only=true`. Each of the following writes `spec_only=false`: a diff that also
  changes `SPEC.md`, `AGENTS.md`, `README.md`, `.github/workflows/test.yml`, `Makefile`, `scheduler/x.sh`,
  `docs/other.md` or a file at `nodesx/a.md`; a rename from `nodes/` to `scheduler/`; a base equal to the head (an
  empty diff); a base or head the repository does not have; an empty `<base>`. In every case the script exits 0 and
  prints a line with its decision and reason. It also runs the classifier step's command, as `test.yml` gives it, in a
  scratch repository whose base commit has a classifier that answers `false` and whose head commit has a classifier
  that always answers `true`: the command writes `spec_only=false`. With no classifier at the base, the command runs
  the head's copy; with neither, it writes `spec_only=false`; it exits 0 in each case.
  The test also reads `.github/workflows/test.yml` with PyYAML and checks the following. On `pull_request`, a step
  with an `id` runs the classifier before the `make test` step, and the `make test` step's condition reads that step's
  `spec_only` output. A spec-check step has exactly
  `if: github.event_name == 'pull_request' && !cancelled()` and runs `sh plugin/skills/node/check-regime.test.sh`
  and `sh plugin/skills/node/check-coverage.test.sh`. No step that runs on `push` has a condition naming `steps.`.
- `scheduler/check-ci-workflow.test.sh`: new cases, appended. Passing: a fixture whose `pull_request` step's `if:` is
  `github.event_name == 'pull_request' && steps.scope.outputs.spec_only != 'true'`, with the classifier step `scope`
  before it in the same job; `.github/workflows/test.yml` itself. Failing, one fixture each, with a problem line that
  names the job and the step: the same `&&` form on the `push` step; a condition naming a step id that does not exist,
  or that appears after the `make test` step or in another job; a classifier step whose `run` is not exactly the
  classifier command, or that has `continue-on-error: true`; a classifier step whose `env` swaps the base and head
  SHAs, or gives either from another expression; `== 'true'` in place of `!= 'true'`; `||` in place of `&&`; an
  output name other than `spec_only`. D10's existing cases stay, apart from the numbers that **Owns:** names.
- `scheduler/runtests-d08.test.sh` (D08-AC-1) and `scheduler/runtests.test.sh` (D03-AC-5) pass with only the lines
  **Owns:** names changed. `site/site.test.sh` (W03-AC-6) is not changed and still passes.

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
   raise it that far. The PR shows the arithmetic from the slowest rows to each value. *D15-AC-4.*
2. **The classifier.** `scheduler/ci-spec-only.sh <base> <head>` runs
   `git diff --name-only --no-renames <base>...<head>`. If git succeeds, lists at least one path, and every path is
   `docs/graph.yaml` or under `nodes/`, it appends `spec_only=true` to `$GITHUB_OUTPUT`. Otherwise it appends
   `spec_only=false`; that covers a git failure, a missing argument, an empty list and any other path. It prints its
   decision, and for `false` the first paths outside the list, the empty diff or the git error, as a line and as a
   `::notice::` annotation, so that the decision can be read from the public annotations API. It exits 0. The list is
   fixed in the script; its header comment gives the reason: no test reads these paths except
   `plugin/skills/node/check-regime.test.sh` and `plugin/skills/node/check-coverage.test.sh`, which the spec-check
   step runs on every pull request. *D15-AC-1.*
3. **The workflow.** In `.github/workflows/test.yml`:
   - the checkout fetches the history the classifier needs, for example `fetch-depth: 0`;
   - a step with `id: scope` and `if: github.event_name == 'pull_request'` runs the classifier as it is at the pull
     request's base (`git show "$BASE_SHA:scheduler/ci-spec-only.sh"`) on the base and head SHAs. It runs the pull
     request's own copy only when the base has no classifier, and it writes `spec_only=false` and exits 0 when neither
     can run. Its `env` sets `BASE_SHA` to `${{ github.event.pull_request.base.sha }}` and `HEAD_SHA` to
     `${{ github.event.pull_request.head.sha }}`;
   - the `pull_request` `make test` step's `if:` becomes
     `github.event_name == 'pull_request' && steps.scope.outputs.spec_only != 'true'`, and its `env` is otherwise
     D08's, with the new budget values;
   - the `push` `make test` step keeps `if: github.event_name == 'push'` and its `env`, with the new budget values;
   - after the `make test` steps, a spec-check step runs on `pull_request` only, also after a failed step but not on a
     cancelled run (`if: github.event_name == 'pull_request' && !cancelled()`). It runs
     `sh plugin/skills/node/check-regime.test.sh` and `sh plugin/skills/node/check-coverage.test.sh`, the two test
     files that read this repository's `docs/graph.yaml` and `nodes/` (A02-AC-3 runs `check-regime.py` on it, A04-AC-3
     `check-coverage.py`; together about 10 s), and fails the run if either fails. It runs them directly, not through
     `make test` or `runtests.sh`, which `check-ci-workflow.py` would count as a `make test` step.

   The triggers, the job, its runner and timeout, and the step that installs the tools do not change. The comment on
   the steps says why `make test` is skipped on a spec-only pull request and never on a push.
   *D15-AC-2, D15-AC-3, D15-AC-4.*
4. **The workflow check.** `scheduler/check-ci-workflow.py` accepts on a `make test` step the condition of change 3,
   with optional `${{ }}` and either kind of quote, only under these conditions:
   - the event is `pull_request`;
   - the step id it names belongs to an earlier step of the same job;
   - that step's `if:` is absent or `github.event_name == 'pull_request'`;
   - that step's `run` is exactly the classifier command of change 3, a form named once in the script;
   - that step's `env` sets the base and head exactly to `${{ github.event.pull_request.base.sha }}` and
     `${{ github.event.pull_request.head.sha }}`;
   - that step's `continue-on-error` is absent or `false`;
   - the output it reads is `spec_only`, compared with `!= 'true'`.

   Every other condition is a problem, as D10 reads them today. The step that carries this condition counts as the one
   `make test` step that runs on `pull_request`. The expected `TEST_FILE_BUDGET` and `TEST_BUDGET` become those of
   change 1. Then the frozen lines that **Owns:** names change, and nothing else. *D15-AC-3, D15-AC-4.*
5. **Recorded checks.** The node's PR records:
   - its own CI run (a `pull_request` run, not spec-only): the classifier's annotation reads `spec_only=false` and
     names paths outside the list, not a git error; the `make test (pull_request)` step and the spec-check step ran
     and passed; the run's step list;
   - one local run of every file of the `Makefile`'s `TESTS` (`TEST_JOBS=2 make test`) in a scratch worktree of the
     node's head where a commit has deleted `docs/graph.yaml` and `nodes/`. This is an exception to AGENTS.md's rule
     that a session does not run the whole suite locally. Every file passes except `check-regime.test.sh` and
     `check-coverage.test.sh`, and those fail only on the deleted paths; a failure that also happens at the head
     without the deletion is recorded as such. If another file fails only with the deletion, the node stops before the
     PR and asks the owner, naming the file and the path it reads, whether to narrow the classifier's list, add the
     file to the spec-check step or change that test. *D15-AC-5.*
6. **The README.** The `make test` row of `README.md`'s table says that CI runs it on every push to `main` and on every
   PR that changes more than `docs/graph.yaml` and `nodes/`, and that a PR that changes only those runs the spec checks
   instead. *D15-AC-2.*

## Gate
- **D15-AC-1** — `ci-spec-only.sh` writes `spec_only=true` for a diff that changes only `docs/graph.yaml` and files under `nodes/`, and `spec_only=false` for a diff that also changes any other path (`SPEC.md`, `AGENTS.md`, `README.md`, the workflow, the `Makefile`, `scheduler/`, `docs/` beyond the graph, a `nodesx/` path, a rename out of `nodes/`), for a base equal to the head (an empty diff), for an unknown base or head and for a missing argument; it always exits 0 and prints its decision; the classifier step's command of `test.yml` writes `spec_only=false` when the base's classifier answers `false` and the head's always answers `true`, runs the head's copy only when the base has none, and writes `spec_only=false` when neither can run. *Verify:* `sh scheduler/ci-spec-only.test.sh`.
- **D15-AC-2** — On `pull_request`, `.github/workflows/test.yml` runs the classifier in a step with an id before the `make test` step, runs the `make test` step unless that step's `spec_only` output is `true`, and runs a spec-check step with `if: github.event_name == 'pull_request' && !cancelled()` that runs `sh plugin/skills/node/check-regime.test.sh` and `sh plugin/skills/node/check-coverage.test.sh`; no step that runs on `push` has a condition that reads a step output, so every push run runs `make test`; both spec-check test files pass on the repository; `README.md`'s `make test` row says which runs run `make test` and which run the spec checks. *Verify:* `sh scheduler/ci-spec-only.test.sh`, `sh plugin/skills/node/check-regime.test.sh`, `sh plugin/skills/node/check-coverage.test.sh`, and the README row, checked by the fresh reviewer.
- **D15-AC-3** — `check-ci-workflow.py` reports `PROBLEMS 0` on `.github/workflows/test.yml` and on a fixture with the classifier step and the `pull_request` condition of change 3, and exits 1 with a problem line naming the job and the step for each failing fixture of the Tests (the condition on the `push` step; a missing, later or other-job step id; a classifier step with another `run` or with `continue-on-error: true`; a classifier step whose `env` swaps the base and head SHAs or gives either from another expression; `== 'true'`; `||`; another output name); D10's existing passing and failing cases still give their results. *Verify:* `sh scheduler/check-ci-workflow.test.sh`.
- **D15-AC-4** — Both `make test` steps of `test.yml` set the `TEST_FILE_BUDGET` and `TEST_BUDGET` that change 1 derives from the node's record, and `check-ci-workflow.py` expects the same values; the PR holds the record of change 1 (every attempt from 2026-11-14 up to the day before the PR whose `make test` step ran to its end, at least 20, the four runs issue #190 cites among them, with their `TOTAL` and slowest `TIME` lines) and the arithmetic from the slowest rows to each value; `TEST_BUDGET` is at most 720 and is not 600. *Verify:* `sh scheduler/runtests-d08.test.sh`, `sh scheduler/runtests.test.sh`, `sh scheduler/check-ci-workflow.test.sh`, and the record in the PR, checked by the fresh reviewer against the jobs API and the job logs for at least three of its rows.
- **D15-AC-5** — The frozen test paths differ from `main` only in the lines **Owns:** names, in the ways it allows, and in added lines, and `site/site.test.sh` is unchanged; the node's own CI run shows the classifier's `spec_only=false` annotation naming paths outside the list and the `make test (pull_request)` and spec-check steps passed; in the local run of every file of `TESTS` with `docs/graph.yaml` and `nodes/` deleted, every file passes except `check-regime.test.sh` and `check-coverage.test.sh`, which fail only on the deleted paths, and any failure that also happens without the deletion is recorded as such. *Verify:* `git diff origin/main...HEAD` over `scheduler/*.test.sh`, `site/site.test.sh` and `scheduler/testdata/`, checked by the fresh reviewer; the recorded CI run URL with its step list and annotations; and the recorded local run, in the PR.

## Risks
- A test added later that reads `docs/graph.yaml` or a file under `nodes/` would not run on the spec-only PR that
  breaks it. It would fail on `main`'s next push run, which D07 reads only for a runtime range. The classifier's header
  comment and D15-AC-5's recorded run name the rule. A node that adds such a test takes that path out of the
  classifier's list, or adds the test to the spec-check step.
- A pull request whose base has no classifier (this node's own, or one based on a `main` from before this node) runs
  its own copy. Once this node is merged, every pull request based on a later `main` runs the base's copy.
- A change to the classifier takes effect only for pull requests based on a `main` that has it; the pull request that
  makes the change is classified by the old copy.
- The first spec-only pull request after the merge is the first real proof that GitHub skips the step as intended.
  The owner should look at its step list: the classifier's `spec_only=true`, `make test (pull_request)` skipped, and
  the spec-check step passed.
- A raised total budget catches only gross slowdowns of the whole suite. A slow new file is still caught by the
  per-file budget and by the `SLOW` lines that each run prints.
- `.github/workflows/image.yml` (D06) still runs `make test` with `TEST_FILE_BUDGET=60`, `TEST_BUDGET=360` and
  `TEST_BUDGET_ENFORCE=1` on pushes to `main` and on container pull requests. This node leaves it as it is, as D08 did;
  its runs can still go red on time alone.
- With `fetch-depth: 0`, the checkout fetches the whole history, which takes a few seconds more. A shallower fetch
  that misses the base makes the classifier answer `false`, so `make test` runs; the mistake costs time but never skips
  `make test`.
- D14 (#189) also adds a line to the `Makefile`'s `TESTS`; whichever node is built second keeps both lines.
