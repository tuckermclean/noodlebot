# L02 — label-retry

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | L01, W02 | none | S |

**Owns:** in `scheduler/loop.sh`: the label step's result for lack of a token (`ensure_labels`), its retry on a tick
(in `tick_run`, after the PR lists came back), the retry's spacing (`SCHED_LABEL_RETRY`) and their lines in the header
comment and the label step's comment; `scheduler/loop-l02.test.sh` (new) and its line in the `Makefile`'s `TESTS`.
**Resolves:** #263

## Purpose
L01's label step runs once, when the loop starts. A loop started before the GitHub App is installed on its
repository gets no token then, logs `label step: no GitHub App token; labels not checked`, and never checks the labels
again until it is restarted, so the `noodlebot` label the owner hands issues over with may never exist. After this node
a label step that got no token is tried again: on the first later tick whose PR lists came back (so the token script
works again), and after a retry that again got no token, not for another `SCHED_LABEL_RETRY` seconds (default 600),
until it succeeds once. While the token script keeps failing, the ticks end early as now and the step is not tried at
all. A step that succeeded, or that failed with a token (L01-AC-5), is not run again while the loop runs, as today.
The visibility record needs no change: W02 already asks an `unknown` visibility again on every tick (W02-AC-6), so it
is recorded on the same first working tick; this node's test shows it alongside the labels.

## Tests
- `scheduler/loop-l02.test.sh` (new), on the loop prelude (`scheduler/testdata/lib/loop-prelude.sh`) with 1 s ticks,
  `SCHED_REPORT=0` and fakes of its own in the style of `scheduler/loop-l01.test.sh`: a fake `gh` that logs every PR
  poll and every call on the repository's labels in order, serves a public repository and a label list without
  `noodlebot` and `noodlebot-triaged`; and a fake token script (`$HOME/.config/noodlebot/token`) that logs each call
  with its time and its caller (the command line of its parent process) and fails as a flag file says. Each case waits
  for the ticks and log lines it checks, with a bound, not a fixed sleep.
  - token fails, then works: a loop starts with the token script failing for every caller and ticks at least three
    times (counted by the token script's calls for the PR lists). It has logged the no-token label line once, made no
    call on the labels, and `visibility` holds `unknown`. The flag is then removed: by the end of the next tick whose
    PR lists came back, the two missing labels are created (POSTs for `noodlebot` and `noodlebot-triaged` only), one
    `label step: created labels:` line is logged and `visibility` holds `public`. At least three more ticks then make
    no call on the labels. On `main` before this node no label call is made after the start (the RED).
  - lists work, the label step does not: a loop with `SCHED_LABEL_RETRY=4` whose token script fails only when its
    caller is `labels.py`. Over at least 12 s of ticks, `labels.py`'s token fetches after the start number at least
    two, each at least 4 s after the one before; the status log has one no-token label line and the loop kept
    ticking. On `main` before this node `labels.py` fetches a token once (the RED).

## Changes
1. **A label step that got no token says so.** `ensure_labels` ends in one of three ways: done (`labels.py` exited 0),
   failed with a token (`labels.py` failed for another reason) or no token: the visibility call's output or
   `labels.py`'s stderr names the token script, the forge's error when the token script fails. A no-token step logs
   `label step: no GitHub App token; labels not checked` once per loop start (a later retry that again gets no token
   logs nothing); a failure with a token logs `label step failed (see report.log); carrying on` as now. Stderr goes to
   `report.log` as now. *L02-AC-1, L02-AC-4.*
2. **The retry.** While the step's last result is no token, a tick whose PR lists came back runs `ensure_labels` again
   after the lists, when it has not run since the start or when `SCHED_LABEL_RETRY` seconds (default 600) have passed
   since its last run. A tick that ends early for lack of a token never runs it. A retry that ends done or failed with
   a token ends the retries for the rest of the loop's run; a retry that creates labels logs them as the start step
   does. The result and the time of the last run are kept in the loop's memory: a restart runs the step at its start,
   as L01 has it. The header comment names `SCHED_LABEL_RETRY` and its default. *L02-AC-2, L02-AC-3, L02-AC-4.*
3. **The test file** of **Tests**, added to the `Makefile`'s `TESTS`. *L02-AC-5.*

## Gate
- **L02-AC-1** — A loop that starts with a failing token script logs `label step: no GitHub App token; labels not checked` once, and over at least three later ticks while the token script still fails it logs no other label-step line, makes no call on the repository's labels and keeps ticking. *Verify:* `sh scheduler/loop-l02.test.sh` (the `L02-AC-1:*` cases).
- **L02-AC-2** — When that token script starts working, with no restart, the tick whose PR lists first come back creates the missing labels (POSTs for the missing ones only), logs one `label step: created labels:` line, and leaves `state/<name>/visibility` holding `public` for a public repository, all before the next tick's PR lists; on `main` before this node no label call is made after the start. *Verify:* `sh scheduler/loop-l02.test.sh` (the `L02-AC-2:*` cases), and the RED run recorded in the PR.
- **L02-AC-3** — After the retried step succeeded, at least three later ticks make no further call on the repository's labels; and the L01 cases (`scheduler/loop-l01.test.sh`: a step that succeeded at the start, or failed with a token, is not run on a tick) pass unchanged. *Verify:* `sh scheduler/loop-l02.test.sh` (the `L02-AC-3:*` cases) and `bash scheduler/loop-l01.test.sh`.
- **L02-AC-4** — When the PR lists come back but the label step again gets no token (the token script fails only for `labels.py`), the step is tried again at most once per `SCHED_LABEL_RETRY` seconds and keeps being tried: with `SCHED_LABEL_RETRY=4` and 1 s ticks over at least 12 s, `labels.py`'s token fetches after the start number at least two, each at least 4 s after the one before, and the status log has one no-token label line; the header comment of `scheduler/loop.sh` names `SCHED_LABEL_RETRY` with its default of 600. *Verify:* `sh scheduler/loop-l02.test.sh` (the `L02-AC-4:*` cases).
- **L02-AC-5** — The node changes no existing line of the frozen paths (`*.test.sh`, `scheduler/testdata/`): `scheduler/loop-l02.test.sh` is new and in the `Makefile`'s `TESTS`, and its `TIME` line in the PR's CI run is under `TEST_FILE_BUDGET`. *Verify:* the `git diff origin/main -- '*.test.sh' scheduler/testdata/` recorded in the PR and the PR's CI run.

## Risks
- Only a step that got no token is retried. A step that fails with a token (the App lacks write access to issues,
  say) is still tried once per loop start, as L01's Risks say; the owner creates the labels by hand or restarts.
- With a working token the first retry costs one visibility call and one label listing on one tick; a token that
  works for the lists but not for the step (an expiry between the two calls) costs one more attempt per 10 minutes.
- A loop that runs long before the App is installed retries on its first working tick, however late; nothing is
  retried past one success.
- The two loops of the new file cost about ten seconds each at 1 s ticks; the file stays under `TEST_FILE_BUDGET`
  (30 s), and each case waits for the ticks it counts so it holds on a loaded machine.
- Other nodes change `scheduler/loop.sh` (`tick_run` especially); whichever merges second merges `main` in.
