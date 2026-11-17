# D11 — test-reaping

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D03 | none | M |

**Owns:** in `scheduler/runtests.sh`, how a test file's processes are stopped (after the file ends, when the runner
stops it, and when the runner itself is stopped or killed) and the header comment's lines on it;
`scheduler/runtests-d11.test.sh` (new) and its line in the `Makefile`'s `TESTS`; in `scheduler/testdata/lib/`, a
shared way to start a background fixture (in `common.sh` or a new helper file) and the lines of the shared helpers that
start or stop background fixtures (the `setsid ... &` starts and the EXIT trap of `loops-body.sh`, the fake `tmux`'s
start in it, and the like in the other helpers), never a check, an expected value or a wait; the read of the starts and
the record of the runs, in the node's PR and under `out/node/D11/`.
**Resolves:** #153

## Purpose
After this node a test run leaves no process behind, however a test file ends. Today a file that stops before its EXIT
trap runs (the runner stopping it, a session being stopped, a crash) leaves its fixtures running: fake sessions
(`while :; do sleep 1; done`) that `scheduler/site.test.sh` starts with `setsid`, and fake loops and an API server that
`scheduler/testdata/lib/loops-body.sh` starts under its fixture folders. One count found 98 such processes, 48 of them
over an hour old and using about 1.85 CPUs on the 4-CPU host, and a leaked fake loop starts Python and git on every
tick. Afterwards `runtests.sh` stops every process a file started, also those that left its process group with
`setsid`, whenever the file ends or the runner stops, and the shared helpers start each fixture so that it ends with its
test file's shell even outside the runner.

## Tests
- `scheduler/runtests-d11.test.sh` (new): runs `scheduler/runtests.sh` on fake test files in a scratch folder. Each fake
  file makes its own `mktemp -d` folder and starts long-running processes there: one with plain `&`, one with
  `setsid ... &`, and one through the shared start helper. Then it ends in one of the ways a test file ends: it exits
  without its cleanup, exits non-zero partway (a crash), or is killed with KILL from outside. The runner itself is also
  sent TERM partway, and killed with KILL together with its process group. Each case then waits, up to 10 seconds, until
  no process names a fake file's folder in its command line or working directory. It reads `/proc` for this, not
  `pgrep -f`, which also matches the test's own shell. A fake file that uses the shared start helper is also run alone
  (`sh <file>`) and killed with TERM, and again with KILL; its fixture must be gone within 10 seconds. The runner's
  `TIME`, `FAILED` and `TOTAL` lines and its exit status are checked to be as D03 made them.
- `scheduler/runtests.test.sh` (D03-AC-4) and the test files that source the changed helpers pass unchanged.

## Changes
1. **The read.** The PR lists every place where a test file or a shared helper under `scheduler/testdata/lib/` starts a
   background process: file, line, how the process is started (`&`, `setsid`, a fake `tmux`), and what ends it today
   (an EXIT trap, a `pkill -f "$tmp/..."`, nothing). Known so far: `scheduler/site.test.sh`'s fake sessions (the script
   written at line 54, started at lines 151 and 152) and its lock holder (line 154), ended only by its EXIT trap (lines 22–28); and `loops-body.sh`'s fake `tmux` (line 27), its
   `start_loop` and `start_session` (lines 72 and 78) and the runtime-root and no-newline fixtures (lines 236, 245 and
   364), all ended only by its EXIT trap (line 9). *D11-AC-4.*
2. **The runner stops what a file started.** `scheduler/runtests.sh` marks each file it starts with something every
   descendant inherits, even across `setsid`, so it can find them all. For example, it can put a per-file variable in
   the environment and read it from `/proc/<pid>/environ`, or give the file its own `TMPDIR` so that its `mktemp -d`
   folders are under one folder. When the file ends (passing, failing, crashing or killed), the runner stops every
   process that still carries the file's mark: TERM, then KILL for those still there a few seconds later. When the
   runner stops a file on its own INT, TERM or HUP, it does the same for the file's whole process group and every
   marked process. The runner's output, its `TIME`, `FAILED`, `SLOW` and `TOTAL` lines and its exit status do not
   change. *D11-AC-1, D11-AC-2.*
3. **The runner killed.** When the runner is killed with KILL, with or without its process group (a session being
   stopped), a watcher it starts outside its own process group sees it gone and stops every marked process of the
   run. The watcher then exits, and it exits as well when the run ends normally, so it never outlives the run by more
   than a few seconds. *D11-AC-2.*
