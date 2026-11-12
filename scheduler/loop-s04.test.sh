#!/bin/bash
# S04: a node that stopped before its PR resumes (E01..E07). Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s04.sh"

# ---- S04: a node that stopped before its PR resumes: the stop is recorded, leftover changes are saved as a patch ----
# Nodes E01..E07 (no deps) in their own remote, data dir and loop (o/s4, 1 s tick). main carries base.txt, d.txt and
# a .gitignore (out/, *.ign). The fake claude snapshots, at the start of every run, the rendered unattended.md,
# the stopped file, the leftover listing, git status --porcelain, HEAD, the branch, the brief and base.txt into
# $S04/rec/<ID>.<run>/ (done is written last), then per node and run:
#   E01 run 1: 3 commits, out/node/E01/brief.md, a modified tracked file, a staged new file, a deleted tracked
#              file, an untracked file, ignored files; usage-limit events, exit 1. run 2: QUESTION.md.
#   E02 run 1: 1 commit, brief, a modified file, then kills itself with SIGTERM (rc 143). run 2: QUESTION.md.
#   E03 run 1: 2 commits, brief, clean worktree, exit 3. run 2: QUESTION.md.
#   E04 (fresh) run 1: QUESTION.md.
#   E05 run 1: only out/node/E05/brief.md (no commit, nothing to save), exit 4. run 2: QUESTION.md.
#   E06 run 1: 1 commit, brief, a modified file, kills run-session.sh (no session.rc). run 2: QUESTION.md.
#   E07 run 1: 1 commit, brief, a modified file, makes state/node/E07/leftover a plain file (no patch can be
#              written there), exit 1.
S04=$tmp/s04; export S04
mkdir -p "$S04/rec" "$tmp/bin7" "$tmp/nb7/scheduler" "$tmp/nb7/plugin" "$tmp/data7/repos"
data7=$(cd "$tmp/data7" && pwd -P)
st4=$data7/state/s4 wt7=$data7/worktrees/s4
S04_STATE=$st4; export S04_STATE
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/nb7/scheduler/" ;; esac; done
[ -f "$src/harness.py" ] && { mkdir -p "$tmp/nb7/scheduler/harnesses"; cp "$src/harness.py" "$tmp/nb7/scheduler/"; cp "$src"/harnesses/*.py "$tmp/nb7/scheduler/harnesses/"; }
git init -q -b main "$tmp/work7"; mkdir -p "$tmp/work7/docs"
{ echo 'nodes:'; for i in 1 2 3 4 5 6 7; do echo "  - {id: E0$i, name: n$i, deps: []}"; done; } >"$tmp/work7/docs/graph.yaml"
printf 'base\n' >"$tmp/work7/base.txt"; printf 'doomed\n' >"$tmp/work7/d.txt"; printf 'out/\n*.ign\n' >"$tmp/work7/.gitignore"
git -C "$tmp/work7" add -A && git -C "$tmp/work7" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work7" "$tmp/remote7.git"
git clone -q "$tmp/remote7.git" "$data7/repos/s4"
cat >"$tmp/bin7/gh" <<'EOF'
#!/bin/sh
case " $* " in
*"/issues?labels=noodlebot"*) echo '[]' ;;
esac
exit 0
EOF
cat >"$tmp/bin7/claude" <<'EOF'
#!/bin/sh
id=${2##* }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
n=$(( $(cat "$S04/runs.$id" 2>/dev/null || echo 0) + 1 )); echo $n >"$S04/runs.$id"
r=$S04/rec/$id.$n; mkdir -p "$r"
cp "$S04_STATE/node/$id/unattended.md" "$r/prompt" 2>/dev/null
cp "$S04_STATE/node/$id/stopped" "$r/stopped" 2>/dev/null
ls "$S04_STATE/node/$id/leftover" >"$r/leftover" 2>/dev/null
git status --porcelain >"$r/status" 2>&1
git rev-parse HEAD >"$r/head" 2>&1; git rev-parse --abbrev-ref HEAD >"$r/branch" 2>&1
cp "out/node/$id/brief.md" "$r/brief" 2>/dev/null
cp "out/node/$id/log.txt" "$r/log" 2>/dev/null
cp cache.ign "$r/ign" 2>/dev/null
cat base.txt >"$r/base" 2>/dev/null
touch "$r/done"
commits() { i=0; while [ $i -lt $1 ]; do i=$((i + 1)); echo "$id $i" >"c$i.txt"; git add "c$i.txt"; git commit -qm "$id commit $i"; done; }
brief() { mkdir -p "out/node/$id"; echo "brief of $id v1" >"out/node/$id/brief.md"; echo "log of $id" >"out/node/$id/log.txt"; cp "out/node/$id/brief.md" "$S04/brief1.$id"; git rev-parse HEAD >"$S04/head1.$id"; }
limit() {
	echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1,"status":"rejected"}}}}'
	echo '{"type":"result","subtype":"error_during_execution","result":"You have hit your usage limit"}'
}
q() { echo "Q1: x" >"$S04_STATE/node/$id/QUESTION.md"; }
case $id.$n in
E01.1) commits 3; brief; echo more >>base.txt; rm d.txt; echo staged >s.txt; git add s.txt; echo untracked >u.txt; echo cache >cache.ign; limit; exit 1 ;;
E02.1) commits 1; brief; echo more >>base.txt; git rev-parse HEAD >"$S04/head1.$id"; kill -TERM $$; sleep 5 ;;
E03.1) commits 2; brief; exit 3 ;;
E04.1) q ;;
E05.1) brief; exit 4 ;;
E06.1) commits 1; brief; echo more >>base.txt; kill -KILL $PPID; exit 0 ;;
E07.1) commits 1; brief; echo more >>base.txt; echo not-a-dir >"$S04_STATE/node/$id/leftover"; exit 1 ;;
*.2) q ;;
esac
exit 0
EOF
chmod +x "$tmp/bin7/gh" "$tmp/bin7/claude"
s4f() { cat "$S04/rec/$1/$2" 2>/dev/null; }
s4have() { [ -e "$S04/rec/$1/done" ]; }
s4runs() { cat "$S04/runs.$1" 2>/dev/null || echo 0; }
s4log() { cat "$st4/status.log" 2>/dev/null; }
s4stopped_is() { # <run> <reason regex>: the stopped file seen at that run's start is one line: UTC time and the reason
	local f="$S04/rec/$1/stopped"
	[ -f "$f" ] && [ "$(wc -l <"$f")" = 1 ] && grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z.*$2\$" "$f"
}
s4resume() { # <run>: the rendered prompt carries the resume section
	local f="$S04/rec/$1/prompt"
	grep -qF 'git log origin/main..HEAD' "$f" 2>/dev/null && grep -qF 'gh run list --branch' "$f"
}
s4patch() { ls "$st4/node/$1/leftover"/*.patch 2>/dev/null | head -1; }
S04_LOOP_OUT=$tmp/s04-loop.out
NOODLEBOT_DATA=$data7 PATH=$tmp/bin7:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$tmp/nb7/scheduler/loop.sh" o/s4 >>"$S04_LOOP_OUT" 2>&1 &
pids+=("$!"); lp7=$!
s4wait 25 sh -c "[ -e '$S04/rec/E01.2/done' ] && [ -e '$S04/rec/E02.2/done' ] && [ -e '$S04/rec/E03.2/done' ] && [ -e '$S04/rec/E05.2/done' ] && [ -e '$S04/rec/E06.2/done' ] && [ -e '$S04/rec/E04.1/done' ]"
s4wait 5 sh -c "[ \"\$(cat '$S04/runs.E07' 2>/dev/null)\" = 1 ]"
# the sessions of the second runs have ended with their QUESTION.md and the loop has taken the stopped files away
s4_ended() { local i; for i in E01 E02 E03 E05 E06; do [ -e "$st4/node/$i/QUESTION.md" ] && [ ! -e "$st4/node/$i/stopped" ] || return 1; done; }
wait_until 10 s4_ended
wait_ticks 3 "$st4"   # E07's "stays at one run" and the patch counts are about ticks that have passed
w1=$wt7/E01
p1=$(s4patch E01); pb1=$(basename "$p1" 2>/dev/null)
# AC-1: the stopped file
s4ok "S04-AC-1: a limit exit: at the next start the stopped file is one line, UTC time and 'usage limit'" s4stopped_is E01.2 'usage limit'
s4ok "S04-AC-1: a session killed by SIGTERM: 'stopped (signal 15)'" s4stopped_is E02.2 'stopped \(signal 15\)'
s4ok "S04-AC-1: an exit with code 3: 'rc 3'" s4stopped_is E03.2 'rc 3'
s4ok "S04-AC-1: an exit with code 4 (no commit): 'rc 4'" s4stopped_is E05.2 'rc 4'
s4ok "S04-AC-1: run-session.sh killed, no session.rc: 'stopped (no exit code)'" s4stopped_is E06.2 'stopped \(no exit code\)'
s4ok "S04-AC-1: a fresh node has no stopped file" test ! -e "$S04/rec/E04.1/stopped"
s4ok "S04-AC-1: the stopped file is gone after the later session ends with QUESTION.md (E01)" sh -c "[ -s '$S04/rec/E01.2/stopped' ] && [ -e '$st4/node/E01/QUESTION.md' ] && [ ! -e '$st4/node/E01/stopped' ]"
s4ok "S04-AC-1: (E02, E03, E05, E06 too)" sh -c "for i in E02 E03 E05 E06; do [ -s '$S04/rec/'\$i'.2/stopped' ] && [ -e '$st4/node/'\$i'/QUESTION.md' ] && [ ! -e '$st4/node/'\$i'/stopped' ] || exit 1; done"
s4ok "S04-AC-1: a node whose first session ends in QUESTION.md has no stopped file (E04)" test ! -e "$st4/node/E04/stopped"
# AC-2: the rendered prompt
s4ok "S04-AC-2: a restarted node with commits gets the resume section (git log origin/main..HEAD, gh run list --branch)" s4resume E01.2
s4ok "S04-AC-2: it gives the reason from stopped: usage limit" grep -qF 'usage limit' "$S04/rec/E01.2/prompt"
s4ok "S04-AC-2: it gives the number of commits past origin/main (3)" grep -Eq '(^|[^0-9.])3 commits?|commits?[^0-9]*[:=(] ?3([^0-9]|$)' "$S04/rec/E01.2/prompt"
s4ok "S04-AC-2: (E02) the reason 'stopped (signal 15)' and 1 commit" sh -c "grep -qF 'stopped (signal 15)' '$S04/rec/E02.2/prompt' && grep -Eq '(^|[^0-9.])1 commit|commits?[^0-9]*[:=(] ?1([^0-9]|\$)' '$S04/rec/E02.2/prompt'"
s4ok "S04-AC-2: (E03) the reason 'rc 3', 2 commits, resume section" sh -c "grep -qF 'rc 3' '$S04/rec/E03.2/prompt' && grep -Eq '(^|[^0-9.])2 commits|commits?[^0-9]*[:=(] ?2([^0-9]|\$)' '$S04/rec/E03.2/prompt'"
s4ok "S04-AC-2: (E06) the reason 'stopped (no exit code)'" grep -qF 'stopped (no exit code)' "$S04/rec/E06.2/prompt"
s4ok "S04-AC-2: the leftover patch written for this start is named in the prompt" sh -c "[ -n '$pb1' ] && grep -qF 'leftover/$pb1' '$S04/rec/E01.2/prompt'"
s4ok "S04-AC-2: it tells the run to examine the patch, never commit it unexamined, list it under Deviations" sh -c "grep -qi 'examine' '$S04/rec/E01.2/prompt' && grep -qi 'unexamined\|never commit\|not commit' '$S04/rec/E01.2/prompt' && grep -q 'Deviations' '$S04/rec/E01.2/prompt'"
s4ok "S04-AC-2: it tells the run to keep the existing brief and not redo committed and reviewed slices" sh -c "grep -qi 'keep.*brief\|existing brief' '$S04/rec/E01.2/prompt' && grep -qi 'not redo\|never redo\|do not redo' '$S04/rec/E01.2/prompt'"
s4ok "S04-AC-2: a restarted node with a clean worktree names no leftover patch (E03)" sh -c "! grep -qE 'leftover/|\.patch' '$S04/rec/E03.2/prompt'"
s4ok "S04-AC-2: a node with out/node/<ID>/ but no commit gets the resume section (E05) with 'rc 4'" sh -c "$(declare -f s4resume); S04='$S04'; s4resume E05.2 && grep -qF 'rc 4' '$S04/rec/E05.2/prompt'"
s4ok "S04-AC-2: a fresh node gets no resume section (E04)" sh -c "s4=$S04/rec/E04.1/prompt; [ -s \$s4 ] && ! grep -qF 'git log origin/main..HEAD' \$s4 && ! grep -qF 'gh run list' \$s4"
s4ok "S04-AC-2: the first session of a node with commits made in no earlier run gets no resume section (E01 run 1)" sh -c "s4=$S04/rec/E01.1/prompt; [ -s \$s4 ] && ! grep -qF 'git log origin/main..HEAD' \$s4"
# AC-3: leftover patch, reset
s4ok "S04-AC-3: the dirty worktree's changes are in leftover/<UTC timestamp>.patch" sh -c "[ -n '$p1' ] && [ -s '$p1' ] && echo '$pb1' | grep -Eq '^[0-9]{8}T[0-9]{6}Z\.patch\$|^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.-]*Z.*\.patch\$|^[0-9TZ:-]+\.patch\$'"
s4ok "S04-AC-3: exactly one patch for the one start" test "$(ls "$st4/node/E01/leftover" 2>/dev/null | wc -l)" = 1
s4rt() {
	local p=$1 head
	[ -f "$p" ] || return 1
	head=$(cat "$S04/head1.E01") || return 1
	rm -rf "$tmp/rt7"; git clone -q "$data7/repos/s4" "$tmp/rt7" 2>/dev/null && git -C "$tmp/rt7" checkout -q "$head" 2>/dev/null || return 1
	[ -z "$(git -C "$tmp/rt7" status --porcelain)" ] || return 1
	git -C "$tmp/rt7" apply "$p" || return 1
	grep -qx more "$tmp/rt7/base.txt" && [ "$(grep -c . "$tmp/rt7/base.txt")" = 2 ] && [ -f "$tmp/rt7/s.txt" ] && grep -qx staged "$tmp/rt7/s.txt" &&
		[ -f "$tmp/rt7/u.txt" ] && grep -qx untracked "$tmp/rt7/u.txt" && [ ! -e "$tmp/rt7/d.txt" ] && [ ! -e "$tmp/rt7/cache.ign" ]
}
s4ok "S04-AC-3: git apply on the same commit restores modified, staged, deleted and untracked files, not the ignored one" s4rt "$p1"
s4ok "S04-AC-3: when the session starts, git status --porcelain in the worktree is empty" sh -c "[ -f '$S04/rec/E01.2/status' ] && [ ! -s '$S04/rec/E01.2/status' ]"
s4ok "S04-AC-3: HEAD is unchanged (E01)" sh -c "[ -s '$S04/head1.E01' ] && [ \"\$(cat '$S04/rec/E01.2/head')\" = \"\$(cat '$S04/head1.E01')\" ]"
s4ok "S04-AC-3: the branch is unchanged, with its 3 commits past origin/main" sh -c "[ \"\$(cat '$S04/rec/E01.2/branch')\" = node/E01-n1 ] && [ \"\$(git -C '$w1' rev-list --count origin/main..HEAD)\" = 3 ]"
s4ok "S04-AC-3: the tracked file is back to its committed content, the untracked file is gone" sh -c "[ \"\$(cat '$S04/rec/E01.2/base')\" = base ] && [ ! -e '$w1/u.txt' ] && [ ! -e '$w1/s.txt' ] && [ -f '$w1/d.txt' ]"
s4ok "S04-AC-3: ignored files are untouched (out/node/E01/log.txt and cache.ign)" sh -c "[ \"\$(cat '$S04/rec/E01.2/log')\" = 'log of E01' ] && [ \"\$(cat '$S04/rec/E01.2/ign')\" = cache ]"
s4ok "S04-AC-3: one status-log event names the node and the patch" sh -c "[ -n '$pb1' ] && [ \"\$(grep 'E01' '$st4/status.log' | grep -cF '$pb1')\" = 1 ]"
s4ok "S04-AC-3: a clean worktree gets no patch (E03: no leftover directory content)" sh -c "[ -z \"\$(ls '$st4/node/E03/leftover' 2>/dev/null)\" ] && [ ! -s '$S04/rec/E03.2/leftover' ]"
s4ok "S04-AC-3: (E03) its status is empty and its commits stay" sh -c "[ ! -s '$S04/rec/E03.2/status' ] && [ \"\$(cat '$S04/rec/E03.2/head')\" = \"\$(cat '$S04/head1.E03')\" ]"
s4ok "S04-AC-3: a fresh node gets no patch (E04)" sh -c "[ -z \"\$(ls '$st4/node/E04/leftover' 2>/dev/null)\" ]"
s4ok "S04-AC-3: a patch that cannot be written: the node is not started that tick (E07 stays at one run)" test "$(s4runs E07)" = 1
s4ok "S04-AC-3: (E07) the worktree is unchanged: still modified, HEAD kept" sh -c "grep -qx more '$wt7/E07/base.txt' && [ \"\$(git -C '$wt7/E07' rev-parse HEAD)\" = \"\$(cat '$S04/head1.E07')\" ] && git -C '$wt7/E07' status --porcelain | grep -q 'base.txt'"
s4ok "S04-AC-3: (E07) the failure is logged" sh -c "grep 'E07' '$st4/status.log' | grep -iE 'leftover|patch' | grep -iqE 'fail|cannot|could not|not written|unable'"
s4ok "S04-AC-3: (E07) its brief and ignored files are untouched" sh -c "[ \"\$(cat '$wt7/E07/out/node/E07/brief.md')\" = \"\$(cat '$S04/brief1.E07')\" ]"
# AC-4: end to end
s4ok "S04-AC-4: the limit-stopped node starts again with its start not counted (both runs are start 1 of 2)" sh -c "[ \"\$(grep -c 'started E01 .*start 1 of 2' '$st4/status.log')\" = 2 ] && [ \"\$(cat '$S04/runs.E01')\" = 2 ]"
s4ok "S04-AC-4: its resume prompt names usage limit and carries the resume section" sh -c "$(declare -f s4resume); S04='$S04'; s4resume E01.2 && grep -qF 'usage limit' '$S04/rec/E01.2/prompt'"
s4ok "S04-AC-4: at that start its earlier commits are on the branch, HEAD unchanged" sh -c "[ \"\$(cat '$S04/rec/E01.2/head')\" = \"\$(cat '$S04/head1.E01')\" ] && git -C '$w1' log --format=%s origin/main..HEAD | grep -qx 'E01 commit 1'"
s4ok "S04-AC-4: its brief is unchanged" sh -c "[ -s '$S04/brief1.E01' ] && cmp -s '$S04/rec/E01.2/brief' '$S04/brief1.E01'"
s4ok "S04-AC-4: the edit is in the leftover patch, not in the worktree" sh -c "[ -n '$p1' ] && grep -q '^+more' '$p1' && [ \"\$(cat '$S04/rec/E01.2/base')\" = base ]"
s4ok "S04-AC-4: the signal-killed node restarts the same way, with a reason beginning 'stopped'" sh -c "$(declare -f s4resume); S04='$S04'; s4resume E02.2 && grep -q 'stopped' '$S04/rec/E02.2/prompt' && [ \"\$(cat '$S04/runs.E02')\" = 2 ]"
p2=$(s4patch E02)
s4ok "S04-AC-4: (signal) its edit is in the leftover patch, not in the worktree, HEAD and brief unchanged" sh -c "[ -n '$p2' ] && grep -q '^+more' '$p2' && [ \"\$(cat '$S04/rec/E02.2/base')\" = base ] && [ \"\$(cat '$S04/rec/E02.2/head')\" = \"\$(cat '$S04/head1.E02')\" ] && cmp -s '$S04/rec/E02.2/brief' '$S04/brief1.E02'"
kill "$lp7"; wait "$lp7" 2>/dev/null
for f in "$st4"/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done

loop_end
