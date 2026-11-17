# D12 — scratch-guard

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D03 | M02 | M |

**Owns:** `scheduler/scratch-guard.test.sh` (new) and its line in the `Makefile`'s `TESTS`; a bullet of `AGENTS.md`'s
Traps on a test's scratch folder and its cleanup; the read of the cleanup commands (change 2), in the node's PR. As
D03 (its change 7) did, this spec allows, for this node only, changing exactly these existing lines of the frozen test
paths (the `*.test.sh` files and `scheduler/testdata/`): each line that assigns `$(mktemp -d …)` to a variable, which
gains `&& [ -d "$<var>" ] || exit 1` and nothing else, or, where the line already ends in `|| exit 1`, gains
`&& [ -d "$<var>" ]` inserted before that `|| exit 1` (change 1). No other frozen line changes: no cleanup command,
check, compared value or pattern, wait or start.
**Resolves:** #166

## Purpose
On 2026-11-17 a run of `scheduler/loops-status.test.sh` with a `TMPDIR` that did not exist stopped every process of
the user on the scheduler's machine: both loops, the API, three sessions, the tmux servers and the user's systemd
manager. `scheduler/testdata/lib/loops-body.sh:8` (`tmp=$(mktemp -d)`) failed and left `tmp` empty, which `set -u`
does not catch, and the EXIT trap on line 9 ran `pkill -f "$tmp/"`, that is `pkill -f "/"`. After this node a test
file whose scratch folder cannot be made stops at once, before it sets a trap or starts a process. No cleanup in a test
file or shared helper runs `pkill`, `kill` or `rm -rf` with a pattern or path that can be empty or `/`. A test runs
every test file with a `TMPDIR` that cannot be made and shows that a sentinel outside each file's process group gets
no signal. Keeping the loops alive when something signals the user's systemd manager (a systemd user service of their
own with `KillMode` settings, or lingering) is not part of this node; issue #166 leaves that to the owner.

