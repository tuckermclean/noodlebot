# D12 — scratch-guard

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D03 | M02 | M |

**Owns:** `scheduler/scratch-guard.test.sh` (new) and its line in the `Makefile`'s `TESTS`; a bullet of `AGENTS.md`'s
Traps on a test's scratch folder and its cleanup; the read of the cleanup commands (change 2), in the node's PR. As
D03 (its change 7) did, this spec allows, for this node only, changing exactly these existing lines of the frozen test
paths (the `*.test.sh` files and `scheduler/testdata/`): each line that assigns `$(mktemp -d …)` to a variable, which
gains `&& [ -d "$<var>" ] || exit 1` and nothing else (change 1); and the cleanup commands change 2's read finds
unguarded, each of which gains a guard in front of it while the command itself stays as it is. No check, compared
value or pattern, wait or start is changed.
**Resolves:** #166

## Purpose
On 2026-11-17 a run of `scheduler/loops-status.test.sh` with a `TMPDIR` that did not exist stopped every process of
the user on the scheduler's machine: both loops, the API, three sessions, the tmux servers and the user's systemd
manager. `scheduler/testdata/lib/loops-body.sh:8` (`tmp=$(mktemp -d)`) failed and left `tmp` empty, which `set -u`
does not catch, and the EXIT trap on line 9 ran `pkill -f "$tmp/"`, that is `pkill -f "/"`. After this node a test
file whose scratch folder cannot be made stops at once, before it sets a trap or starts a process. No cleanup in a test
file or shared helper runs `pkill`, `kill` or `rm -rf` with a pattern or path that can be empty or `/`. A test runs
every test file with a `TMPDIR` that does not exist and shows that a sentinel outside each file's process group gets
no signal. Keeping the loops alive when something signals the user's systemd manager (a systemd user service of their
own with `KillMode` settings, or lingering) is not part of this node; issue #166 leaves that to the owner.

