# D14 — cleanup-guards

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D12, S04, S06 | none | M |

**Owns:** `scheduler/testdata/lib/kill-own.sh` (new: the guarded kill of change 2) and `scheduler/kill-own.test.sh`
(new) with its line in the `Makefile`'s `TESTS`; in `scheduler/scratch-guard.test.sh` (D12's), the mktemp scan, the
namespace driver's `unshare` options and the environment it runs the files with, its wait before it reads the
sentinel, its handling of the scratch folder's path and its skip lines (changes 3-6); the sentence on pid files in
`AGENTS.md`'s Traps bullet on scratch folders (change 7); the read of change 1, in the node's PR. As D03 (its change
7) and D12 did, this spec allows, for this node only, changing exactly these existing lines of the frozen test paths
(the `*.test.sh` files and `scheduler/testdata/`): the cleanup lines `scheduler/loop-s06.test.sh:63`,
`scheduler/loop-s06-update.test.sh:36`, `scheduler/loop-s06-later.test.sh:66` and
`scheduler/loop-s06-review.test.sh:130` (as of `main` at c38bb52), whose kills of the `pg.*` and `pg2.*` pid files go
through the guarded kill and which change in nothing else; one line sourcing `kill-own.sh` in
`scheduler/testdata/lib/loop-s06.sh`, which all four files source; the fake's `kill -KILL $PPID` at
`scheduler/loop-s04.test.sh:71`, which gains the guard of change 2 and nothing else; each line the wider scan of
change 3 finds unguarded, which gains only D12's guard; and the lines of `scheduler/scratch-guard.test.sh` that
changes 3-6 name. No check, compared value, wait or start of another frozen line changes.
**Resolves:** #177

## Purpose
Four `loop-s06*` cleanups kill the process group whose number a fake claude wrote from its own `$PPID`
(`scheduler/testdata/lib/loop-s06-main.sh:48` and `:64`, `scheduler/loop-s06-review.test.sh:60` and `:73`). If the
fake's parent died before the fake started, `$PPID` is 1, or the pid of a subreaper such as `systemd --user`, and the
cleanup runs `kill -KILL -- -1`, which kills every process of the user, as in issue #166; the S04 fake's
`kill -KILL $PPID` can likewise kill the user's systemd manager. After this node no test cleanup or fake signals a pid
or group taken from `$PPID` unless it is a number above 1 whose command line names the test's own scratch folder. The
node also closes the gaps D12's `scratch-guard.test.sh` left: the forms of `mktemp -d` its scan misses, a namespace
run with network and the forge's variables, a signal in the run's last fraction of a second that can go unrecorded,
and a scratch path that is not canonical turning the namespace case into a skip with a misleading reason.

