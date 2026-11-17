# D08 — ci-budget-pr

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D03 | none | S |

**Owns:** in `.github/workflows/test.yml`: the split of the `make test` step by event (the step that runs on `pull_request`, the step that runs on `push`, and the settings each one sets); `scheduler/runtests-d08.test.sh` (new) and its line in the `Makefile`'s `TESTS`.
**Resolves:** #137

## Purpose
After this node a CI run fails for time only on a pull request. On a `pull_request` event `test.yml` runs `make test` with the budgets enforced, as D03 set them, so a slow new test is still caught in review. On a push to `main` it runs `make test` with the same budgets but without `TEST_BUDGET_ENFORCE=1`: the `TIME`, `SLOW` and `TOTAL` lines are still printed, but the run fails only when a test fails. GitHub's runners often take 370–480 s for the whole suite, so main's push runs no longer go red on time alone. Since D07 those runs gate the self-deploy, and a red one blocks it until someone reruns it by hand. `scheduler/runtests.sh` does not change: `TEST_BUDGET_ENFORCE` already means exactly this.

## Tests
- `scheduler/runtests-d08.test.sh` (new): reads `.github/workflows/test.yml` with PyYAML and works out, for a `pull_request` event and for a `push` event, which steps run `make test`. A step with no `if:` runs on both events. `if: github.event_name == '<event>'` (with optional `${{ }}` and either kind of quote) runs only on that event. Any other `if:` on a `make test` step fails the check, so a condition the test cannot read is never taken as true. For each event it checks the number of such steps and the `env` of the one that runs. It also checks that the workflow is still triggered by `pull_request` and by `push` to `main`.
- `scheduler/runtests.test.sh` (D03-AC-5) and `site/site.test.sh` (W03-AC-6) are not changed and still pass. Their checks of `test.yml` hold because the `pull_request` step keeps D03's settings and both steps set `SITE_TESTS=required`.

## Changes
1. **Two `make test` steps.** In `.github/workflows/test.yml`, the step `make test` becomes two steps. The first has `if: github.event_name == 'pull_request'` and keeps today's `env` (`SITE_TESTS: required`, `TEST_BUDGET_ENFORCE: 1`, `TEST_FILE_BUDGET: 60`, `TEST_BUDGET: 360`). The second has `if: github.event_name == 'push'` and the same `env` without `TEST_BUDGET_ENFORCE`, so the `SLOW` lines are still measured against the CI budgets but the runner exits non-zero only when a file failed. The triggers (`pull_request`, and `push` to `main`), the job, its runner, its timeout and the other steps do not change. A comment on the two steps says why they differ. *D08-AC-1, D08-AC-2.*
2. **The test.** `scheduler/runtests-d08.test.sh` as above, added to the `Makefile`'s `TESTS`. It needs only `python3` with PyYAML, which the workflow already installs, and it takes well under `TEST_FILE_BUDGET`. *D08-AC-1.*

## Gate
- **D08-AC-1** — On a `pull_request` event, exactly one step of `test.yml` runs `make test`, with `TEST_BUDGET_ENFORCE=1`, `TEST_FILE_BUDGET=60`, `TEST_BUDGET=360` and `SITE_TESTS=required`. On a `push` event, exactly one step runs `make test`, with `SITE_TESTS=required`, `TEST_FILE_BUDGET=60` and `TEST_BUDGET=360`, and without `TEST_BUDGET_ENFORCE` set to `1`. Every `make test` step's `if:` is one the test can read. The workflow is still triggered by `pull_request` and by `push` to `main`. *Verify:* `scheduler/runtests-d08.test.sh`.
- **D08-AC-2** — `scheduler/runtests.sh`, `scheduler/runtests.test.sh`, `site/site.test.sh` and `scheduler/deploy.sh` are unchanged, and `make test` passes with their D03-AC-5 and W03-AC-6 lines. The node's own CI run (a `pull_request` run) shows the enforcing `make test` step ran, with its `TIME` and `TOTAL` lines, and the push step skipped. *Verify:* `git diff origin/main..HEAD` over those paths, checked by the fresh reviewer, and the recorded CI run URL with its step list, in the PR.

## Risks
- On `main`, time is no longer a gate. A suite that grows slow on `main` alone shows up only in the `SLOW` lines of main's push runs until the next pull request's run fails on it. By then the slowdown has already merged, so the author of an unrelated PR may have to deal with it.
- A skipped step leaves the job `success`, which is what D07's deploy gate reads. If a mistake in the `if:` conditions skipped `make test` on both events, every run would go green with nothing tested. D08-AC-1's "exactly one step per event" check guards against that.
- A trigger added to `test.yml` later (`workflow_dispatch`, say) runs neither step unless its node adds a step or a condition for it. The test covers only `pull_request` and `push`.
- `.github/workflows/image.yml` (D06) also runs `make test` inside the image with `TEST_BUDGET_ENFORCE=1` on every push to `main`. This node leaves it as it is: D07's deploy gate does not read it, but its push runs can still go red on time alone.
