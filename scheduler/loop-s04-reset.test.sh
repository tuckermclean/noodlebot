#!/bin/bash
# S04 (slice 5). Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s04.sh"

# ---- S04 (slice 5): a reset that fails partway names its patch, a patch not yet shown is named later; a rebase patch names its base ----
# Nodes K01, K02 (no deps) in their own remote, data dir and loop (o/s45). main carries f.txt and .gitignore with out/;
# branch "other" edits f.txt. The fake claude snapshots the rendered unattended.md of every start into $S45/rec/<ID>.<run>/.
#   K01 run 1: a commit, brief, an edit of f.txt, an untracked sub/u.txt in a directory without write permission
#              (git clean cannot remove it); usage limit, exit 1. run 2: another edit of f.txt, usage limit. run 3: QUESTION.md.
#   K02 run 1: a commit on its branch, a rebase onto origin/other that stops on a conflict, exit 1. run 2: QUESTION.md.
S45=$tmp/s45; export S45
mkdir -p "$S45/rec" "$tmp/bin45" "$tmp/nb45/scheduler" "$tmp/nb45/plugin" "$tmp/data45/repos"
data45=$(cd "$tmp/data45" && pwd -P)
st45=$data45/state/s45 wt45=$data45/worktrees/s45
S45_STATE=$st45; export S45_STATE
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/nb45/scheduler/" ;; esac; done
[ -f "$src/harness.py" ] && { mkdir -p "$tmp/nb45/scheduler/harnesses"; cp "$src/harness.py" "$tmp/nb45/scheduler/"; cp "$src"/harnesses/*.py "$tmp/nb45/scheduler/harnesses/"; }
git init -q -b main "$tmp/work45"; mkdir -p "$tmp/work45/docs"
{ echo 'nodes:'; for i in 1 2; do echo "  - {id: K0$i, name: n$i, deps: []}"; done; } >"$tmp/work45/docs/graph.yaml"
printf 'base\n' >"$tmp/work45/f.txt"; printf 'out/\n' >"$tmp/work45/.gitignore"
git -C "$tmp/work45" add -A && git -C "$tmp/work45" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$tmp/work45" checkout -q -b other && echo theirs >"$tmp/work45/f.txt" && git -C "$tmp/work45" -c user.name=t -c user.email=t@t commit -qam theirs
git -C "$tmp/work45" checkout -q main
git clone -q --bare "$tmp/work45" "$tmp/remote45.git"
git clone -q "$tmp/remote45.git" "$data45/repos/s45"
cat >"$tmp/bin45/gh" <<'EOF'
#!/bin/sh
case " $* " in
*"/issues?labels=noodlebot"*) echo '[]' ;;
esac
exit 0
EOF
cat >"$tmp/bin45/claude" <<'EOF'
#!/bin/sh
id=${2##* }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
n=$(( $(cat "$S45/runs.$id" 2>/dev/null || echo 0) + 1 )); echo $n >"$S45/runs.$id"
r=$S45/rec/$id.$n; mkdir -p "$r"
cp "$S45_STATE/node/$id/unattended.md" "$r/prompt" 2>/dev/null
git status --porcelain >"$r/status" 2>&1
git rev-parse HEAD >"$r/head" 2>&1
touch "$r/done"
limit() {
	echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1,"status":"rejected"}}}}'
	echo '{"type":"result","subtype":"error_during_execution","result":"You have hit your usage limit"}'
}
case $id.$n in
K01.1) echo c >c.txt; git add c.txt; git commit -qm "K01 commit"; mkdir -p "out/node/$id"; echo "brief" >"out/node/$id/brief.md"
	echo edit1 >>f.txt; mkdir sub; echo undeletable >sub/u.txt; chmod a-w sub; limit; exit 1 ;;
K01.2) echo edit2 >>f.txt; limit; exit 1 ;;
K02.1) echo mine >f.txt; git commit -qam mine; git rev-parse HEAD >"$S45/tip.$id"; git fetch -q origin; git rebase origin/other >/dev/null 2>&1
	git rev-parse HEAD >"$S45/dhead.$id"; exit 1 ;;
*) echo "Q1: x" >"$S45_STATE/node/$id/QUESTION.md" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin45/gh" "$tmp/bin45/claude"
s45ps() { ls "$st45/node/$1/leftover"/*.patch 2>/dev/null | sed 's#.*/##'; }
s45p1() { local p; for p in $(s45ps K01); do grep -q '^+edit1' "$st45/node/K01/leftover/$p" && { echo "$p"; return; }; done; }
s45all() { local p; [ -s "$1" ] && [ -s "$2" ] || return 1; while read -r p; do grep -qF "$p" "$1" || return 1; done <"$2"; }
s45none() { local p; [ -s "$1" ] && [ -s "$2" ] || return 1; while read -r p; do ! grep -qF "$p" "$1" || return 1; done <"$2"; }
if [ "$(id -u)" = 0 ]; then
	fail "S04-AC-3: (partial reset, Q1) cannot run as root: a directory without write permission does not stop git clean"
else
	NOODLEBOT_DATA=$data45 PATH=$tmp/bin45:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		bash "$tmp/nb45/scheduler/loop.sh" o/s45 >>"$tmp/s45-loop.out" 2>&1 &
	pids+=("$!"); lp45=$!
	s4wait 15 sh -c "[ -e '$S45/rec/K01.1/done' ] && grep K01 '$st45/status.log' | grep -qiE 'fail|cannot'"
	s4wait 8 sh -c "[ \$(ls '$st45'/node/K01/leftover/*.patch 2>/dev/null | wc -l) -ge 2 ]"
	wait_ticks 1 "$st45"   # the node is held and has not run again
	p1=$(s45p1); allp=$(s45ps K01)
	grep K01 "$st45/status.log" | grep -iE 'fail|cannot' | head -1 >"$tmp/s45-note1"; printf '%s\n' "$allp" >"$tmp/s45-allp"
	s4ok "S04-AC-3: (partial reset) the reset fails with the node held: it ran once and the undeletable file is still there" sh -c "[ \"\$(cat '$S45/runs.K01' 2>/dev/null)\" = 1 ] && [ -e '$wt45/K01/sub/u.txt' ]"
	s4ok "S04-AC-3: (partial reset) a patch holds the real edit of f.txt" test -n "$p1"
	s4ok "S04-AC-3: (partial reset) the first failure note in the status log names that patch" sh -c "[ -n '$p1' ] && grep -qF '$p1' '$tmp/s45-note1'"
	s4ok "S04-AC-3: (partial reset) the first failure note names the cause (the file or directory that cannot be removed, permission denied)" grep -qiE 'permission|denied|failed to remove|cannot remove|u\.txt|sub/' "$tmp/s45-note1"
	chmod u+w "$wt45/K01/sub"
	s4wait 20 sh -c "[ -e '$S45/rec/K01.2/done' ]"
	pr=$S45/rec/K01.2/prompt
	s4ok "S04-AC-3: (partial reset) once the file is deletable the node starts with a clean worktree" sh -c "[ -e '$S45/rec/K01.2/done' ] && [ ! -s '$S45/rec/K01.2/status' ] && [ ! -e '$wt45/K01/sub/u.txt' ]"
	s4ok "S04-AC-2: (partial reset) the rendered prompt names the patch with the real edit (P1)" sh -c "[ -n '$p1' ] && [ -s '$pr' ] && grep -qF '$p1' '$pr'"
	s4ok "S04-AC-2: (partial reset) the prompt names every patch written and not yet shown (all of leftover/)" s45all "$pr" "$tmp/s45-allp"
	s4wait 20 sh -c "[ -e '$S45/rec/K01.3/done' ]"
	p3=''; for p in $(s45ps K01); do grep -q '^+edit2' "$st45/node/K01/leftover/$p" && p3=$p; done
	pr3=$S45/rec/K01.3/prompt
	s4ok "S04-AC-2: (partial reset) the next start names the new patch (run 2's edit)" sh -c "[ -n '$p3' ] && [ -s '$pr3' ] && grep -qF '$p3' '$pr3'"
	s4ok "S04-AC-2: (partial reset) the next start does not name P1 or any patch shown to run 2 again" s45none "$pr3" "$tmp/s45-allp"
	kill "$lp45"; wait "$lp45" 2>/dev/null
	for f in "$st45"/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done
	chmod -R u+w "$wt45" 2>/dev/null
fi
# rebase base (Q2): K02 is in the same loop; it ran while the checks above waited (or, as root, not at all)
if [ "$(id -u)" = 0 ]; then
	NOODLEBOT_DATA=$data45 PATH=$tmp/bin45:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		bash "$tmp/nb45/scheduler/loop.sh" o/s45 >>"$tmp/s45-loop.out" 2>&1 &
	pids+=("$!"); lp45=$!
	s4wait 20 sh -c "[ -e '$S45/rec/K02.2/done' ]"
	kill "$lp45"; wait "$lp45" 2>/dev/null
	for f in "$st45"/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done
fi
s4wait 10 sh -c "[ -e '$S45/rec/K02.2/done' ]"
dh=$(cat "$S45/dhead.K02" 2>/dev/null); tp=$(cat "$S45/tip.K02" 2>/dev/null); pr2=$S45/rec/K02.2/prompt
s4ok "S04-AC-2: (rebase base) run 1 left the rebase on a detached HEAD that is not the branch tip, and the node restarted" sh -c "[ -n '$dh' ] && [ -n '$tp' ] && [ '$dh' != '$tp' ] && [ -s '$pr2' ]"
s4ok "S04-AC-2: (rebase base) the prompt names the leftover patch" sh -c "[ -s '$pr2' ] && grep -qF 'leftover/' '$pr2'"
s4ok "S04-AC-2: (rebase base) the prompt names the commit the patch applies to (the rebase's detached HEAD)" sh -c "[ -n '$dh' ] && [ -s '$pr2' ] && grep -qF \"\$(printf %s '$dh' | cut -c1-7)\" '$pr2'"

loop_end
