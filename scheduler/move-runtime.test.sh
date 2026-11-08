#!/bin/sh
# shellcheck disable=SC2015 # pass only echoes, so "A && pass || fail" never runs both
# Tests scheduler/move-runtime.sh (run here as: bash scheduler/move-runtime.sh <checkout>):
# it moves an installation's repos/, worktrees/ and state/ to the runtime root.
#   sh scheduler/move-runtime.test.sh   (make test)
set -u
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root" || exit 2
mv_sh=$root/scheduler/move-runtime.sh
tmp=$(mktemp -d)
bg=
trap 'for p in $bg; do kill "$p" 2>/dev/null; done; rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export HOME=$tmp/home; mkdir -p "$HOME"
unset NOODLEBOT_DATA

# fixture <dir>: <dir>/co is a checkout with clones proj (worktrees A01, A02) and other (worktree B01),
# state with markers and files; <dir>/data is the runtime root.
fixture() {
	co=$1/co; data=$1/data; mkdir -p "$co/repos" "$co/worktrees/proj" "$co/worktrees/other" "$data"
	for n in proj other; do
		git init -q "$1/origin-$n" && git -C "$1/origin-$n" commit -q --allow-empty -m init
		git clone -q "$1/origin-$n" "$co/repos/$n"
	done
	git -C "$co/repos/proj" worktree add -q -b nodeA01 "$co/worktrees/proj/A01"
	git -C "$co/repos/proj" worktree add -q -b nodeA02 "$co/worktrees/proj/A02"
	git -C "$co/repos/other" worktree add -q -b nodeB01 "$co/worktrees/other/B01"
	mkdir -p "$co/state/proj/node/A01" "$co/state/proj/node/A02" "$co/state/other/node/B01"
	echo "which?" >"$co/state/proj/node/A01/QUESTION.md"
	echo 12 >"$co/state/proj/node/A02/WAITING-PR"
	echo "tick 1" >"$co/state/proj/status.log"
	echo "tick 2" >"$co/state/other/status.log"
	: >"$co/state/proj/loop.lock"
}
sums() { (cd "$1" 2>/dev/null && find . -type f ! -name loop.lock | sort | while read -r f; do printf '%s ' "$f"; cksum <"$f"; done); }
intact() { [ -d "$1/repos/proj/.git" ] && [ -d "$1/repos/other/.git" ] && [ -d "$1/worktrees/proj/A01" ] && [ -d "$1/worktrees/proj/A02" ] && [ -d "$1/worktrees/other/B01" ] && [ -f "$1/state/proj/node/A01/QUESTION.md" ]; }
empty() { [ -z "$(ls -A "$1")" ]; }

# --- D02-AC-5: the move
f=$tmp/f1; fixture "$f"; co=$f/co; data=$f/data
before=$(sums "$co/state")
out=$(NOODLEBOT_DATA=$data bash "$mv_sh" "$co" 2>&1); rc=$?
[ $rc = 0 ] && pass "D02-AC-5 the move exits 0" || fail "D02-AC-5 the move exits 0: rc $rc, out '$out'"
l=$(git -C "$data/repos/proj" worktree list 2>&1)
case $l in *"$data/worktrees/proj/A01"*) a=1 ;; *) a= ;; esac
case $l in *"$data/worktrees/proj/A02"*) b=1 ;; *) b= ;; esac
[ -n "$a" ] && [ -n "$b" ] && ! printf '%s' "$l" | grep -q "$co" && pass "D02-AC-5 git worktree list in the moved proj clone lists both worktrees at their new paths" || fail "D02-AC-5 proj worktree list: '$l'"
l=$(git -C "$data/repos/other" worktree list 2>&1)
case $l in *"$data/worktrees/other/B01"*) pass "D02-AC-5 git worktree list in the moved other clone lists its worktree at the new path" ;; *) fail "D02-AC-5 other worktree list: '$l'" ;; esac
ok=1
for w in proj/A01 proj/A02 other/B01; do git -C "$data/worktrees/$w" status >/dev/null 2>&1 || ok=; done
[ -n "$ok" ] && pass "D02-AC-5 git status succeeds in each moved worktree" || fail "D02-AC-5 git status fails in a moved worktree"
after=$(sums "$data/state")
[ -n "$before" ] && [ "$before" = "$after" ] && pass "D02-AC-5 the state's files are unchanged" || fail "D02-AC-5 state files differ: '$before' vs '$after'"
[ ! -e "$co/repos" ] && [ ! -e "$co/worktrees" ] && [ ! -e "$co/state" ] && pass "D02-AC-5 the checkout has no repos/, worktrees/ or state/ left" || fail "D02-AC-5 checkout left: $(ls "$co")"
out=$(NOODLEBOT_DATA=$data bash "$mv_sh" "$co" 2>&1); rc=$?
after2=$(sums "$data/state")
[ $rc = 0 ] && [ -n "$out" ] && [ "$after" = "$after2" ] && [ ! -e "$co/repos" ] && [ ! -e "$co/state" ] && pass "D02-AC-5 a second run moves nothing, says so and exits 0" || fail "D02-AC-5 second run: rc $rc, out '$out'"

