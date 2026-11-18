# D11 — test-reaping

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D03 | D13 | M |

**Owns:** in `scheduler/runtests.sh`, how a test file is started (with `setsid`, in a process group of its own) and how
its processes are stopped (after the file ends, when the runner stops it, and when the runner itself is stopped or
killed), the watcher, and the header comment's lines on them; `scheduler/runtests-d11.test.sh` (new) and its line in the
`Makefile`'s `TESTS`; in `scheduler/testdata/lib/`, a shared way to start a background fixture (in `common.sh` or a new
helper file); as D03 (its change 7) did, this spec allows, for this node only, changing exactly the existing lines of
the frozen test paths that change 4 names (the starts of long-running fixtures in the shared helpers and in
`scheduler/site.test.sh`, and `loops-body.sh`'s EXIT trap), each only in the way change 4 says, and never a check, an
expected value or pattern, a wait or a setting a fixture is started with; the read of the starts and the record of
the runs, in the node's PR and under `out/node/D11/`.
**Resolves:** #153

## Purpose
After this node a test run leaves no process behind, however a test file ends. Today a file that stops before its EXIT
trap runs (the runner stopping it, a session being stopped, a crash) leaves its fixtures running: fake sessions
(`while :; do sleep 1; done`) that `scheduler/site.test.sh` starts with `setsid`, and fake loops and an API server that
`scheduler/testdata/lib/loops-body.sh` starts under its fixture folders. One count found 98 such processes, 48 of them
over an hour old and using about 1.85 CPUs on the 4-CPU host, and a leaked fake loop starts Python and git on every
tick. A test file also has no process group of its own today: `runtests.sh` starts it with `work "$next" "$f" &` from
a non-interactive `sh` (line 62), so every file shares the group of the runner, of `make` and of the caller.
Afterwards `runtests.sh` starts each file in a process group of its own and stops every process a file started, also
those that left its group with `setsid`, whenever the file ends or the runner stops, and it never signals its own group.
The shared helpers start each long-running fixture so that it ends with its test file's shell even outside the runner.

## Tests
- `scheduler/runtests-d11.test.sh` (new): runs `scheduler/runtests.sh` on fake test files in a scratch folder. Each fake
  file makes its own `mktemp -d` folder and starts long-running processes there: one with plain `&`, one with
  `setsid ... &`, and one through the shared start helper, which itself starts a process with `setsid ... &`. Then it
  ends in one of the ways a test file ends: it exits without its cleanup, exits non-zero partway (a crash), or is killed
  with KILL from outside. The runner itself is also sent TERM partway, and killed with KILL together with its process group.
  In both of these cases the runner runs in a process group of its own, started with `setsid` from a wrapper shell, so
  that signalling its group never reaches the test file or an outer runner. In the TERM case that group also holds a
  sentinel process: a child of the wrapper shell, not of the runner, that no test file started; the sentinel must still
  be running afterwards. A fake file that leaves no process behind is also run, and the runner ends within 2 seconds of
  it: the stopping adds no wait when nothing is left. Each case then waits, up to 10 seconds, until no process names a
  fake file's folder in its command line or working directory. It reads `/proc` for this, not `pgrep -f`, which also
  matches the test's own shell. A fake file that uses the shared start helper is also run alone (`sh <file>`) and killed
  with TERM, and again with KILL; its fixture, and the process the fixture started with `setsid`, must be gone within 10
  seconds. A start through the helper is checked to leave `$!` as the fixture's own pid, a child of the test shell that
  the shell can `kill` and `wait` for, and `x=$(<start through the helper>; echo ok)` must return within a few seconds.
  In that check the fixture's own stdin, stdout and stderr are redirected (`</dev/null >/dev/null 2>&1`, as the shared
  helpers' starts do), so that the check measures the helper and its watch: a fixture that inherits stdout keeps any
  `$(...)` open, helper or not. The runner's `TIME`, `FAILED`, `SLOW` and `TOTAL` lines and its exit status are checked
  to be as D03 made them. The scenarios run concurrently, so the file takes about 15 seconds (one 10-second wait and a
  TERM-then-KILL grace), under `TEST_FILE_BUDGET` (30 s locally, 60 s in CI).
- `scheduler/runtests.test.sh` (D03-AC-4) and the test files that source the changed helpers pass unchanged.

## Changes
1. **The read.** The PR lists every place where a test file or a shared helper under `scheduler/testdata/lib/` starts a
   background process: file, line, how the process is started (`&`, `setsid`, a fake `tmux`), and what ends it today
   (an EXIT trap, a `pkill -f "$tmp/..."`, nothing). Known so far (line numbers as of `main` at `deb92c1`):
   - `scheduler/site.test.sh`'s fake sessions (the script written at line 54, started at lines 151 and 152) and its lock
     holder (line 154), ended only by its EXIT trap (cleanup at lines 25–30, `trap cleanup EXIT` at line 31);
   - `scheduler/testdata/lib/api-common.sh`'s `live()` (line 26), a fake session ended by the cleanup that waits on
     `$pids`;
   - `scheduler/testdata/lib/api-setup.sh`'s lock holder (line 30, a `flock ... sh -c 'while :; do sleep 1; done'` whose
     child outlives `flock`) and its API server (`start_server`, line 90);
   - `scheduler/testdata/lib/loops-body.sh`'s fake `tmux` (line 27) and its second fake `tmux` (line 528), its
     `start_loop` and `start_session` (lines 72 and 78), the runtime-root and no-newline fixtures (lines 236, 245 and
     364), and its other loop, session, lock, API server and `env -u` starts (lines 373, 387, 458, 612, 664, 715 and
     768), all ended only by its EXIT trap (line 9);
   - `scheduler/testdata/lib/report-w05.sh`'s fake session (line 47);
   - the loop starts in `loop-s07.sh` (line 148), `loop-g01.sh`, `loop-s01.sh` and `loop-g02.sh`.

   The read marks as exempt, with the reason, each start that stays as it is: a short-lived start the test waits for
   (`api-common.sh`'s `ended()`, line 29; `loops-body.sh`'s dead-pid `sh -c : &`, lines 154 and 410) and a helper of the
   test shell itself (`report-fakegh.sh`'s watchdog, the subshell ending at line 58; `loop-s09.sh`'s ticker, line 91).
   *D11-AC-4.*