## Tests
- `scheduler/scratch-guard.test.sh` (new, in the `Makefile`'s `TESTS`), with two cases:
  - **The mktemp lines.** It reads every file of the `Makefile`'s `TESTS` and every `scheduler/testdata/lib/*.sh`. Each
    line that assigns `$(mktemp -d …)` to a variable must have the form
    `<var>=$(mktemp -d …) && [ -d "$<var>" ] || exit 1`, and the case names each line that does not (`file:line`).
    It also shows that a fixture file in its own scratch folder, holding one unguarded line, is caught. This case runs
    everywhere.
  - **The run with a TMPDIR that cannot be made.** A driver runs inside a user, pid and mount namespace of its own
    (`unshare --user --map-root-user --pid --fork --mount-proc`, probed as `scheduler/loops-pidns.test.sh:253` does).
    The driver is the command `unshare --fork` starts, so it is the namespace's pid 1: it sets no trap for TERM, HUP
    or INT, and the kernel then delivers it no such signal sent from inside the namespace, so a file that signals
    every process it sees cannot end the driver. Before it starts anything, the driver bind-mounts the test's scratch
    folder over itself and remounts every other mount of the namespace read-only (a mount that refuses, such as
    `/proc/sys/fs/binfmt_misc`, stays as it is), then checks that it can make no file in the checkout, in the real
    `HOME` or in the real `TMPDIR` (or `/tmp`). It runs the files with their working directory and `HOME` in the
    scratch folder: a file that goes on with an empty path can change nothing outside the scratch folder. It then starts a sentinel: a shell whose command line contains `/`, which traps TERM,
    HUP and INT and records each one it gets in a file in the scratch folder. The driver then runs every file of the
    `Makefile`'s `TESTS` except this one, a few at a time, each in a session of its own (`setsid`), with `TMPDIR` set
    on its command to a path below a regular file in the scratch folder (for example `$scratch/afile/missing`, where
    `afile` is a file), so that both `mkdir -p` under it and `mktemp -d` fail. It writes each file's status, time and
    output, and whether the sentinel is still running after the last file, to the scratch folder. The outer test reads
    those records and the sentinel's after the namespace has ended, so a run in which a file ends the driver's work
    still reports FAIL rather than vanishing. Each file must end within 5 s with a non-zero status and print no
    `PASS:` line; after the last file the sentinel must still be running and have recorded no signal. The case never
    runs a test file outside the namespace. Where the machine refuses the namespace, or the driver can still make a
    file in the checkout, the real `HOME` or the real `TMPDIR`, it runs no test file and passes with a line naming the skip, as D06-AC-11 does, and the first case still runs.
  - The file stays under `TEST_FILE_BUDGET`.
- The existing test files and shared helpers (changed only as **Owns** allows): every case that passes on the node's
  base still passes.

## Changes
1. **Every scratch folder is checked where it is made.** Each line of a `*.test.sh` file in the `Makefile`'s `TESTS`
   or of a shared helper under `scheduler/testdata/lib/` that assigns `$(mktemp -d …)` to a variable gains
   `&& [ -d "$<var>" ] || exit 1`, so the file stops before it sets a trap or starts a process. As of `main` at
   49a9ed4 that is one line in each of the files that make their own folder, plus `loop-prelude.sh:10`,
   `loops-body.sh:8` and `guard-body.sh:9`, which the loop, loops and guard test files source.
   `scheduler/harness.test.sh:11` and `scheduler/loops-pidns.test.sh:15` already end in `|| exit 1`: the edit inserts
   `&& [ -d "$tmp" ]` before it, and the line gains nothing else. `guard-body.sh:373` holds `mktemp -d` inside a quoted
   command that a case checks and is not such a line. *D12-AC-1.*
2. **No cleanup with an empty or `/` pattern.** The read lists every `pkill`, `pgrep`, `killall`, `kill` and `rm -rf`
   in the files of change 1 whose pattern, pid or path is built from a variable. For each one it names where the value
   comes from and why, once change 1 is in, it can be neither empty nor `/`: the variable is set by a line guarded
   under change 1, or built from one by appending, before the command can run, or it is a pid from `$!` or a pid file
   under such a folder. As of 49a9ed4 every site found so far holds, so none needs a guard:
   - the EXIT traps of `loops-body.sh:9` and `loop-prelude.sh:15` (`pkill -f "$tmp/"`, `rm -rf "$tmp"`): `tmp` from
     the guarded line before each (`loops-body.sh:8`, `loop-prelude.sh:10`);
   - `loops-body.sh:466` (`pkill -P "$oldpid"`, `oldpid=$!` at line 459), `:467` (`pkill -f "$oldlock"`, `oldlock` at
     line 457 from `nb`) and `:572` (`pkill -f "$nb/scheduler/api.py"`): `nb=$sc/nb` and `sc=$tmp/<scenario>` in
     `setup` (lines 41-42);
   - `loop-s07.sh:157` (`pkill -f "$q/"`): `q=$tmp/q-<tag>` (line 26);
   - `loops-pidns.test.sh:18`: `tmp` from line 15;
   - `loop-p03.test.sh:108` and `:110`: `$tmp/nb-p3/…`, `tmp` from `loop-prelude.sh:10`;
   - `loop-d02.test.sh:117` (`pkill -P "$sp"; kill "$sp"`): `sp=$!` (line 109);
   - `site.test.sh:27`: `$tmp/bin/run-session.sh`, `tmp` from line 23;
   - `report-w05.sh:49` (`kill $wpid; rm -rf "$tmp"`): `wpid=$!`, `tmp` from the guarded line of the file that sources it;
   - `move-runtime.test.sh:10-13`: line 8 runs `cd "$root"` (the checkout), line 12's EXIT trap runs `rm -rf "$tmp"`
     and line 13 runs `tmp=$(cd "$tmp" && pwd -P)`. With line 10 unguarded and `tmp` empty, `cd ""` succeeds as a
     no-op in dash and bash, so `tmp` becomes the checkout and the trap deletes it; once line 10 is guarded, `tmp` is a
     folder before line 13 and stays one;
   - the `kill -KILL -- "-$(cat "$f")"` sites (`loop-s01.sh:56`, `loop-g02.sh:151`, `loops-body.sh:533` with
     `kill -TERM`, and about 15 test files, `loop-s04.test.sh:164` among them): `f` is a pid file in a state folder
     under `$tmp`, written by a fake session, and an empty file gives `kill … -- -`, which `kill` rejects.

   The read is recorded in the PR. This spec allows no guard on a cleanup line: a command the read finds whose value
   can still be empty or `/` is asked of the owner in the session's `QUESTION.md`, by file and line, with the guard it
   proposes, and is changed only as the answer allows. A guard inside a trap string (`loops-body.sh:9`,
   `loop-prelude.sh:15`) would edit the same frozen line that D11 changes. *D12-AC-2.*
3. **The test.** `scheduler/scratch-guard.test.sh` as in Tests, and its line in the `Makefile`'s `TESTS`. Its own
   scratch folder is made with the guarded line. *D12-AC-1, D12-AC-3.*
4. **The RED run is contained.** The node's RED run of the new test, on its base, where `loops-body.sh` still runs
   `pkill -f "/"` and `move-runtime.test.sh` still takes the checkout for its scratch folder, runs inside the
   namespace only, with every mount but the scratch folder read-only. A sentinel that the recording shell starts
   outside the namespace must survive it, and the checkout must be unchanged by it. The PR records the run: the first
   case naming the unguarded lines, the second failing on the sentinel, the outer sentinel still running, and
   `git status --porcelain` and the checkout's file count before and after, the same. *D12-AC-4.*
5. **`AGENTS.md` says it.** A Traps bullet says that `mktemp -d` leaves its variable empty when it fails (`set -u`
   does not catch it), so a test makes its scratch folder with `<var>=$(mktemp -d) && [ -d "$<var>" ] || exit 1`
   before it sets a trap. It also says that a cleanup never runs `pkill -f`, `kill` or `rm -rf` with a pattern or path
   that can be empty or `/`, and that `scratch-guard.test.sh` checks the first rule. *D12-AC-5.*

## Gate
- **D12-AC-1** — Every line of a file in the `Makefile`'s `TESTS` or of `scheduler/testdata/lib/*.sh` that assigns `$(mktemp -d …)` to a variable has the form `<var>=$(mktemp -d …) && [ -d "$<var>" ] || exit 1`, and a fixture file with one unguarded line is reported by `file:line`. *Verify:* `scheduler/scratch-guard.test.sh`.
- **D12-AC-2** — The PR records the read of change 2: every `pkill`, `pgrep`, `killall`, `kill` and `rm -rf` in those files whose pattern, pid or path is built from a variable, each with the guarded line, `$!` or pid file its value comes from, at least the sites change 2 lists. No such command can run with an empty value or `/`; a command for which the read cannot show that is named in a question to the owner (file, line and the proposed guard) and is changed only as the owner's answer allows. *Verify:* the record in the PR, checked by the fresh reviewer against `grep -nE '\b(pkill|pgrep|killall|kill|rm -rf)\b'` over the same files.
- **D12-AC-3** — In a user, pid and mount namespace of its own, whose driver is the namespace's pid 1 and has remounted every mount but the test's scratch folder read-only (the checkout, the real `HOME` and the real `TMPDIR` checked unwritable), every file of the `Makefile`'s `TESTS` except `scratch-guard.test.sh`, run in a session of its own with a `TMPDIR` below a regular file, ends within 5 s with a non-zero status and no `PASS:` line. A sentinel that the driver started (its command line contains `/`) is still running afterwards and has recorded no TERM, HUP or INT, as the outer test reads from the records after the namespace has ended. No test file runs outside the namespace; where the namespace is refused or that check fails, the case runs no test file and passes with a line naming the skip. *Verify:* `scheduler/scratch-guard.test.sh`, and a recorded local run in the PR in which the namespace case ran (not skipped).
- **D12-AC-4** — The PR records the RED run of `scheduler/scratch-guard.test.sh` on the node's base, inside the namespace with every mount but the scratch folder read-only. The mktemp case names the unguarded lines, the namespace case fails on the sentinel, a sentinel the recording shell started outside the namespace is still running after the run, and the checkout's `git status --porcelain` and file count are the same before and after the run. *Verify:* the record in the PR.
- **D12-AC-5** — The only existing lines changed under the frozen test paths are the `mktemp -d` lines of change 1, each gaining only `&& [ -d "$<var>" ] || exit 1`, or only `&& [ -d "$<var>" ]` inserted before a `|| exit 1` it already had, and any line the owner's answer to a question of change 2 allows, changed only as that answer says. `AGENTS.md`'s Traps has the bullet of change 5. Every case that passes on the base passes on the head. *Verify:* the fresh reviewer's check of `git diff <base>..HEAD`, recorded in the PR, and the PR's CI run.

## Risks
- The namespace case needs unprivileged user namespaces. CI's runner may refuse them (`image.yml` turns the AppArmor
  restriction off for its own job; `test.yml` does not), so there the case is skipped and only the mktemp case
  guards against a regression. The recorded local run is the evidence for D12-AC-3.