# --- D02-AC-5: the default root, NOODLEBOT_DATA unset
f=$tmp/f2; fixture "$f"; co=$f/co; def=$HOME/.local/share/noodlebot
out=$(env -u NOODLEBOT_DATA bash "$mv_sh" "$co" 2>&1); rc=$?
[ $rc = 0 ] && [ -d "$def/repos/proj/.git" ] && [ -d "$def/worktrees/proj/A01" ] && [ -f "$def/state/proj/node/A01/QUESTION.md" ] && [ ! -e "$co/repos" ] &&
	git -C "$def/worktrees/proj/A02" status >/dev/null 2>&1 &&
	pass "D02-AC-5 with NOODLEBOT_DATA unset it moves to \$HOME/.local/share/noodlebot" || fail "D02-AC-5 default root: rc $rc, out '$out'"
rm -rf "$def"

# refusal check: <label> <fixture-dir> <reason-pattern-regex>
refused() {
	label=$1; ff=$2; pat=$3
	out=$(NOODLEBOT_DATA=$ff/data bash "$mv_sh" "$ff/co" 2>&1); rc=$?
	[ $rc != 0 ] && [ $rc != 127 ] && pass "D02-AC-6 $label: exits non-zero" || fail "D02-AC-6 $label: exits non-zero (rc $rc, out '$out')"
	printf '%s' "$out" | grep -Eq "$pat" && pass "D02-AC-6 $label: names the reason" || fail "D02-AC-6 $label: message lacks /$pat/: '$out'"
	intact "$ff/co" && [ ! -e "$ff/data/worktrees" ] && pass "D02-AC-6 $label: the checkout is intact" || fail "D02-AC-6 $label: checkout changed"
}

# a held loop.lock
f=$tmp/f3; fixture "$f"
( exec 8>"$f/co/state/proj/loop.lock"; flock -n 8 && exec sleep 60 ) &
bg="$bg $!"
i=0; while flock -n "$f/co/state/proj/loop.lock" true 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
refused "a held loop.lock" "$f" 'loop\.lock'
[ -d "$f/co/state" ] && empty "$f/data" && pass "D02-AC-6 a held loop.lock: the root gained nothing" || fail "D02-AC-6 a held loop.lock: root has $(ls "$f/data")"

# a live session.pid
f=$tmp/f4; fixture "$f"
sleep 60 & p=$!; bg="$bg $p"
echo "$p" >"$f/co/state/proj/node/A01/session.pid"
refused "a live session.pid" "$f" "session\.pid|$p"
[ -d "$f/co/state" ] && empty "$f/data" && pass "D02-AC-6 a live session.pid: the root gained nothing" || fail "D02-AC-6 a live session.pid: root has $(ls "$f/data")"

# an existing target
f=$tmp/f5; fixture "$f"; mkdir -p "$f/data/state/proj"; echo keep >"$f/data/state/proj/mine"
refused "an existing target" "$f" "$f/data/state|data/state"
[ "$(cat "$f/data/state/proj/mine")" = keep ] && [ ! -e "$f/data/repos" ] && [ ! -e "$f/data/worktrees" ] && pass "D02-AC-6 an existing target: the target is untouched and nothing else moved" || fail "D02-AC-6 an existing target: root changed: $(ls "$f/data")"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all move-runtime checks"
