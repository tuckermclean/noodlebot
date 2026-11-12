#!/bin/bash
# S04 (more leftovers). Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s04.sh"

# ---- S04 (more leftovers): staged content only in the index, a stale index lock, evidence under an ignored out/, a rebase in progress ----
# Nodes J01..J04 (no deps) in their own remote, data dir and loop (o/s4d). main carries f.txt and .gitignore with out/ (kept.md
# of J03 is force-added on main); branch "other" edits f.txt. The fake claude records at every start into $S04D/rec/<ID>.<run>/
# (done last); run 1 leaves the state below and exits 1, run 2 writes QUESTION.md:
#   J01: edit f.txt, git add f.txt, restore f.txt from HEAD (MM); git add n.txt, delete it (AD).
#   J02: tracked edit, then the index.lock a SIGKILLed git leaves.
#   J03: edits out/node/J03/kept.md, git add -f out/node/J03/brief.md, untracked ignored log.txt, edits f.txt.
#   J04: commits on its branch, starts a rebase onto origin/other that stops on a conflict.
S04D=$tmp/s04d; export S04D
mkdir -p "$S04D/rec" "$tmp/bin10" "$tmp/nb10/scheduler" "$tmp/nb10/plugin" "$tmp/data10/repos"
data10=$(cd "$tmp/data10" && pwd -P)
st10=$data10/state/s4d wt10=$data10/worktrees/s4d
S04D_STATE=$st10; export S04D_STATE
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/nb10/scheduler/" ;; esac; done
[ -f "$src/harness.py" ] && { mkdir -p "$tmp/nb10/scheduler/harnesses"; cp "$src/harness.py" "$tmp/nb10/scheduler/"; cp "$src"/harnesses/*.py "$tmp/nb10/scheduler/harnesses/"; }
git init -q -b main "$tmp/work10"; mkdir -p "$tmp/work10/docs" "$tmp/work10/out/node/J03"
{ echo 'nodes:'; for i in 1 2 3 4; do echo "  - {id: J0$i, name: n$i, deps: []}"; done; } >"$tmp/work10/docs/graph.yaml"
printf 'base\n' >"$tmp/work10/f.txt"; printf 'out/\n' >"$tmp/work10/.gitignore"; printf 'kept v0\n' >"$tmp/work10/out/node/J03/kept.md"
git -C "$tmp/work10" add -A && git -C "$tmp/work10" add -f out/node/J03/kept.md && git -C "$tmp/work10" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$tmp/work10" checkout -q -b other && echo theirs >"$tmp/work10/f.txt" && git -C "$tmp/work10" -c user.name=t -c user.email=t@t commit -qam theirs
git -C "$tmp/work10" checkout -q main
git clone -q --bare "$tmp/work10" "$tmp/remote10.git"
git clone -q "$tmp/remote10.git" "$data10/repos/s4d"
cat >"$tmp/bin10/gh" <<'EOF'
#!/bin/sh
case " $* " in
*"/issues?labels=noodlebot"*) echo '[]' ;;
esac
exit 0
EOF
cat >"$tmp/bin10/claude" <<'EOF'
#!/bin/sh
id=${2##* }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
n=$(( $(cat "$S04D/runs.$id" 2>/dev/null || echo 0) + 1 )); echo $n >"$S04D/runs.$id"
r=$S04D/rec/$id.$n; mkdir -p "$r"
git status --porcelain >"$r/status" 2>&1
git rev-parse HEAD >"$r/head" 2>&1
git rev-parse --abbrev-ref HEAD >"$r/branch" 2>&1
[ -e "$(git rev-parse --git-path rebase-merge)" ] && echo yes >"$r/rebasing"
[ -e "$(git rev-parse --git-path rebase-apply)" ] && echo yes >"$r/rebasing"
git rev-parse "node/$id-n${id#J0}" >"$r/tip" 2>/dev/null
ls "$S04D_STATE/node/$id/leftover" 2>/dev/null | wc -l >"$r/npatch"
cat f.txt >"$r/f" 2>/dev/null; [ -e n.txt ] && echo yes >"$r/n"
for x in kept.md brief.md log.txt; do cp "out/node/$id/$x" "$r/$x" 2>/dev/null; done
touch "$r/done"
case $id.$n in
J01.1) git rev-parse HEAD >"$S04D/head1.$id"; echo staged >>f.txt; git add f.txt; git show HEAD:f.txt >f.txt
	echo newfile >n.txt; git add n.txt; rm n.txt; exit 1 ;;
J02.1) git rev-parse HEAD >"$S04D/head1.$id"; echo edit >>f.txt; : >"$(git rev-parse --git-path index.lock)"; exit 1 ;;
J03.1) git rev-parse HEAD >"$S04D/head1.$id"; echo "kept v1" >"out/node/$id/kept.md"; echo "brief v1" >"out/node/$id/brief.md"; git add -f "out/node/$id/brief.md"
	echo "log v1" >"out/node/$id/log.txt"; echo ordinary >>f.txt; exit 1 ;;
J04.1) echo mine >f.txt; git commit -qam mine; git rev-parse HEAD >"$S04D/head1.$id"; git fetch -q origin; git rebase origin/other >/dev/null 2>&1; exit 1 ;;
*.1) exit 0 ;;
*) echo "Q1: x" >"$S04D_STATE/node/$id/QUESTION.md" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin10/gh" "$tmp/bin10/claude"
s4dpatch() { ls "$st10/node/$1/leftover"/*.patch 2>/dev/null | head -1; }
NOODLEBOT_DATA=$data10 PATH=$tmp/bin10:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$tmp/nb10/scheduler/loop.sh" o/s4d >>"$tmp/s04d-loop.out" 2>&1 &
pids+=("$!"); lp10=$!
s4wait 20 sh -c "for i in J01 J02 J03 J04; do [ -e '$S04D/rec/'\$i'.2/done' ] || exit 1; done"
wait_ticks 3 "$st10"   # "still exactly one patch after a few more ticks"
# 1: staged content only in the index
p=$(s4dpatch J01)
s4ok "S04-AC-3: (index-only content) the node started: its second session ran" test -e "$S04D/rec/J01.2/done"
s4ok "S04-AC-3: (index-only content) the patch holds the staged edit of f.txt" sh -c "[ -n '$p' ] && grep -q '^+staged' '$p'"
s4ok "S04-AC-3: (index-only content) the patch holds the staged new file n.txt" sh -c "[ -n '$p' ] && grep -q '^+newfile' '$p'"
s4ok "S04-AC-3: (index-only content) the worktree is clean at the second start" sh -c "[ -f '$S04D/rec/J01.2/status' ] && [ ! -s '$S04D/rec/J01.2/status' ] && [ ! -e '$S04D/rec/J01.2/n' ]"
# 2: a stale index lock
s4ok "S04-AC-3: (stale index lock) the node starts again within the wait" test -e "$S04D/rec/J02.2/done"
s4ok "S04-AC-3: (stale index lock) the worktree is clean at that start" sh -c "[ -f '$S04D/rec/J02.2/status' ] && [ ! -s '$S04D/rec/J02.2/status' ] && [ \"\$(cat '$S04D/rec/J02.2/f' 2>/dev/null)\" = base ]"
s4ok "S04-AC-3: (stale index lock) exactly one patch at that start, holding the edit" sh -c "[ \"\$(tr -d ' \n' <'$S04D/rec/J02.2/npatch')\" = 1 ] && grep -q '^+edit' '$(s4dpatch J02)'"
s4ok "S04-AC-3: (stale index lock) still exactly one patch after a few more ticks" test "$(ls "$st10/node/J02/leftover" 2>/dev/null | wc -l)" = 1
# 3: evidence under an ignored out/
p=$(s4dpatch J03)
s4ok "S04-AC-3: (ignored out/) kept.md, brief.md and log.txt are present at the second start with run 1's content" sh -c "[ \"\$(cat '$S04D/rec/J03.2/kept.md' 2>/dev/null)\" = 'kept v1' ] && [ \"\$(cat '$S04D/rec/J03.2/brief.md' 2>/dev/null)\" = 'brief v1' ] && [ \"\$(cat '$S04D/rec/J03.2/log.txt' 2>/dev/null)\" = 'log v1' ]"
s4ok "S04-AC-3: (ignored out/) the ordinary edit is in the patch" sh -c "[ -n '$p' ] && grep -q '^+ordinary' '$p'"
s4ok "S04-AC-3: (ignored out/) the ordinary edit is gone from the worktree" sh -c "[ \"\$(cat '$S04D/rec/J03.2/f' 2>/dev/null)\" = base ]"
s4ok "S04-AC-3: (ignored out/) the files are still in the worktree afterwards" sh -c "[ \"\$(cat '$wt10/J03/out/node/J03/kept.md' 2>/dev/null)\" = 'kept v1' ] && [ \"\$(cat '$wt10/J03/out/node/J03/brief.md' 2>/dev/null)\" = 'brief v1' ] && [ \"\$(cat '$wt10/J03/out/node/J03/log.txt' 2>/dev/null)\" = 'log v1' ]"
# 4: a rebase in progress
s4ok "S04-AC-3: (rebase) run 1 left a rebase in progress and the node started again" sh -c "[ -s '$S04D/head1.J04' ] && [ -e '$S04D/rec/J04.2/done' ]"
s4ok "S04-AC-3: (rebase) no rebase is in progress at the second start" sh -c "[ -e '$S04D/rec/J04.2/done' ] && [ ! -e '$S04D/rec/J04.2/rebasing' ]"
s4ok "S04-AC-3: (rebase) HEAD is on the node's branch" test "$(cat "$S04D/rec/J04.2/branch" 2>/dev/null)" = node/J04-n4
s4ok "S04-AC-3: (rebase) the branch tip equals run 1's commit" sh -c "[ -s '$S04D/head1.J04' ] && [ \"\$(cat '$S04D/rec/J04.2/tip' 2>/dev/null)\" = \"\$(cat '$S04D/head1.J04')\" ]"
s4ok "S04-AC-3: (rebase) the worktree is clean at the second start" sh -c "[ -f '$S04D/rec/J04.2/status' ] && [ ! -s '$S04D/rec/J04.2/status' ]"
s4ok "S04-AC-3: (rebase) a leftover patch exists" sh -c "[ -s '$(s4dpatch J04)' ]"
kill "$lp10"; wait "$lp10" 2>/dev/null
for f in "$st10"/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done

loop_end
