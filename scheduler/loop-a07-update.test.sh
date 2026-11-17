#!/bin/bash
# A07-AC-4 (update): the scaffold's PR (branch exactly spec/adopt) conflicts with main: a session starts in pr/<N>/, rendered
# from scheduler/unattended-update.md with /noodlebot:adopt --update <N> (not a triage), in worktrees/<name>/pr-<N> on the PR's
# branch, which the adoption unit's removed worktree (adopt-scaffold) no longer holds.
# Assumed: the fake claude (loop-a07.sh) logs "pr.<N> run <n> <prompt> | <pwd> | <branch>" for --update/--feedback prompts;
# the update template's wording "started this session to update" (its first line) tells which template rendered the prompt.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-a07.sh"
. "$src/testdata/lib/loop-a07-pr.sh"

a07_unit_pr none scaffold 21 spec/adopt
touch "$A07/hold.pr.21"
a07_conflict a07 21
need "A07-AC-4: a conflicting spec/adopt PR starts an update session (--update 21)" 15 a07_any_start 21 update
a07_pr_session 21 spec/adopt update scaffold
chk "A07-AC-4: its prompt is the update template's (unattended-update.md)" grep -qF 'started this session to update' "$st/pr/21/unattended.md"
ticks 3
chk "A07-AC-4: one update session only while it runs" a07_runis pr.21 1
chk "A07-AC-4: the update started no second adoption session" a07_runis scaffold 1
rm -f "$A07/hold.pr.21"
a07_stop
loop_end
