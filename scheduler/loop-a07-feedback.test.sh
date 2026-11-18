#!/bin/bash
# A07-AC-4 (feedback): the owner comments on the area's PR (branch spec/adopt-one): a session starts in pr/<N>/, its
# unattended.md rendered from scheduler/unattended-feedback.md with /noodlebot:adopt --feedback <N> (not a triage), in
# worktrees/<name>/pr-<N> on the PR's branch, after the unit's worktree (adopt-one) was removed so the branch can be checked out.
# Assumed: the fake claude (loop-a07.sh) logs "pr.<N> run <n> <prompt> | <pwd> | <branch>" for --update/--feedback prompts;
# the feedback template's wording "to act on the owner's feedback" tells which template rendered the prompt; the loop's first
# feedback read records the open PRs (state/feedback exists), so the comment is added after it.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-a07.sh"
. "$src/testdata/lib/loop-a07-pr.sh"

a07_unit_pr two one 22 spec/adopt-one
touch "$A07/hold.pr.22"
need "A07-AC-4 setup: the loop made its first feedback read" 15 test -d "$st/feedback"
a07_comment a07 22 201 'please rename the wrap area'
need "A07-AC-4: the owner's comment on a spec/adopt-one PR starts a feedback session (--feedback 22)" 15 a07_any_start 22 feedback
a07_pr_session 22 spec/adopt-one feedback one
chk "A07-AC-4: its prompt is the feedback template's (unattended-feedback.md)" grep -qF "to act on the owner's feedback" "$st/pr/22/unattended.md"
chk "A07-AC-4: the comment is handed over in pr/22/FEEDBACK.md" grep -qF 'please rename the wrap area' "$st/pr/22/FEEDBACK.md"
ticks 3
chk "A07-AC-4: one feedback session only while it runs" a07_runis pr.22 1
chk "A07-AC-4: the feedback started no second session of the unit" a07_runis one 1
chk "A07-AC-4: the next area waits for the PR's merge" a07_runis two 0
rm -f "$A07/hold.pr.22"
a07_stop
loop_end
