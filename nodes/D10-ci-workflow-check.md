# D10 — ci-workflow-check

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D08 | none | S |

**Owns:** `scheduler/check-ci-workflow.py` (new), `scheduler/check-ci-workflow.test.sh` (new) and its line in the `Makefile`'s `TESTS`; in `.github/workflows/test.yml`, only when the check fails on it as D08 left it: the smallest fix within D08's two `make test` steps and their settings (change 3).
**Resolves:** #141, #144

## Purpose
After this node a test shows that a failing `make test` always fails a run of `.github/workflows/test.yml`. Since D07 the conclusion of main's push run gates the self-deploy, so anything that lets a failing `make test` end in a `success` run deploys untested code. D08's `runtests-d08.test.sh` reads only each `make test` step's `if:` and `env`; it passes a job-level `if:`, `continue-on-error`, a `run` such as `make test || true`, and a `TEST_BUDGET_ENFORCE` set in the workflow's or the job's `env`. `scheduler/check-ci-workflow.py` reads the whole workflow and reports each of these, and its test shows every one caught on a fixture while `test.yml` itself passes.

## Tests
- `scheduler/check-ci-workflow.test.sh` (new): runs `check-ci-workflow.py` on `.github/workflows/test.yml` and on fixture workflows the test writes into a scratch folder at run time.
  - Passing: `test.yml` as it is; a fixture in D08's shape whose settings come from three levels (`SITE_TESTS` in the workflow's `env`, `TEST_FILE_BUDGET` and `TEST_BUDGET` in the job's `env`, `TEST_BUDGET_ENFORCE` in the pull-request step's `env`), whose job's `env` also holds `GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`, whose `on` key is quoted (`"on":`) and whose job and steps set `continue-on-error: false`. Each gives `PROBLEMS 0` and exit 0.
  - Failing, one fixture each, made from the passing fixture by one change: an `if:` on the job; `continue-on-error: true` on the job; `continue-on-error: true` on the push step; `run: make test || true`; `run: sh scheduler/runtests.sh` in place of `make test`; `TEST_BUDGET_ENFORCE: 1` in the workflow's `env`; the same in the job's `env`; `TEST_BUDGET_ENFORCE: 0` in the pull-request step's `env`; a step `if:` the check cannot read; `TEST_FILE_BUDGET` in the job's `env` written as a `${{ }}` expression; the job's `env` written as a list instead of a mapping; `TEST_BUDGET: 600` in place of 360 in the job's `env`; a third `make test` step with no `if:`; the `push` trigger removed; the `pull_request` trigger removed. Each gives exit 1 and a problem line naming the job and the step where there is one, and what is wrong.
- `scheduler/runtests-d08.test.sh` (D08-AC-1), `scheduler/runtests.test.sh` (D03-AC-5) and `site/site.test.sh` (W03-AC-6) are not changed and still pass.

## Changes
1. **The check.** `python3 -I scheduler/check-ci-workflow.py [<workflow>]` (default `.github/workflows/test.yml`, relative to the repository root) reads the workflow with PyYAML, taking the triggers from the `on` key or from `True` (PyYAML reads an unquoted `on` as `True`, as `site/site.test.sh` already handles). It prints each problem on its own line, naming the job and the step where there is one, and what is wrong, then `PROBLEMS <n>`, and exits 1 when n > 0 and 0 otherwise; a file it cannot read or parse is one problem. A `make test` step is a step whose `run` invokes `make` with the target `test` or invokes `runtests.sh`. The problems:
   - the workflow is no longer triggered by `pull_request` or by `push` to `main`;
   - a job holding a `make test` step has an `if:`, or a `continue-on-error` other than `false`;
   - a `make test` step has a `continue-on-error` other than `false`, or a `run` that is not exactly `make test` (surrounding whitespace aside);
   - a `make test` step's `if:` is not absent and not `github.event_name == '<event>'` (with optional `${{ }}` and either kind of quote), the form D08 reads;
   - for the `pull_request` event and for the `push` event, the number of `make test` steps that run on it, counted across all jobs, is not exactly one;
   - the effective `env` of the step that runs on an event, the workflow's `env` overlaid by the job's and then by the step's, differs from D08-AC-1: on `pull_request` it must hold `TEST_BUDGET_ENFORCE=1`, `TEST_FILE_BUDGET=60`, `TEST_BUDGET=360` and `SITE_TESTS=required`; on `push` the same without `TEST_BUDGET_ENFORCE` set to `1`; values are compared as strings. A value of one of these four keys (`TEST_BUDGET_ENFORCE`, `TEST_FILE_BUDGET`, `TEST_BUDGET`, `SITE_TESTS`) holding `${{` cannot be read and is a problem; the other keys of an `env` are not judged, so a `GH_TOKEN: ${{ secrets.X }}` beside them passes. An `env` at any of the three levels that is not a mapping is a problem.
   *D10-AC-1, D10-AC-2.*
