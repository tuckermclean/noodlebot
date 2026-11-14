#!/bin/bash
# S04 (tracked but ignored). Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s04.sh"

# ---- S04 (tracked but ignored): a tracked file matching an ignore pattern is not "ignored" by Git: its edit is in the patch ----
# Node F01 in its own remote, data dir and loop (o/s4b). main carries .gitignore (out/, *.ign), a tracked n.txt and
# the force-added keep.ign and t.ign. Run 1 edits t.ign and n.txt, leaves keep.ign alone, exits 1. Run 2 asks QUESTION.md.
S04B=$tmp/s04b; export S04B
mkdir -p "$S04B/rec" "$tmp/bin8" "$tmp/nb8/scheduler" "$tmp/nb8/plugin" "$tmp/data8/repos"
data8=$(cd "$tmp/data8" && pwd -P)
st8=$data8/state/s4b
S04B_STATE=$st8; export S04B_STATE
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/nb8/scheduler/" ;; esac; done
[ -f "$src/harness.py" ] && { mkdir -p "$tmp/nb8/scheduler/harnesses"; cp "$src/harness.py" "$tmp/nb8/scheduler/"; cp "$src"/harnesses/*.py "$tmp/nb8/scheduler/harnesses/"; }
[ -f "$src/forge.py" ] && { mkdir -p "$tmp/nb8/scheduler/forges"; cp "$src/forge.py" "$tmp/nb8/scheduler/"; cp "$src"/forges/*.py "$tmp/nb8/scheduler/forges/"; }
git init -q -b main "$tmp/work8"; mkdir -p "$tmp/work8/docs"
echo 'nodes:
  - {id: F01, name: n1, deps: []}' >"$tmp/work8/docs/graph.yaml"
printf 'n\n' >"$tmp/work8/n.txt"; printf 'out/\n*.ign\n' >"$tmp/work8/.gitignore"
printf 'keep\n' >"$tmp/work8/keep.ign"; printf 't\n' >"$tmp/work8/t.ign"
git -C "$tmp/work8" add -A && git -C "$tmp/work8" add -f keep.ign t.ign && git -C "$tmp/work8" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work8" "$tmp/remote8.git"
git clone -q "$tmp/remote8.git" "$data8/repos/s4b"
cat >"$tmp/bin8/gh" <<'EOF'
#!/bin/sh
case " $* " in
*"/issues?labels=noodlebot"*) echo '[]' ;;
esac
exit 0
EOF
cat >"$tmp/bin8/claude" <<'EOF'
#!/bin/sh
id=${2##* }
n=$(( $(cat "$S04B/runs" 2>/dev/null || echo 0) + 1 )); echo $n >"$S04B/runs"
r=$S04B/rec/$n; mkdir -p "$r"
git status --porcelain >"$r/status" 2>&1
git rev-parse HEAD >"$r/head" 2>&1
cat t.ign >"$r/t" 2>/dev/null; cat keep.ign >"$r/keep" 2>/dev/null; cat n.txt >"$r/n" 2>/dev/null
touch "$r/done"
case $n in
1) git rev-parse HEAD >"$S04B/head1"; echo edited >>t.ign; echo edited >>n.txt; exit 1 ;;
*) echo "Q1: x" >"$S04B_STATE/node/$id/QUESTION.md" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin8/gh" "$tmp/bin8/claude"
NOODLEBOT_DATA=$data8 PATH=$tmp/bin8:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$tmp/nb8/scheduler/loop.sh" o/s4b >>"$tmp/s04b-loop.out" 2>&1 &
pids+=("$!"); lp8=$!
s4wait 25 sh -c "[ -e '$S04B/rec/2/done' ]"
s4b_patch() { [ -n "$(ls "$st8"/node/F01/leftover/*.patch 2>/dev/null)" ]; }
wait_until 5 s4b_patch   # the patch is written before the second start
pt=$(ls "$st8"/node/F01/leftover/*.patch 2>/dev/null | head -1)
s4bnodel() { # the patch deletes neither keep.ign nor t.ign
	awk '/^diff --git /{f=$3} /^deleted file mode/{ if (f ~ /(keep|t)\.ign$/) bad=1 } END{exit bad}' "$1"
}
s4brt() { # git apply on the same commit reproduces both edits and leaves keep.ign as committed
	[ -f "$pt" ] || return 1
	rm -rf "$tmp/rt8"; git clone -q "$data8/repos/s4b" "$tmp/rt8" 2>/dev/null && git -C "$tmp/rt8" checkout -q "$(cat "$S04B/head1")" 2>/dev/null || return 1
	git -C "$tmp/rt8" apply "$pt" || return 1
	[ "$(cat "$tmp/rt8/t.ign")" = "$(printf 't\nedited')" ] && [ "$(cat "$tmp/rt8/n.txt")" = "$(printf 'n\nedited')" ] && [ "$(cat "$tmp/rt8/keep.ign")" = keep ]
}
s4ok "S04-AC-3: (tracked but ignored) the second session started" test -e "$S04B/rec/2/done"
s4ok "S04-AC-3: (tracked but ignored) the patch carries the edit of t.ign" sh -c "[ -n '$pt' ] && awk '/^diff --git /{f=\$3} f ~ /t\\.ign\$/ && /^\\+edited\$/{ok=1} END{exit !ok}' '$pt'"
s4ok "S04-AC-3: (tracked but ignored) the patch deletes neither keep.ign nor t.ign" sh -c "[ -n '$pt' ] && $(declare -f s4bnodel) && s4bnodel '$pt'"
s4ok "S04-AC-3: (tracked but ignored) git apply on the same commit reproduces both edits and leaves keep.ign as committed" s4brt
s4ok "S04-AC-3: (tracked but ignored) at the second start git status --porcelain is empty" sh -c "[ -f '$S04B/rec/2/status' ] && [ ! -s '$S04B/rec/2/status' ]"
s4ok "S04-AC-3: (tracked but ignored) at the second start t.ign and keep.ign are at their committed content" sh -c "[ \"\$(cat '$S04B/rec/2/t' 2>/dev/null)\" = t ] && [ \"\$(cat '$S04B/rec/2/keep' 2>/dev/null)\" = keep ] && [ \"\$(cat '$S04B/rec/2/n' 2>/dev/null)\" = n ]"
kill "$lp8"; wait "$lp8" 2>/dev/null
for f in "$st8"/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done

loop_end
