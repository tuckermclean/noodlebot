#!/bin/bash
# S04 (unusual leftovers). Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s04.sh"

# ---- S04 (unusual leftovers): an interrupted merge, out/ not ignored, a force-staged ignored file, a staged-only change, a follow-up ----
# Nodes H01..H05 (no deps) in their own remote, data dir and loop (o/s4c). main carries f.txt and a .gitignore with
# *.ign only (out/ is NOT ignored); branch "other" in the remote edits f.txt. H05's original PR is merged and its
# question answered, so it starts as a follow-up (node/H05-followup-1). The fake claude records at every start into
# $S04C/rec/<ID>.<run>/ (done last); run 1 per node, run 2 (and later) writes QUESTION.md:
#   H01: commits on its branch, then starts a conflicting merge of origin/other and leaves it unfinished, exit 1.
#   H02: writes out/node/H02/brief.md, edits tracked f.txt, adds untracked x.txt, exit 1.
#   H03: git add -f of a new n.ign (matches *.ign, not in HEAD), exit 1.
#   H04: edits f.txt, git add f.txt, restores the worktree copy from HEAD (staged-only change), exit 1.
#   H05: commits on its follow-up branch, exit 1.
S04C=$tmp/s04c; export S04C
mkdir -p "$S04C/rec" "$tmp/bin9" "$tmp/nb9/scheduler" "$tmp/nb9/plugin" "$tmp/data9/repos"
data9=$(cd "$tmp/data9" && pwd -P)
st9=$data9/state/s4c wt9=$data9/worktrees/s4c
S04C_STATE=$st9; export S04C_STATE
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/nb9/scheduler/" ;; esac; done
[ -f "$src/harness.py" ] && { mkdir -p "$tmp/nb9/scheduler/harnesses"; cp "$src/harness.py" "$tmp/nb9/scheduler/"; cp "$src"/harnesses/*.py "$tmp/nb9/scheduler/harnesses/"; }
[ -f "$src/forge.py" ] && { mkdir -p "$tmp/nb9/scheduler/forges"; cp "$src/forge.py" "$tmp/nb9/scheduler/"; cp "$src"/forges/*.py "$tmp/nb9/scheduler/forges/"; }
git init -q -b main "$tmp/work9"; mkdir -p "$tmp/work9/docs"
{ echo 'nodes:'; for i in 1 2 3 4 5; do echo "  - {id: H0$i, name: n$i, deps: []}"; done; } >"$tmp/work9/docs/graph.yaml"
printf 'base\n' >"$tmp/work9/f.txt"; printf '*.ign\n' >"$tmp/work9/.gitignore"
git -C "$tmp/work9" add -A && git -C "$tmp/work9" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$tmp/work9" checkout -q -b other && echo theirs >"$tmp/work9/f.txt" && git -C "$tmp/work9" -c user.name=t -c user.email=t@t commit -qam theirs
git -C "$tmp/work9" checkout -q main
git clone -q --bare "$tmp/work9" "$tmp/remote9.git"
git clone -q "$tmp/remote9.git" "$data9/repos/s4c"
mkdir -p "$st9/node/H05"; echo "Q1: which way?" >"$st9/node/H05/QUESTION.md"; echo "Q1: as recommended" >"$st9/node/H05/ANSWER.md"
cat >"$tmp/bin9/gh" <<'EOF'
#!/bin/sh
case " $* " in
*" --state merged "*) echo '50 node/H05-n5' ;;
*"/issues?labels=noodlebot"*) echo '[]' ;;
esac
exit 0
EOF
cat >"$tmp/bin9/claude" <<'EOF'
#!/bin/sh
id=${2##* }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
n=$(( $(cat "$S04C/runs.$id" 2>/dev/null || echo 0) + 1 )); echo $n >"$S04C/runs.$id"
r=$S04C/rec/$id.$n; mkdir -p "$r"
cp "$S04C_STATE/node/$id/unattended.md" "$r/prompt" 2>/dev/null
git status --porcelain >"$r/status" 2>&1
git rev-parse HEAD >"$r/head" 2>&1
git rev-parse -q --verify MERGE_HEAD >"$r/mergehead" 2>&1 && echo yes >"$r/merging"
cp "out/node/$id/brief.md" "$r/brief" 2>/dev/null
cat f.txt >"$r/f" 2>/dev/null; [ -e x.txt ] && echo yes >"$r/x"; [ -e n.ign ] && echo yes >"$r/ign"
touch "$r/done"
case $id.$n in
H01.1) echo mine >f.txt; git commit -qam mine; git rev-parse HEAD >"$S04C/head1.$id"; git fetch -q origin; git merge -q origin/other >/dev/null 2>&1; exit 1 ;;
H02.1) mkdir -p "out/node/$id"; echo "brief of $id" >"out/node/$id/brief.md"; cp "out/node/$id/brief.md" "$S04C/brief1.$id"
	git rev-parse HEAD >"$S04C/head1.$id"; echo edit >>f.txt; echo untracked >x.txt; exit 1 ;;
H03.1) git rev-parse HEAD >"$S04C/head1.$id"; echo force >n.ign; git add -f n.ign; exit 1 ;;
H04.1) git rev-parse HEAD >"$S04C/head1.$id"; echo staged >>f.txt; git add f.txt; git show HEAD:f.txt >f.txt; exit 1 ;;
H05.1) echo c >c.txt; git add c.txt; git commit -qm "H05 follow-up commit"; git rev-parse HEAD >"$S04C/head1.$id"; exit 1 ;;
*.1) exit 0 ;;
*) echo "Q1: x" >"$S04C_STATE/node/$id/QUESTION.md" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin9/gh" "$tmp/bin9/claude"
s4cf() { cat "$S04C/rec/$1/$2" 2>/dev/null; }
s4cpatch() { ls "$st9/node/$1/leftover"/*.patch 2>/dev/null | head -1; }
NOODLEBOT_DATA=$data9 PATH=$tmp/bin9:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$tmp/nb9/scheduler/loop.sh" o/s4c >>"$tmp/s04c-loop.out" 2>&1 &
pids+=("$!"); lp9=$!
s4wait 25 sh -c "for i in H01 H02 H03 H04 H05; do [ -e '$S04C/rec/'\$i'.2/done' ] || exit 1; done"
s4c_patches() { [ -n "$(s4cpatch H01)" ] && [ -n "$(s4cpatch H02)" ] && [ -n "$(s4cpatch H03)" ]; }
wait_until 5 s4c_patches   # the patches are written before the second starts
# 1: an interrupted merge
s4ok "S04-AC-3: (interrupted merge) run 1 left the merge unfinished and the second session started" sh -c "[ -s '$S04C/head1.H01' ] && [ -e '$S04C/rec/H01.2/done' ]"
s4ok "S04-AC-3: (interrupted merge) git status --porcelain is empty at the second start" sh -c "[ -f '$S04C/rec/H01.2/status' ] && [ ! -s '$S04C/rec/H01.2/status' ]"
s4ok "S04-AC-3: (interrupted merge) no merge is in progress at the second start" sh -c "[ -e '$S04C/rec/H01.2/mergehead' ] && [ ! -e '$S04C/rec/H01.2/merging' ] && ! git -C '$wt9/H01' rev-parse -q --verify MERGE_HEAD >/dev/null"
s4ok "S04-AC-3: (interrupted merge) HEAD is run 1's HEAD" sh -c "[ -s '$S04C/head1.H01' ] && [ \"\$(cat '$S04C/rec/H01.2/head')\" = \"\$(cat '$S04C/head1.H01')\" ]"
s4ok "S04-AC-3: (interrupted merge) a leftover patch exists" sh -c "[ -s '$(s4cpatch H01)' ]"
# 2: out/ not ignored
p=$(s4cpatch H02)
s4ok "S04-AC-3: (out/ not ignored) the node's brief is still there at the second start, unchanged" sh -c "[ -s '$S04C/brief1.H02' ] && cmp -s '$S04C/rec/H02.2/brief' '$S04C/brief1.H02' && cmp -s '$wt9/H02/out/node/H02/brief.md' '$S04C/brief1.H02'"
s4ok "S04-AC-3: (out/ not ignored) the tracked edit is in the patch" sh -c "[ -n '$p' ] && grep -q '^+edit' '$p'"
s4ok "S04-AC-3: (out/ not ignored) the untracked file is in the patch" sh -c "[ -n '$p' ] && grep -q '^+untracked' '$p'"
s4ok "S04-AC-3: (out/ not ignored) the tracked edit and the untracked file are gone from the worktree" sh -c "[ \"\$(cat '$S04C/rec/H02.2/f' 2>/dev/null)\" = base ] && [ ! -e '$S04C/rec/H02.2/x' ] && [ ! -e '$wt9/H02/x.txt' ]"
s4ok "S04-AC-3: (out/ not ignored) the patch does not take the brief" sh -c "[ -n '$p' ] && ! grep -q 'brief.md' '$p'"
# 3: a force-staged new file matching an ignore pattern
p3=$(s4cpatch H03)
s4c3rt() {
	[ -f "$p3" ] && [ -s "$S04C/head1.H03" ] || return 1
	rm -rf "$tmp/rt9"; git clone -q "$data9/repos/s4c" "$tmp/rt9" 2>/dev/null && git -C "$tmp/rt9" checkout -q "$(cat "$S04C/head1.H03")" 2>/dev/null || return 1
	git -C "$tmp/rt9" apply "$p3" || return 1
	[ "$(cat "$tmp/rt9/n.ign" 2>/dev/null)" = force ]
}
s4ok "S04-AC-3: (force-staged ignored file) it is in the patch" sh -c "[ -n '$p3' ] && grep -q 'n.ign' '$p3' && grep -q '^+force' '$p3'"
s4ok "S04-AC-3: (force-staged ignored file) git apply on the same commit in a scratch clone recreates it" s4c3rt
s4ok "S04-AC-3: (force-staged ignored file) at the second start the status is empty and the file is gone" sh -c "[ -e '$S04C/rec/H03.2/done' ] && [ ! -s '$S04C/rec/H03.2/status' ] && [ ! -e '$S04C/rec/H03.2/ign' ]"
# 4: a staged-only change whose worktree file equals HEAD
s4ok "S04-AC-3: (staged-only change) the node is not held: its second session starts" test -e "$S04C/rec/H04.2/done"
s4ok "S04-AC-3: (staged-only change) its worktree is clean at that start" sh -c "[ -f '$S04C/rec/H04.2/status' ] && [ ! -s '$S04C/rec/H04.2/status' ] && [ \"\$(cat '$S04C/rec/H04.2/f' 2>/dev/null)\" = base ]"
s4ok "S04-AC-3: (staged-only change) HEAD is unchanged" sh -c "[ -s '$S04C/head1.H04' ] && [ \"\$(cat '$S04C/rec/H04.2/head' 2>/dev/null)\" = \"\$(cat '$S04C/head1.H04')\" ]"
# 5: a follow-up
fp=$S04C/rec/H05.2/prompt
s4ok "S04-AC-2: (follow-up) its first start gets no resume section" sh -c "[ -s '$S04C/rec/H05.1/prompt' ] && grep -q 'FOLLOW-UP' '$S04C/rec/H05.1/prompt' && ! grep -qF 'git log origin/main..HEAD' '$S04C/rec/H05.1/prompt' && ! grep -qF 'gh run list' '$S04C/rec/H05.1/prompt'"
s4ok "S04-AC-2: (follow-up) its restart renders the follow-up prompt with the resume section (git log origin/main..HEAD, gh run list --branch)" sh -c "grep -q 'FOLLOW-UP' '$fp' && grep -qF 'git log origin/main..HEAD' '$fp' && grep -qF 'gh run list --branch' '$fp'"
s4ok "S04-AC-2: (follow-up) it gives the reason 'rc 1' and 1 commit past origin/main" sh -c "grep -qF 'rc 1' '$fp' && grep -Eq '(^|[^0-9.])1 commit|commits?[^0-9]*[:=(] ?1([^0-9]|\$)' '$fp'"
s4ok "S04-AC-2: (follow-up) it has no unfilled placeholder" sh -c "[ -s '$fp' ] && ! grep -qE '@[A-Z]+@' '$fp'"
kill "$lp9"; wait "$lp9" 2>/dev/null
for f in "$st9"/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done

loop_end