## Tests
- `scheduler/scratch-guard.test.sh` (new, in the `Makefile`'s `TESTS`), with two cases:
  - **The mktemp lines.** It reads every file of the `Makefile`'s `TESTS` and every `scheduler/testdata/lib/*.sh`. Each
    line that assigns `$(mktemp -d …)` to a variable must have the form
    `<var>=$(mktemp -d …) && [ -d "$<var>" ] || exit 1`, and the case names each line that does not (`file:line`).
    It also shows that a fixture file in its own scratch folder, holding one unguarded line, is caught. This case runs
    everywhere.
  - **The run with a missing TMPDIR.** Inside a user and pid namespace of its own (started and probed as
    `scheduler/loops-pidns.test.sh:253` does), a driver starts a sentinel first. The sentinel is a shell whose command
    line contains `/`; it traps TERM, HUP and INT and records each one it gets. The driver then runs every file of the
    `Makefile`'s `TESTS` except this one, a few at a time, each in a session of its own (`setsid`), with `TMPDIR` set
    on its command to a path under the test's scratch folder that does not exist. Each file must end within 5 s with
    a non-zero status and print no `PASS:` line. After the last file the sentinel must still be running and have
    recorded no signal. The case never runs a test file outside the namespace. Where the machine refuses the
    namespace, it passes with a line naming the skip, as D06-AC-11 does, and the first case still runs.
  - The file stays under `TEST_FILE_BUDGET`.
- The existing test files and shared helpers (changed only as **Owns** allows): every case that passes on the node's
  base still passes.

## Changes
1. **Every scratch folder is checked where it is made.** Each line of a `*.test.sh` file in the `Makefile`'s `TESTS`
   or of a shared helper under `scheduler/testdata/lib/` that assigns `$(mktemp -d …)` to a variable gains
   `&& [ -d "$<var>" ] || exit 1`, so the file stops before it sets a trap or starts a process. As of `main` at
   49a9ed4 that is one line in each of the files that make their own folder (`scheduler/harness.test.sh:11` and
   `scheduler/loops-pidns.test.sh:15` have `|| exit 1` already and get the `[ -d ]` check too), plus
   `loop-prelude.sh:10`, `loops-body.sh:8` and `guard-body.sh:9`, which the loop, loops and guard test files
   source. `guard-body.sh:373` holds `mktemp -d` inside a quoted command that a case checks and is not such a line.
   *D12-AC-1.*
2. **No cleanup with an empty or `/` pattern.** The read lists every `pkill`, `pgrep`, `killall`, `kill` and `rm -rf`
   in the files of change 1 whose pattern, pid or path is built from a variable. For each one it says why the value can
   be neither empty nor `/`: the variable is set by a line guarded under change 1, or built from one by appending,
   before the command can run. Where that does not hold, the command gets a guard in front that skips it unless the
   value is a non-empty path under the scratch base (for example
   `case $v in /tmp/?*|"${TMPDIR:-/tmp}"/?*) ;; *) exit 1 ;; esac`) or matches a mark unique to the test. Known so far,
   as of 49a9ed4: the EXIT traps of `loops-body.sh:9` and `loop-prelude.sh:15` (`pkill -f "$tmp/"`, `rm -rf "$tmp"`);
   `loops-body.sh:467` (`pkill -f "$oldlock"`) and `:572` (`pkill -f "$nb/scheduler/api.py"`);
   `loop-s07.sh:157` (`pkill -f "$q/"`); `loops-pidns.test.sh:18`; `loop-p03.test.sh:108` and `:110`;
   `site.test.sh:27`; `report-w05.sh:49`. The read is recorded in the PR. *D12-AC-2.*
3. **The test.** `scheduler/scratch-guard.test.sh` as in Tests, and its line in the `Makefile`'s `TESTS`. Its own
   scratch folder is made with the guarded line. *D12-AC-1, D12-AC-3.*
4. **The RED run is contained.** The node's RED run of the new test, on its base, where `loops-body.sh` still runs
   `pkill -f "/"`, runs inside the namespace only. A sentinel that the recording shell starts outside the namespace
   must survive it. The PR records the run: the first case naming the unguarded lines, the second failing on the
   sentinel, and the outer sentinel still running. *D12-AC-4.*
5. **`AGENTS.md` says it.** A Traps bullet says that `mktemp -d` leaves its variable empty when it fails (`set -u`
   does not catch it), so a test makes its scratch folder with `<var>=$(mktemp -d) && [ -d "$<var>" ] || exit 1`
   before it sets a trap. It also says that a cleanup never runs `pkill -f`, `kill` or `rm -rf` with a pattern or path
   that can be empty or `/`, and that `scratch-guard.test.sh` checks the first rule. *D12-AC-5.*

## Gate
- **D12-AC-1** — Every line of a file in the `Makefile`'s `TESTS` or of `scheduler/testdata/lib/*.sh` that assigns `$(mktemp -d …)` to a variable has the form `<var>=$(mktemp -d …) && [ -d "$<var>" ] || exit 1`, and a fixture file with one unguarded line is reported by `file:line`. *Verify:* `scheduler/scratch-guard.test.sh`.
- **D12-AC-2** — The PR records the read of change 2: every `pkill`, `pgrep`, `killall`, `kill` and `rm -rf` in those files whose pattern, pid or path is built from a variable, each with the guarded line its value comes from or the guard added in front of it, at least the sites change 2 lists. No such command can run with an empty value or `/`. *Verify:* the record in the PR, checked by the fresh reviewer against `grep -nE '\b(pkill|pgrep|killall|kill|rm -rf)\b'` over the same files.
- **D12-AC-3** — In a user and pid namespace of its own, every file of the `Makefile`'s `TESTS` except `scratch-guard.test.sh`, run in a session of its own with a `TMPDIR` that does not exist, ends within 5 s with a non-zero status and no `PASS:` line. A sentinel that the files' parent started (its command line contains `/`) is still running afterwards and has recorded no TERM, HUP or INT. No test file runs outside the namespace; where the namespace is refused, the case passes with a line naming the skip. *Verify:* `scheduler/scratch-guard.test.sh`, and a recorded local run in the PR in which the namespace case ran (not skipped).
- **D12-AC-4** — The PR records the RED run of `scheduler/scratch-guard.test.sh` on the node's base, inside the namespace. The mktemp case names the unguarded lines, the namespace case fails on the sentinel, and a sentinel the recording shell started outside the namespace is still running after the run. *Verify:* the record in the PR.
- **D12-AC-5** — The only existing lines changed under the frozen test paths are the `mktemp -d` lines of change 1, each gaining only `&& [ -d "$<var>" ] || exit 1`, and the guards change 2 adds in front of cleanup commands, each command kept as it was. `AGENTS.md`'s Traps has the bullet of change 5. Every case that passes on the base passes on the head. *Verify:* the fresh reviewer's check of `git diff <base>..HEAD`, recorded in the PR, and the PR's CI run.

## Risks
- The namespace case needs unprivileged user namespaces. CI's runner may refuse them (`image.yml` turns the AppArmor
  restriction off for its own job; `test.yml` does not), so there the case is skipped and only the mktemp case
  guards against a regression. The recorded local run is the evidence for D12-AC-3.
- In the namespace a file runs as a mapped root. That changes nothing once it stops at its `mktemp -d` line, but on
  the base a file that goes on with an empty `tmp` sees paths like `/bin` as root of the namespace. It still cannot
  write files the real root owns, and the pid namespace keeps every signal inside.
- The 5 s bound assumes a file does nothing slow before its `mktemp -d` line. As of 49a9ed4 every file only sets
  variables, clears its environment and sources helpers before that line (the latest is at line 66 of
  `pickup.test.sh`), so the bound leaves room on a loaded machine.
- D11 (spec PR #154) changes how the EXIT trap of `loops-body.sh:9` stops fixtures, and M02 changes the waits in the
  same file. Whichever merges after this node keeps the guards of changes 1 and 2. M02 waits for this node, as the
  owner held it until issue #166 is fixed.
- A node built at the same time that adds a test file with an unguarded `mktemp -d` line fails the mktemp case once
  both are on `main`. The node that merges second guards that line, as the `AGENTS.md` bullet says.