2. **The runner stops what a file started.** `scheduler/runtests.sh` starts each file in a process group of its own with
   `setsid` (for example `setsid -w "$sh" "$2"` inside `work`), so that a file's group holds only that file's processes
   and never the runner, `make` or the caller. It does not use `set -m`: `dash` without a terminal prints "can't access
   tty; job control turned off" on the runner's stderr and leaves the job in the runner's group. The runner signals only
   its files' groups and marked processes, never its own group. It also marks each file it starts with something every
   descendant inherits, even across `setsid`, so it can find them all. For example, it can put a per-file variable in
   the environment and read it from `/proc/<pid>/environ`, or give the file its own `TMPDIR` so that its `mktemp -d`
   folders are under one folder. When the file ends (passing, failing, crashing or killed), the runner stops every
   process that still carries the file's mark: TERM, then KILL for those still there a few seconds later. The stopping
   does not slow the suite: it runs in the background, or it waits only when it signalled something, so a file that
   leaves nothing behind adds no time to its `TIME` line or to `TOTAL`. When the runner stops a file on its own INT,
   TERM or HUP, it does the same for the file's own process group and every marked process. The runner's output, its
   `TIME`, `FAILED`, `SLOW` and `TOTAL` lines and its exit status do not change. *D11-AC-1, D11-AC-2.*
3. **The runner killed.** When the runner is killed with KILL, with or without its process group (a session being
   stopped), a watcher it starts outside its own process group sees it gone and stops every marked process of the
   run. The watcher then exits, and it exits as well when the run ends normally, so it never outlives the run by more
   than a few seconds. The watcher holds none of the runner's stdin, stdout or stderr, so a pipe reading the runner's
   output (`make test | ...`) ends when the runner ends. *D11-AC-2.*