4. **Fixtures that end with their file.** A shared start helper in `scheduler/testdata/lib/` starts a background
   fixture in its own session, as `setsid` does, so that the checks that read a session's process group still hold.
   It also gives the fixture a watch: when the shell of the test file that started it is gone, however that shell
   ended, the watch stops the fixture's process group within a few seconds. It also has a hard lifetime (an upper
   bound in seconds, well over `TEST_FILE_BUDGET`). The shared helpers start every background fixture through it,
   `loops-body.sh`'s starts among them. A start in a frozen `*.test.sh` file, such as `site.test.sh`'s fake sessions,
   moves to the helper only as a frozen-test change that the owner approves on the PR first. Without that approval,
   the start stays as it is and is covered by the runner (changes 2 and 3) but not when the file runs alone.
   *D11-AC-3, D11-AC-4.*
5. **A whole run.** On the scheduler's machine, `TEST_JOBS=2 make test` runs once to the end and once stopped with TERM
   partway. Each run has `TMPDIR` set to a folder of its own, so that every scratch folder of the run is under that
   folder. Ten seconds after each run ends, the list of processes naming that folder (from `/proc`) is recorded under
   `out/node/D11/` and is empty. *D11-AC-5.*

## Gate
- **D11-AC-1** — When a test file run by `scheduler/runtests.sh` ends in any way (passing, failing partway, or killed with KILL from outside) and leaves background processes it started (with `&` or with `setsid`), none of them remains 10 seconds later. The runner's `TIME`, `FAILED` and `TOTAL` lines and its exit status are unchanged. *Verify:* `sh scheduler/runtests-d11.test.sh`.
- **D11-AC-2** — When `scheduler/runtests.sh` is sent TERM partway, or is killed with KILL together with its process group, no process that its running test files started (also those started with `setsid`) remains 10 seconds later, and no process of the runner remains either. *Verify:* `sh scheduler/runtests-d11.test.sh`.
- **D11-AC-3** — A fixture started through the shared start helper runs in its own session and ends within 10 seconds after the shell of the test file that started it ends, also when the file runs alone (`sh <file>`) and is killed with TERM or with KILL. The shared helpers under `scheduler/testdata/lib/` start every background fixture through it. *Verify:* `sh scheduler/runtests-d11.test.sh`, and the fresh reviewer's check that no `setsid ... &` or other background start in `scheduler/testdata/lib/` bypasses the helper.
- **D11-AC-4** — The PR records the read (every background start in the test files and shared helpers, with what ends it before and after the node). Every changed line of a `*.test.sh` file is listed as a frozen-test change with the owner's approval on the PR. No check, expected value, pattern or wait in `scheduler/*.test.sh` or `scheduler/testdata/` is changed, loosened or removed. *Verify:* the record in the PR, and the fresh reviewer's check of `git diff <base>..HEAD` over the test paths.
- **D11-AC-5** — On the scheduler's machine, `TEST_JOBS=2 make test` runs with `TMPDIR` set to a folder of its own, once to the end and once stopped with TERM partway. Ten seconds after each run ends, no process names that folder in its command line or working directory. *Verify:* the recorded process lists and run logs under `out/node/D11/`, in the PR.

## Risks
- Whatever mark the runner uses can be lost. A test that clears the environment (`env -i`) loses an environment mark,
  and a test that sets its own `TMPDIR` or writes outside `mktemp` loses a folder mark. The read (change 1) names such
  tests, and a process the mark misses is caught only by the helper's watch.
- Stopping the processes of a file that has ended must not reach another file's processes, or the processes of
  another `make test` running at the same time (several sessions run tests at once). The mark is per file and per run,
  never a pattern such as `/tmp/tmp.*`.
- Several cases check a session's process group (sessions run under `setsid`, and the group id is the pid in
  `session.pid`). The helper must keep the fixture's own session and process group, and its watch must not be in that
  group, or a test that kills the group would see an extra process.
- M02 (planned) changes the waits next to `loops-body.sh`'s `start_loop` and `start_session` starts. Whichever of the
  two nodes merges second resolves the conflict, keeping both: D11 changes the start lines and M02 the waits.
- A watch that polls adds a small load per fixture. Its poll interval and the hard lifetime are kept coarse (about a
  second, and several minutes) so that fixtures cost less than the leaks did.
- The issue's count came from one loaded morning. The whole-run record (change 5) shows the fix on the machine but not
  every way a session can be stopped. A leak found later starts from the read.