2. **The test.** `scheduler/check-ci-workflow.test.sh` as above, added to the `Makefile`'s `TESTS`. It needs only `python3` with PyYAML, which the workflow already installs, and it stays well under `TEST_FILE_BUDGET`. *D10-AC-1, D10-AC-2.*
3. **`test.yml` itself.** It is not changed when the check passes on it as D08 left it. When the check reports a problem in it, the node fixes that problem with the smallest change, within D08's two steps and their settings, and the PR names each problem and its fix. *D10-AC-3.*

## Gate
- **D10-AC-1** — `check-ci-workflow.py` reports `PROBLEMS 0` and exits 0 on `.github/workflows/test.yml` and on a fixture whose settings come from the workflow's and the job's `env`, whose job's `env` holds a `${{ }}` value under a key outside the four compared ones, whose `on` key is quoted and whose job and steps set `continue-on-error: false`. *Verify:* `sh scheduler/check-ci-workflow.test.sh`.
- **D10-AC-2** — `check-ci-workflow.py` exits 1 with a problem line naming the job and the step where there is one, and what is wrong, for each failing fixture of the Tests: a job-level `if:`; `continue-on-error: true` on the job and on a `make test` step; a `make test` step whose `run` is `make test || true` or `sh scheduler/runtests.sh`; `TEST_BUDGET_ENFORCE: 1` in the workflow's or the job's `env` reaching the push step; `TEST_BUDGET_ENFORCE: 0` in the pull-request step; an unreadable step `if:`; a compared key's `env` value written as an expression; an `env` that is not a mapping; a job-level `TEST_BUDGET` other than 360 reaching both steps; a third `make test` step; the `push` trigger removed; the `pull_request` trigger removed. *Verify:* `sh scheduler/check-ci-workflow.test.sh`.
- **D10-AC-3** — `scheduler/runtests.sh`, `scheduler/runtests.test.sh`, `scheduler/runtests-d08.test.sh`, `site/site.test.sh` and `scheduler/deploy.sh` are unchanged, and `make test` passes with their D03-AC-5, D08-AC-1 and W03-AC-6 lines; `.github/workflows/test.yml` is unchanged, or the PR names each problem the check found in it and the change that fixed it. *Verify:* `git diff origin/main...HEAD` over those paths, checked by the fresh reviewer, and the node's recorded CI run URL in the PR.

## Risks
- The check covers what the issue found, not every way a workflow can hide a failure: a `shell:` or `defaults.run` override, a `strategy` matrix or a step after `make test` that changes the job's outcome is not judged. A later node that adds one of these to `test.yml` should extend the check.
- D07's deploy gate reads the push run's `conclusion`. A skipped `make test` step, a job skipped by an `if:` and a step with `continue-on-error` all leave that conclusion `success`, which is why each is a problem here rather than a style point.
- Pull-request runs still enforce `TEST_BUDGET=360`, and GitHub's runners often take 370–480 s for the whole suite, so this node's own PR run may go red on time alone. A session reads the `SLOW` and `TOTAL` lines before treating a red run as its own failure, and reruns it when only time failed.
- The check's expected values repeat D08-AC-1's. A node that changes the CI budgets changes them in `check-ci-workflow.py` too, or this node's test fails on `test.yml`.
