# D14 — cleanup-guards

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D12, S04, S06 | none | M |

**Owns:** `scheduler/testdata/lib/kill-own.sh` (new: the guarded kill of change 2) and `scheduler/kill-own.test.sh`
(new) with its line in the `Makefile`'s `TESTS`; a new `scheduler/scratch-guard-*.test.sh` with its line in `TESTS`, if
the new cases of changes 4-5 move there (Risks); in `scheduler/scratch-guard.test.sh` (D12's), the mktemp scan, the
namespace driver's `unshare` options and the environment it runs the files with, its wait before it reads the sentinel,
the `late` argument that runs the late-signal case alone, its handling of the scratch folder's path and its two skip
lines (changes 3-6); the sentence on `$PPID` in `AGENTS.md`'s Traps bullet on scratch folders (change 7); the read of
change 1, in the node's PR. As D03 (its change 7) and D12 did, this spec allows, for this node only, changing exactly
these existing lines of the frozen test paths (the `*.test.sh` files and `scheduler/testdata/`): the cleanup lines
`scheduler/loop-s06.test.sh:63`, `scheduler/loop-s06-update.test.sh:36`, `scheduler/loop-s06-later.test.sh:66` and
`scheduler/loop-s06-review.test.sh:130` (as of `main` at c38bb52), whose kills of the `pg.*` and `pg2.*` pid files go
through the guarded kill and which change in nothing else; one line sourcing `kill-own.sh` in
`scheduler/testdata/lib/loop-s06.sh`, which all four files source; the fake's `kill -KILL $PPID` at
`scheduler/loop-s04.test.sh:71`, which gains the check of change 2 and nothing else; each line the wider scan of change
3 finds unguarded (none on `main` at c38bb52), which gains only D12's guard; and the lines of
`scheduler/scratch-guard.test.sh` that changes 3-6 name. No check, compared value, wait or start of another
frozen line changes.
**Resolves:** #177

## Purpose
Four `loop-s06*` cleanups kill the process group whose number a fake claude wrote from its own `$PPID`
(`scheduler/testdata/lib/loop-s06-main.sh:48` and `:64`, `scheduler/loop-s06-review.test.sh:60` and `:73`). If the
fake's parent died before the fake started, `$PPID` is 1, and the cleanup then runs `kill -KILL -- -1`, which kills
every process of the user, as in issue #166; or it is the pid of a subreaper, and the cleanup then kills that subreaper
and its group, such as the user's `systemd --user`. The S04 fake's `kill -KILL $PPID` can likewise kill the user's
systemd manager. After this node no test cleanup or fake signals a pid or group taken from a fake's `$PPID` unless it is
a number above 1 whose command line names the test's scratch folder, except the fake make recipes of
`scheduler/deploy.test.sh` (change 1). Kills of a pid file written from `$!` (the `session.pid` files of
`loop-g01*.test.sh` and others) are not in scope: their value is never 1. The node also closes the gaps D12's
`scratch-guard.test.sh` left: the forms of `mktemp -d` its scan misses, a namespace run with network and the forge's
variables, a signal in the run's last fraction of a second that can go unrecorded, and a scratch path that is not
canonical turning the namespace case into a skip with a misleading reason.

## Tests
- `scheduler/kill-own.test.sh` (new, in the `Makefile`'s `TESTS`): the guarded kill of change 2, run inside a user and
  pid namespace of its own (`unshare --user --map-root-user --pid --fork --mount-proc`, probed as
  `scheduler/scratch-guard.test.sh` does), so that a broken guard that ran `kill -- -1` in this test reaches only the
  namespace. Inside it, a driver starts a sentinel, a group leader of its own (`setsid`) whose command line does not
  name the scratch folder, and a process group whose leader's command line does. The guarded kill, given pid files
  holding `1`, nothing, a value that is not a number, the sentinel's pid and the group leader's pid, signals only the
  group: the group and its leader are gone and the sentinel and its group still run. Given the group leader's pid file
  with a scratch folder that is empty, `/`, one whose canonical form is `/` (such as `/tmp/..`), not absolute or not an
  existing directory, it signals nothing (the group still runs). Each such bad folder is one the leader's command line
  names followed by `/` (an argument holding `//` for `/` and for a folder whose canonical form is `/`, a path under
  the missing folder for one that does not exist, and a path holding the relative folder for one that is not
  absolute), so that only the refusal keeps the group from being killed. Given the scratch folder through a symlink
  while the leader's command line names the canonical path, it kills the group. A sibling folder whose name starts
  with the scratch folder's name (`<folder>x`) named on a process's command line does not count as the scratch
  folder. A second case reads the five lines of change 2 and shows that each kills its `pg.*`, `pg2.*` or `$PPID`
  value only through the check: a call to `kill-own.sh` in the four S06 lines, and in the S04 fake the same check
  written into its line, made against the scratch folder that holds `$S04` (`${S04%/*}`), not against `$S04`. Where
  the machine refuses the namespace, the first case runs nothing that signals and passes with a line naming the
  skip, as D12-AC-3 does.
- `scheduler/scratch-guard.test.sh` (D12's, extended as changes 3-6 say): fixture lines for each new form of change 3,
  the probe of change 4 and the late-signal run of change 5. Every case that passes on the base still passes, and every
  `PASS:` name the base prints is still printed, except the two skip lines, which may be reworded (changes 4 and 6).
- `scheduler/loop-s04.test.sh` and the four `loop-s06*` files (changed only as **Owns** allows): every case that passes
  on the base still passes.
- `scheduler/kill-own.test.sh`, any new `scratch-guard-*.test.sh` and `scheduler/scratch-guard.test.sh` stay under
  `TEST_FILE_BUDGET`; the S04 and S06 files changed only by a cleanup or fake line gain no wait, sleep or retry:
  `kill-own.sh` and the S04 check only read `/proc` and signal.

## Changes
1. **The read.** Every `kill`, `pkill` and `killall` in the files of the `Makefile`'s `TESTS` and in
   `scheduler/testdata/` whose pid or group comes from `$PPID`, directly or through a file a fake wrote, is listed with
   where its value comes from, whether that value can be 1, empty or a process outside the test, and the change this
   node makes to it or why it needs none. At least the issue's sites: the four `loop-s06*` cleanups and their writers
   (above), `scheduler/loop-s04.test.sh:71`, and `scheduler/deploy.test.sh:182` and `:194` (`kill -KILL $$PPID` in a
   make recipe: no change). The read gives the recipes' real reason: their KILL goes to one pid, never a group, so it
   cannot become `kill -- -1`, and a KILL to pid 1 is refused or ignored by the kernel; their make is `make -C
   "$scratch/wt"` in `deploy.sh`'s own `mktemp -d` folder, not the test's scratch folder, so no command-line check
   against that folder can be written there; what is left is a make that ended before its recipe shell started, when the
   KILL reaches the nearest subreaper, the same race the S04 fake has, which this node does not guard in these two
   lines. The `child.*` files of the S06 cleanups hold `$!` of a `sleep` and are listed with the reason their kill stays
   as it is. The read is recorded in the PR. *D14-AC-1.*
2. **The guarded kill.** `scheduler/testdata/lib/kill-own.sh` (POSIX sh) gives a function that, given a scratch folder
   and pid files, sends KILL to the process group and the pid each file holds only when the value is a number above 1
   and `/proc/<pid>/cmdline` names `<folder>/`, with the trailing slash, as the scratch folder was given or in its
   canonical form; any other value is left alone. It signals nothing at all when the scratch folder it is given is
   empty, `/`, one whose canonical form is `/`, not absolute or not an existing directory. The four `loop-s06*`
   cleanup lines pass their `pg.*` and `pg2.*` files through it. The S04 fake (`loop-s04.test.sh:71`) is a quoted
   heredoc whose only path to the scratch folder is `$S04`, so the same check is written into its line: it kills
   `$PPID` only when `${S04%/*}`, the scratch folder that holds `$S04`, passes the folder checks, `$PPID` is above 1,
   and its command line names `${S04%/*}/` as given or in its canonical form (`run-session.sh` is under `$tmp/nb7/`,
   never under `$S04/`). A leader that has already ended is then not signalled; what is left of its group is stopped
   by D11's runner, which stops every process carrying its file's `NBRT_` mark, and, for those whose command line
   names the folder, by the prelude's `pkill -f "$tmp/"`. *D14-AC-2.*
3. **The scan sees every form.** The mktemp case of `scratch-guard.test.sh` also reads assignments of the form
   `<var>="$(mktemp -d …)"`, `` <var>=`mktemp -d …` ``, `$( mktemp -d … )` with spaces, `mktemp --directory`,
   `mktemp` with `-d` after other options (`mktemp -p "$x" -d`) and `-d` inside combined short options where it is
   not first (`mktemp -qd`, `mktemp -td x`), with or without a leading `local` or `export`. Each must carry the guard
   `&& [ -d "$<var>" ] || exit 1`; a guarded line of any of these forms, `local` and `export` included, is not
   reported. A fixture line of each form, unguarded, is reported by `file:line`, and its guarded twin is not. Every
   such line in scope that the wider scan finds unguarded gains only that guard. *D14-AC-3.*
4. **The namespace reaches nothing.** The namespace case's `unshare` also takes `--net`, so the files see only a
   loopback interface, and the driver runs each file with `env -i` and only `PATH`, `HOME`, `TMPDIR` and, when it is
   set, D11's runner mark `NBRT_<pid>` passed through: an allow-list, so a credential variable added later is left out
   too. A probe that the driver runs the way it runs a test file, with fake values of `NOODLEBOT_FORGE`, `GH_TOKEN`,
   `GITHUB_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY` set on the namespace's command, records its
   environment's names and `/proc/net/dev`; the outer test checks that it has no variable but the allow-list and those
   the shell sets itself (`PWD`, and for a file run with `bash` also `SHLVL` and `_`), and that `lo` is the only
   interface. Where the machine refuses the namespace with `--net`, the case skips as it does today, with a line naming
   the skip. *D14-AC-4.*
5. **A late signal is recorded.** The driver reads the sentinel's state only after the sentinel has had time to run
   the trap of any signal it got as the last file ended (the issue measured 116-179 ms from a TERM to the record; the
   sentinel's `sleep 0.2` delays its trap), by waiting longer than one sentinel tick after the last file ends (the
   sentinel's own line stays as it is). A second, short driver run checks it in the worst case: its only file is a
   stand-in that waits until the sentinel has just started a new `sleep` (a new child of the sentinel in `/proc`),
   then sends TERM to the sentinel and exits at once; the record must show that TERM. The file that holds the case
   runs it alone, with the namespace probe it needs, when given the argument `late` (`sh <file> late`). The case
   fails on D12's driver; the RED run records a failing run (the driver's poll phase is not fixed, so on the base it
   fails in most runs rather than every run). *D14-AC-5.*
6. **The scratch path is canonical.** The test compares the canonical path of its scratch folder with
   `/proc/self/mountinfo`, made right after the guarded `mktemp -d` line and before the trap is set, with its own
   guard: `tmp=$(cd "$tmp" && pwd -P) && [ -d "$tmp" ] || exit 1`. So a `TMPDIR` that holds `..` or a symlink no
   longer remounts the scratch folder read-only. A skip line names the check that failed; a driver that started is
   never reported as "driver did not start". *D14-AC-6.*
7. **`AGENTS.md` says it.** The Traps bullet on scratch folders gains one sentence: a cleanup or fake that signals a pid
   or group taken from `$PPID`, or read from a file a fake wrote from `$PPID`, first checks that it is a number above 1
   whose command line names the test's scratch folder (`scheduler/testdata/lib/kill-own.sh`), because a parent that has
   ended makes `$PPID` 1 and `kill -- -1` signals every process of the user; except the make recipes of
   `scheduler/deploy.test.sh`, whose `$$PPID` is a single make outside the test's scratch folder (change 1). *D14-AC-7.*

## Gate
- **D14-AC-1** — The PR records the read of change 1: every `kill`, `pkill` and `killall` in the `Makefile`'s `TESTS` files and `scheduler/testdata/` whose pid or group comes from `$PPID`, directly or through a pid file a fake wrote, each with its source, whether it can be 1, empty or outside the test, and the change made or why none; at least the four `loop-s06*` cleanups, `scheduler/loop-s04.test.sh:71` and `scheduler/deploy.test.sh:182` and `:194`. *Verify:* the record in the PR, checked by the fresh reviewer against `grep -nE '\$\$?PPID'` and the `pg.*`/`pg2.*` writers over the same files.
- **D14-AC-2** — Inside a user and pid namespace of its own, the guarded kill of `scheduler/testdata/lib/kill-own.sh`, given pid files holding `1`, nothing, a non-number, the pid of a sentinel (a group leader of its own) whose command line does not name the scratch folder, and the pid of a group leader whose command line names `<folder>/`, signals only that group (the group and its leader are gone, the sentinel and its group still run); given the group leader's pid file with a scratch folder that is empty, `/`, one whose canonical form is `/`, not absolute or not an existing directory, each named on the leader's command line followed by `/` (an argument holding `//` for `/` and for a canonical `/`, a path under the missing folder, a path holding the relative folder), it signals nothing; given the folder through a symlink while the leader names the canonical path, it kills the group; a sibling `<folder>x` on a command line does not match; the four `loop-s06*` cleanup lines kill their `pg.*` and `pg2.*` values only through a call to `kill-own.sh`, and the S04 fake its `$PPID` only through the same check written into its line, made against `${S04%/*}`, the scratch folder that holds `$S04`, as given or canonical; where the namespace is refused, the behaviour case runs nothing that signals and passes with a line naming the skip. *Verify:* `scheduler/kill-own.test.sh`, and a recorded local run in the PR in which its namespace case ran (not skipped), made in the node's quick gate before any S06 file runs with the new cleanup lines.
- **D14-AC-3** — `scheduler/scratch-guard.test.sh`'s mktemp case reports by `file:line` an unguarded fixture line of each form of change 3 (quoted, backtick, spaced `$( … )`, `--directory`, `-d` after other options, `-d` inside combined short options where it is not first, and with `local` or `export`) and does not report the guarded twin of each; every such line in the `Makefile`'s `TESTS` files and `scheduler/testdata/lib/*.sh` is guarded. Accepting a guarded `local` or `export` line widens the literal form D12-AC-1 names (`<var>=$(mktemp -d …) && …`) and loosens no check. *Verify:* `scheduler/scratch-guard.test.sh`.
- **D14-AC-4** — In the namespace case, a probe run as the driver runs a test file, with fake values of `NOODLEBOT_FORGE`, `GH_TOKEN`, `GITHUB_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY` set on the namespace's command, has in its environment only `PATH`, `HOME`, `TMPDIR`, D11's `NBRT_<pid>` mark and the variables the shell sets itself (`PWD`, and for a file run with `bash` also `SHLVL` and `_`), and sees only the `lo` interface in `/proc/net/dev`; where the namespace with `--net` is refused, the case runs no file and passes with a line naming the skip. *Verify:* `scheduler/scratch-guard.test.sh`, and a recorded local run in the PR in which the namespace case ran (not skipped).
- **D14-AC-5** — A stand-in last file that sends TERM to the sentinel just after the sentinel starts a new tick (a new `sleep` child of the sentinel in `/proc`), and then exits at once, has that TERM recorded and the case reports it; the case fails on D12's driver (the RED run records a failing run; on the base it fails in most runs, not every run, as the driver's poll phase is not fixed); the late-signal case run alone with the argument `late` (`sh <file> late`, not the whole namespace run) passes in 20 consecutive local runs in which the namespace was made, recorded in the PR; where the namespace is refused, the case runs nothing and passes with a line naming the skip. *Verify:* `scheduler/scratch-guard.test.sh` (or the `scratch-guard-*.test.sh` it moves to), the RED run, and the PR's record of the 20 runs.
- **D14-AC-6** — With `TMPDIR` set to a path through a symlink, or holding `..`, to a folder where the namespace case runs with the canonical path, `scheduler/scratch-guard.test.sh`'s namespace case runs (it is not skipped) and passes; the canonical path is taken with its own guard before the trap is set; a skip line names the check that failed, never "driver did not start" for a driver that started. *Verify:* a recorded local run in the PR with each such `TMPDIR`, and the fresh reviewer's reading of the skip lines.
- **D14-AC-7** — The only existing lines changed under the frozen test paths are those **Owns** names, each changed only as it says: the four `loop-s06*` cleanup lines, one source line in `scheduler/testdata/lib/loop-s06.sh`, `scheduler/loop-s04.test.sh:71`, lines the wider scan finds unguarded (gaining only D12's guard) and the lines of `scheduler/scratch-guard.test.sh` that changes 3-6 name, with no check of that file loosened and every `PASS:` name of the base still printed but the two skip lines, which may be reworded; `AGENTS.md`'s Traps bullet has the sentence of change 7, with its exception for the make recipes of `scheduler/deploy.test.sh`; every case that passes on the base passes on the head; `scheduler/kill-own.test.sh`, any new `scratch-guard-*.test.sh` and `scheduler/scratch-guard.test.sh` stay under `TEST_FILE_BUDGET`, and the S04 and S06 files changed only by a cleanup or fake line gain no wait, sleep or retry (`kill-own.sh` and the S04 check only read `/proc` and signal). *Verify:* the fresh reviewer's check of `git diff <base>..HEAD` and reading of `kill-own.sh` and the changed lines, recorded in the PR, and the PR's CI run.

## Risks
- The guarded kill skips a group whose leader has already ended, so a fake's leftover processes are no longer killed
  by these cleanup lines. D11's runner stops them (every process with its file's `NBRT_` mark, a fake's `sleep 300`
  among them), the prelude's `pkill -f "$tmp/"` stops those whose command line names the folder, and a leftover shows
  in D11's checks rather than staying silent.
- `kill-own.test.sh` checks the guard's refusals only inside its namespace; the S06 and S04 lines run the guard outside
  it in every `make test`: on the scheduler's machine, in the node's quick gate and in CI. Where CI's runner refuses
  unprivileged user namespaces (and network namespaces for `--net`) those cases skip, and the recorded local runs
  are their evidence, as for D12-AC-3. So the node's quick gate runs `kill-own.test.sh` with its namespace case run
  (not skipped) before any S06 file runs with the new lines (D14-AC-2).
- `scratch-guard.test.sh` runs every test file in its namespace; the probe and the late-signal run add a few seconds.
  If the file nears `TEST_FILE_BUDGET`, the new cases move to `kill-own.test.sh` or a `scratch-guard-*.test.sh` of
  their own (**Owns**) rather than slowing the namespace run.
- The command-line check matches the scratch folder's path as the S06 and S04 fixtures name it (`$tmp/nb06/…`,
  `run-session.sh` under the scratch folder, canonical as `loop.sh` and `loop-s06-main.sh` make it); a fixture that
  starts its session from outside the scratch folder would make the guard skip its kill, which the S06 cases would
  show as a leftover group, not a wrong pass.
- `scheduler/loop-s06-later.test.sh` is near the 60 s `TEST_FILE_BUDGET` that PR runs enforce (61.74 s on CI run
  44395308749, 47.83 s on run 44398778243, same code), and the node's PR changes its cleanup line. A red `SLOW:` line
  for an S06 file is rerun, and recorded as unrelated when the file's diff is only the cleanup line.
- A node built at the same time that adds a test file with an unguarded `mktemp -d` line of one of the new forms
  fails the mktemp case once both are on `main`; the node that merges second guards that line, as `AGENTS.md` says.