- In the namespace a file runs as a mapped root, which can change or delete anything the real user owns: on the base,
  `move-runtime.test.sh` (lines 8-13, change 2) would take the checkout for its scratch folder and its trap would delete
  it, and a path built from an empty variable such as `"$tmp"/*` reaches the user's home. The pid namespace keeps the
  signals in; only the read-only remount of every mount but the scratch folder keeps the files away from the checkout,
  the session's worktree and the home folder. So the case runs no file unless the driver finds those three unwritable, and the RED run records
  that the checkout is unchanged.
- The 5 s bound assumes a file does nothing slow before its `mktemp -d` line. As of 49a9ed4 every file only sets
  variables, clears its environment and sources helpers before that line (the latest is at line 66 of
  `pickup.test.sh`), so the bound leaves room on a loaded machine.
- D11 (its spec merged in PR #154, the node not yet built) changes how the EXIT trap of `loops-body.sh:9` stops
  fixtures, and M02 changes the waits in the same file. Whichever of D11 and D12 merges second keeps both changes:
  D12's guarded `mktemp -d` lines and D11's trap. M02 waits for this node, as the owner held it until issue #166 is
  fixed.
- M02's work adds kills of its own (its branch had a `pkill -f "$sc/"` in `m02_got`). The read of change 2 covers only
  the lines on this node's base, so M02 checks each kill it adds against the `AGENTS.md` bullet of change 5: its value
  comes from a guarded scratch folder and can be neither empty nor `/`.
- A node built at the same time that adds a test file with an unguarded `mktemp -d` line fails the mktemp case once
  both are on `main`. The node that merges second guards that line, as the `AGENTS.md` bullet says.