## Tests
- `scheduler/kill-own.test.sh` (new, in the `Makefile`'s `TESTS`): the guarded kill of change 2, run inside a user and
  pid namespace of its own (`unshare --user --map-root-user --pid --fork --mount-proc`, probed as
  `scheduler/scratch-guard.test.sh` does), so that even a broken guard that ran `kill -- -1` reaches only the
  namespace. Inside it, a driver starts a sentinel whose command line does not name the scratch folder, and a process
  group whose leader's command line does. The guarded kill, given pid files holding `1`, nothing, a value that is not a
  number, the sentinel's pid and the group leader's pid, signals only the group: the group and its leader are gone,
  the sentinel still runs and the driver records no signal. A second case reads the five lines of change 2 and shows
  that each kills its `pg.*`, `pg2.*` or `$PPID` value only through the guard. Where the machine refuses the namespace,
  the first case runs nothing that signals and passes with a line naming the skip, as D12-AC-3 does.
- `scheduler/scratch-guard.test.sh` (D12's, extended as changes 3-6 say): fixture lines for each new form of change 3,
  the probe of change 4 and the late-signal run of change 5. Every case that passes on the base still passes, and
  every `PASS:` name the base prints is still printed.
- `scheduler/loop-s04.test.sh` and the four `loop-s06*` files (changed only as **Owns** allows): every case that passes
  on the base still passes.
- Every changed or new file stays under `TEST_FILE_BUDGET` (30 s).

## Changes
1. **The read.** Every `kill`, `pkill` and `killall` in the files of the `Makefile`'s `TESTS` and in
   `scheduler/testdata/` whose pid or group comes from `$PPID`, directly or through a file a fake wrote, is listed with
   where its value comes from, whether that value can be 1, empty or a process outside the test, and the change this
   node makes to it or why it needs none. At least the issue's sites: the four `loop-s06*` cleanups and their writers
   (above), `scheduler/loop-s04.test.sh:71`, and `scheduler/deploy.test.sh:182` and `:194` (`kill -KILL $$PPID` in a
   make recipe, whose parent is make, which waits for its recipe shell: no change). The `child.*` files of the S06
   cleanups hold `$!` of a `sleep` and are listed with the reason their kill stays as it is. The read is recorded in
   the PR. *D14-AC-1.*
2. **The guarded kill.** `scheduler/testdata/lib/kill-own.sh` (POSIX sh) gives a function that, given a scratch folder
   and pid files, sends KILL to the process group and the pid each file holds only when the value is a number above 1
   and `/proc/<pid>/cmdline` names the scratch folder (as the file was given it, or canonical); any other value is
   left alone. The four `loop-s06*` cleanup lines pass their `pg.*` and `pg2.*` files through it, and the S04 fake
   (`loop-s04.test.sh:71`) kills `$PPID` only when the same check holds (`$PPID` is above 1 and its command line names
   the scratch folder). A leader that has already ended is then not signalled; what is left of its group is stopped by
   the prelude's `pkill -f "$tmp/"` and by D11's runner. *D14-AC-2.*
3. **The scan sees every form.** The mktemp case of `scratch-guard.test.sh` also reads assignments of the form
   `<var>="$(mktemp -d …)"`, `` <var>=`mktemp -d …` ``, `$( mktemp -d … )` with spaces, `mktemp --directory` and
   `mktemp` with `-d` after other options (`mktemp -p "$x" -d`), with or without a leading `local`. Each must carry the
   guard `&& [ -d "$<var>" ] || exit 1`; a guarded line of any of these forms, `local` included, is not reported. A
   fixture line of each form, unguarded, is reported by `file:line`, and its guarded twin is not. Every such line in
   scope that the wider scan finds unguarded gains only that guard. *D14-AC-3.*
4. **The namespace reaches nothing.** The namespace case's `unshare` also takes `--net`, so the files see only a
   loopback interface, and the driver runs each file with no variable whose name starts with `NOODLEBOT_FORGE` and
   without `GH_TOKEN`, `GITHUB_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY`. A probe that the driver runs
   the way it runs a test file, with fake values of those variables set on the namespace's command, records its
   environment's names and `/proc/net/dev`; the outer test checks that none of the variables is there and that `lo` is
   the only interface. Where the machine refuses the namespace with `--net`, the case skips as it does today, with a
   line naming the skip. *D14-AC-4.*
5. **A late signal is recorded.** The driver reads the sentinel's state only after the sentinel has had time to run
   the trap of any signal it got as the last file ended (the issue measured 116-179 ms from a TERM to the record; the
   sentinel's `sleep 0.2` delays its trap), for example by waiting longer than one sentinel tick or by making the
   sentinel's trap run at once. A second, short driver run whose only file is a stand-in that sends TERM to the
   sentinel as it exits shows that signal in the record. *D14-AC-5.*
6. **The scratch path is canonical.** The test compares the canonical path of its scratch folder (for example
   `tmp=$(cd "$tmp" && pwd -P)` after the guarded `mktemp -d` line) with `/proc/self/mountinfo`, so a `TMPDIR` that
   holds `..` or a symlink no longer remounts the scratch folder read-only. A skip line names the check that failed;
   a driver that started is never reported as "driver did not start". *D14-AC-6.*
7. **`AGENTS.md` says it.** The Traps bullet on scratch folders gains one sentence: a cleanup that signals a pid or
   group read from a file, or taken from `$PPID`, first checks that it is a number above 1 whose command line names the
   test's scratch folder (`scheduler/testdata/lib/kill-own.sh`), because a parent that has ended makes `$PPID` 1 and
   `kill -- -1` signals every process of the user. *D14-AC-7.*

## Gate
- **D14-AC-1** — The PR records the read of change 1: every `kill`, `pkill` and `killall` in the `Makefile`'s `TESTS` files and `scheduler/testdata/` whose pid or group comes from `$PPID`, directly or through a pid file a fake wrote, each with its source, whether it can be 1, empty or outside the test, and the change made or why none; at least the four `loop-s06*` cleanups, `scheduler/loop-s04.test.sh:71` and `scheduler/deploy.test.sh:182` and `:194`. *Verify:* the record in the PR, checked by the fresh reviewer against `grep -nE '\$\$?PPID'` and the `pg.*`/`pg2.*` writers over the same files.
- **D14-AC-2** — Inside a user and pid namespace of its own, the guarded kill of `scheduler/testdata/lib/kill-own.sh`, given pid files holding `1`, nothing, a non-number, the pid of a sentinel whose command line does not name the scratch folder, and the pid of a group leader whose command line does, signals only that group (the group and its leader are gone, the sentinel still runs and records no signal); the four `loop-s06*` cleanup lines kill their `pg.*` and `pg2.*` values, and the S04 fake its `$PPID`, only through that check; where the namespace is refused, the behaviour case runs nothing that signals and passes with a line naming the skip. *Verify:* `scheduler/kill-own.test.sh`, and a recorded local run in the PR in which its namespace case ran (not skipped).
- **D14-AC-3** — `scheduler/scratch-guard.test.sh`'s mktemp case reports by `file:line` an unguarded fixture line of each form of change 3 (quoted, backtick, spaced `$( … )`, `--directory`, `-d` after other options, and with `local`) and does not report the guarded twin of each; every such line in the `Makefile`'s `TESTS` files and `scheduler/testdata/lib/*.sh` is guarded. *Verify:* `scheduler/scratch-guard.test.sh`.
- **D14-AC-4** — In the namespace case, a probe run as the driver runs a test file, with fake values of the forge and token variables of change 4 set on the namespace's command, has none of them in its environment and sees only the `lo` interface in `/proc/net/dev`; where the namespace with `--net` is refused, the case runs no file and passes with a line naming the skip. *Verify:* `scheduler/scratch-guard.test.sh`, and a recorded local run in the PR in which the namespace case ran (not skipped).
- **D14-AC-5** — A driver run whose only file is a stand-in that sends TERM to the sentinel as it exits records that TERM, and the case reports it; the same check passes in 20 consecutive local runs, recorded in the PR. *Verify:* `scheduler/scratch-guard.test.sh`, and the PR's record of the 20 runs.
- **D14-AC-6** — With `TMPDIR` set to a path through a symlink, or holding `..`, to a folder where the namespace case runs with the canonical path, `scheduler/scratch-guard.test.sh`'s namespace case runs (it is not skipped) and passes; a skip line names the check that failed, never "driver did not start" for a driver that started. *Verify:* a recorded local run in the PR with each such `TMPDIR`, and the fresh reviewer's reading of the skip lines.
- **D14-AC-7** — The only existing lines changed under the frozen test paths are those **Owns** names, each changed only as it says: the four `loop-s06*` cleanup lines, one source line in `scheduler/testdata/lib/loop-s06.sh`, `scheduler/loop-s04.test.sh:71`, lines the wider scan finds unguarded (gaining only D12's guard) and the lines of `scheduler/scratch-guard.test.sh` that changes 3-6 name, with no check of that file loosened and every `PASS:` name of the base still printed; `AGENTS.md`'s Traps bullet has the sentence of change 7; every case that passes on the base passes on the head, and each changed or new file stays under `TEST_FILE_BUDGET`. *Verify:* the fresh reviewer's check of `git diff <base>..HEAD`, recorded in the PR, and the PR's CI run.

## Risks
- The guarded kill skips a group whose leader has already ended, so a fake's leftover processes are no longer killed
  by these cleanup lines; the prelude's `pkill -f "$tmp/"` and D11's runner stop them, and a leftover shows in D11's
  checks rather than staying silent.
- `kill-own.test.sh` and the extended namespace case need unprivileged user namespaces (and network namespaces for
  `--net`); where CI's runner refuses them those cases skip, and the recorded local runs are their evidence, as for
  D12-AC-3. A broken guard is only ever exercised inside the namespace, so it cannot reach the user's processes.
- `scratch-guard.test.sh` runs every test file in its namespace; the probe and the late-signal run add a few seconds.
  If the file nears `TEST_FILE_BUDGET`, the new cases move to `kill-own.test.sh` or a `scratch-guard-*.test.sh` of
  their own rather than slowing the namespace run.
- The command-line check matches the scratch folder's path as the S06 and S04 fixtures name it (`$tmp/nb06/…`,
  `run-session.sh` under the scratch folder); a fixture that starts its session from outside the scratch folder would
  make the guard skip its kill, which the S06 cases would show as a leftover group, not a wrong pass.
- A node built at the same time that adds a test file with an unguarded `mktemp -d` line of one of the new forms fails
  the mktemp case once both are on `main`; the node that merges second guards that line, as the `AGENTS.md` bullet
  says.