4. **Fixtures that end with their file.** A shared start helper in `scheduler/testdata/lib/` starts a background
   fixture in its own session, as `setsid` does, so that the checks that read a session's process group still hold. Its
   contract:
   - After a start through the helper, `$!` is the fixture's own pid, a child of the test shell, so that frozen tests
     that `kill "$p"; wait "$p"` (such as `loop-s03.test.sh` at line 252) or wait on a list of pids (`api-common.sh`'s
     cleanup, line 11) work unchanged.
   - The helper and the watch it starts hold none of the caller's stdin, stdout or stderr, so `x=$(<start> ...)` and a
     pipe reading the test's output do not wait for the helper or the watch. The fixture's own stdio is the caller's to
     redirect, as the shared helpers' starts already do (`</dev/null >/dev/null 2>&1`): a fixture that inherits stdout
     keeps a `$(...)` open, helper or not.
   - The watch finds the test file's shell through an exported variable, not its parent, so that it also works for a
     fixture started from a process that is not the test shell's child, such as the fake `tmux` scripts that the loops
     under test run.
   - The helper puts a per-fixture mark in the fixture's environment. When the shell of the test file that started the
     fixture is gone, however that shell ended, the watch stops, within a few seconds, the fixture's process group and
     every process that carries the fixture's mark, so that processes the fixture starts in sessions of their own end
     too: real `loop.sh` fixtures start their sessions with `setsid` (`scheduler/loop.sh` lines 677 and 731), as
     `loop-g01.sh`, `loop-s01.sh` and `loop-g02.sh` do.
   - The fixture also has a hard lifetime (an upper bound in seconds, well over `TEST_FILE_BUDGET`).

   The test files and shared helpers start every long-running fixture the read lists through it; the starts the read
   marks exempt stay as they are and are covered by the runner (changes 2 and 3).

   Every existing line of a `*.test.sh` file and of `scheduler/testdata/` is frozen, the shared helpers included. As
   D03 did (its change 7), this spec allows, for this node only, changing exactly these existing lines (line numbers as
   of `main` at `deb92c1`); merging this spec is the owner's approval of them:
   - `scheduler/testdata/lib/loops-body.sh`: the EXIT trap at line 9, and the starts at lines 27, 72, 78, 236, 245,
     364, 373, 387, 458, 528, 612, 664, 715 and 768;
   - `scheduler/testdata/lib/api-common.sh:26` (`live()`), `api-setup.sh:30` (the lock holder) and `:90`
     (`start_server`), and `report-w05.sh:47`;
   - `scheduler/testdata/lib/loop-s07.sh:148`, and the loop starts in `loop-g01.sh` (line 267), `loop-s01.sh` (line 67)
     and `loop-g02.sh` (line 145);
   - `scheduler/site.test.sh`'s starts at lines 151, 152 and 154.

   Each of these lines changes in one way only. A start line moves its start into the start helper and keeps every
   setting on the line (its command, arguments, redirections, environment and what it does with `$!`). The
   EXIT trap changes only in how it stops fixtures. No check, no expected value or pattern a check compares against,
   and no wait changes, and D11-AC-4's diff check enforces that. Any other existing line of the frozen paths (a start
   the read finds beyond those named here, say) changes only with the owner's approval of that line, asked for one
   line at a time; without it, the start stays as it is, the PR lists it, and the runner covers it but not when its
   file runs alone. A new helper file and lines added to an existing one need no approval. The PR lists every changed
   existing line and quotes this approval (or, for a line not named here, the owner's own). *D11-AC-3, D11-AC-4.*
5. **Recorded runs.** On the scheduler's machine, `TEST_JOBS=2 make test TESTS="<the files the read lists as starting
   background fixtures>"` runs once to the end and once stopped partway with TERM sent to `make`, which passes it on to
   its child, the runner. These runs check the files that start fixtures, as D09's quick gate runs a chosen set of files
   rather than the whole suite. Each run has `TMPDIR` set to a folder of its own, so that every scratch folder of the
   run is under that folder. `TMPDIR` is set only on the run's command (`TMPDIR=<folder> TEST_JOBS=2 make test ...`),
   never exported in the shell that checks for leaks, and the check leaves out its own process and its children, so that
   it never matches itself. Ten seconds after each run ends, the list of processes that name that folder in their
   command line, working directory or open file descriptors (`/proc/<pid>/fd`), or that hold that `TMPDIR` in their
   environment (`/proc/<pid>/environ`), is recorded under `out/node/D11/` and is empty. The PR holds a summary of both
   runs: each run's exit status, its `TOTAL` line and the empty process list. *D11-AC-5.*

## Gate
- **D11-AC-1** — When a test file run by `scheduler/runtests.sh` ends in any way (passing, failing partway, or killed with KILL from outside) and leaves background processes it started (with `&` or with `setsid`), none of them remains 10 seconds later. The runner's `TIME`, `FAILED`, `SLOW` and `TOTAL` lines and its exit status are unchanged. *Verify:* `sh scheduler/runtests-d11.test.sh`.
- **D11-AC-2** — When `scheduler/runtests.sh` is sent TERM partway, or is killed with KILL together with its process group, no process that its running test files started (also those started with `setsid`) remains 10 seconds later, and no process of the runner remains either. Sent TERM, the runner signals only its test files' process groups and the processes they started: a process in the runner's own process group that no test file started is still running afterwards. *Verify:* `sh scheduler/runtests-d11.test.sh`.
- **D11-AC-3** — A fixture started through the shared start helper runs in its own session and, with the processes it starts in sessions of their own, ends within 10 seconds after the shell of the test file that started it ends, also when the file runs alone (`sh <file>`) and is killed with TERM or with KILL. After a start through the helper, `$!` is the fixture's pid, a child of the test shell, and a command substitution around the start returns without waiting for the fixture. Every long-running fixture the read lists in the shared helpers under `scheduler/testdata/lib/` and in `scheduler/site.test.sh` starts through it, except a start on an existing frozen line that change 4 does not name and the owner has not approved one line at a time, which the PR lists. *Verify:* `sh scheduler/runtests-d11.test.sh`, and the fresh reviewer's check that every long-running fixture the read lists starts through the helper, each start change 4 names among them, and that each start the read marks exempt is a short-lived start the test waits for or a helper of the test shell itself.
- **D11-AC-4** — The PR records the read (every background start in the test files and shared helpers, with what ends it before and after the node, and the exempt starts with their reasons). Every changed or removed existing line of a `*.test.sh` file or of a file under `scheduler/testdata/` is listed in the PR as a frozen-line change and is either a line change 4 names, with change 4's approval quoted, or a line the owner approved on its own, with that approval quoted. Each such change only moves a start to the shared start helper, keeping every setting on the line, or changes how `loops-body.sh`'s EXIT trap stops fixtures. No check, no expected value or pattern a check compares against, and no wait in `scheduler/*.test.sh` or `scheduler/testdata/` is changed, loosened or removed. *Verify:* the record in the PR, and the fresh reviewer's check of `git diff <base>..HEAD` over the test paths.
- **D11-AC-5** — On the scheduler's machine, `TEST_JOBS=2 make test TESTS="<the files the read lists as starting background fixtures>"` runs with `TMPDIR` set to a folder of its own on the run's command only, once to the end and once stopped partway with TERM sent to `make`. Ten seconds after each run ends, no process names that folder in its command line, working directory or open file descriptors, or holds that `TMPDIR` in its environment, leaving out the checking process and its children. *Verify:* the recorded process lists and run logs under `out/node/D11/`, and the summary of both runs in the PR (exit status, `TOTAL` line and the empty process list).

## Risks
- Whatever mark the runner or the helper uses can be lost. A test that clears the environment (`env -i`) loses an
  environment mark, and a test that sets its own `TMPDIR` or writes outside `mktemp` loses a folder mark. The read
  (change 1) names such tests, and a process the mark misses is caught only by the helper's watch.
- The starts the read marks exempt (a test shell's own helpers such as `loop-s09.sh`'s ticker), and any start the read
  finds on a frozen line that change 4 does not name and the owner does not approve, are covered only under the
  runner, not when their file runs alone and is killed.
- The node that spec PR #167 adds for issue #166 (D12 there, not yet merged) also changes `loops-body.sh`'s EXIT trap at line 9: it guards the
  `mktemp -d` line before it (line 8) and the trap's `pkill -f "$tmp/"`, which ran as `pkill -f "/"` when `$tmp` was
  empty. Whichever of the two nodes merges second keeps both changes: that node's guards, and D11's change of how the trap stops
  fixtures, which never signals by a pattern or path that can be empty or `/`.
- Stopping a file's processes after every file must not slow the suite: the TERM-then-KILL grace runs in the
  background or only when something was signalled (change 2), since D08 fails pull requests over the time budgets.
- Stopping the processes of a file that has ended must not reach another file's processes, or the processes of
  another `make test` running at the same time (several sessions run tests at once). The mark is per file and per run,
  never a pattern such as `/tmp/tmp.*`.
- Several cases check a session's process group (sessions run under `setsid`, and the group id is the pid in
  `session.pid`). The helper must keep the fixture's own session and process group, and its watch must not be in that
  group, or a test that kills the group would see an extra process.
- M02 (planned) changes the waits next to `loops-body.sh`'s `start_loop` and `start_session` starts: D11's start lines
  72 and 78 sit next to M02's waits at lines 73 and 80. Whichever of the two nodes merges second resolves the conflict,
  keeping both: D11 changes the start lines and M02 the waits.
- D05 (merged) owns the settings `scheduler/testdata/lib/loop-s07.sh` starts its loops with, and D11 changes how that
  start (line 148) is made. D11 changes only the start itself and keeps every setting on that line; a later change to
  either keeps both.
- A watch that polls adds a small load per fixture. Its poll interval and the hard lifetime are kept coarse (about a
  second, and several minutes) so that fixtures cost less than the leaks did, and it reads the environments under
  `/proc` only once, after the test shell is gone.
- The issue's count came from one loaded morning. The recorded runs (change 5) show the fix on the machine but not
  every way a session can be stopped. A leak found later starts from the read.
