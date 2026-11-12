#!/bin/sh
# D04: deploy.sh spends make test only on commits that change a runtime path. Test of scheduler/deploy.sh against a
# fake remote of the scheduler's own repository (the live checkout is a clone), in the style of deploy.test.sh.
# make test is stubbed by the Makefile of the first commit: it appends one line to $log per call,
#   call <sha> jobs=[<TEST_JOBS make variable>] env=[<TEST_JOBS environment>] tests=[<TESTS>]
# and fails (printing the file's content) when $failing/<sha> exists. A later case adds a case by appending lines:
# it builds its commits with mk, makes a stub fail with failing <sha> [<output>], and reads $log with ncalls/callsof.
#   sh scheduler/deploy-d04.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
# ok <name> <condition>: PASS when the whole shell condition (a string, evaluated here) succeeds.
ok() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

unset TEST_JOBS TESTS USAGE_7D_MARGIN NOODLEBOT_VERSION
export HOME=$tmp/home
export NOODLEBOT_DATA=$tmp/data
mkdir -p "$HOME" "$tmp/failing"
log=$tmp/make.log
: >"$log"
failing=$tmp/failing
deploy=$src/deploy.sh
live=$tmp/live
dd=$NOODLEBOT_DATA/deploy

git init -q -b main "$tmp/work"
g() { git -C "$tmp/work" -c user.name=t -c user.email=t@t "$@"; }
# mk <label> <path>...: a new commit on the remote's main that appends <label> to each path (creating it).
mk() {
	l=$1; shift
	for p in "$@"; do mkdir -p "$(dirname "$tmp/work/$p")"; echo "$l" >>"$tmp/work/$p"; done
	g add -A && g commit -q -m "$l" && g push -q "$tmp/remote.git" HEAD:main 2>/dev/null
}
# mk2 <label> <path>...: like mk, but commits without pushing; push_main publishes all of them at once.
mk2() {
	l=$1; shift
	for p in "$@"; do mkdir -p "$(dirname "$tmp/work/$p")"; echo "$l" >>"$tmp/work/$p"; done
	g add -A && g commit -q -m "$l"
}
push_main() { g push -q "$tmp/remote.git" HEAD:main 2>/dev/null; }
head_w() { git -C "$tmp/work" rev-parse HEAD; }
# the stub: the first commit's Makefile
printf 'test:\n\t@sha=$$(git rev-parse HEAD); echo "call $$sha jobs=[$(TEST_JOBS)] env=[$$TEST_JOBS] tests=[$(TESTS)]" >>%s; if [ -e %s/$$sha ]; then cat %s/$$sha; exit 1; fi\n' "$log" "$failing" "$failing" >"$tmp/work/Makefile"
for p in SPEC.md AGENTS.md CLAUDE.md README.md docs/graph.yaml nodes/N01.md .github/workflows/t.yml scheduler/x.sh; do
	mkdir -p "$(dirname "$tmp/work/$p")"; echo base >"$tmp/work/$p"
done
g add -A && g commit -q -m c0
g tag v0.1.0
git clone -q --bare "$tmp/work" "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$live"
g remote add origin "$tmp/remote.git" 2>/dev/null

short() { printf %.7s "$1"; }
ver() { git -C "$tmp/work" describe --tags --always "$1" 2>/dev/null; }
head_of() { git -C "$live" rev-parse HEAD; }
dep() { sh "$deploy" "$live" 2>&1; }
ncalls() { grep -c '^call ' "$log"; }
callsof() { grep -c "^call $1 " "$log"; }
failing() { printf '%s\n' "${2:-stub failure}" >"$failing/$1"; }
in_rejected() { grep -qx "$1" "$dd/rejected" 2>/dev/null; }
nlines() { printf '%s\n' "$1" | grep -c .; }
# deployed_line <old> <new> <suffix>: the status line of a deploy.
deployed_line() { echo "deployed $1..$2 (version $(ver "$2"))$3"; }
rejected_line() { echo "not deployed: $1 (version $(ver "$1")) fails make test"; }

# A runtime commit first, so deploy/previous exists: it must stay as it is over a non-runtime deploy.
mk r0 scheduler/x.sh
r0=$(head_w); c0=$(git -C "$tmp/work" rev-parse HEAD~1)
out=$(dep)
ok "D04-AC-1 setup: a runtime commit is deployed with make test (guard)" '[ "$(head_of)" = "$r0" ] && [ "$(ncalls)" = 1 ] && [ "$(cat "$dd/previous" 2>/dev/null)" = "$c0" ]'

# D04-AC-1: a commit that changes only non-runtime paths is fast-forwarded without make test.
mk n1 SPEC.md AGENTS.md CLAUDE.md README.md docs/graph.yaml nodes/N01.md .github/workflows/t.yml
n1=$(head_w)
calls_before=$(ncalls)
prev_before=$(cat "$dd/previous" 2>/dev/null)
out=$(dep)
ok "D04-AC-1 the live checkout moves to the non-runtime commit" '[ "$(head_of)" = "$n1" ]'
ok "D04-AC-1 make test is not run (the stub records no call)" '[ "$(head_of)" = "$n1" ] && [ "$(ncalls)" = "$calls_before" ] && [ "$(callsof "$n1")" = 0 ]'
ok "D04-AC-1 one status line 'deployed <old>..<new> (version <v>) without make test: no runtime change'" '[ "$out" = "$(deployed_line "$r0" "$n1" " without make test: no runtime change")" ]'
ok "D04-AC-1 deploy/previous is unchanged" '[ -n "$prev_before" ] && [ "$(cat "$dd/previous" 2>/dev/null)" = "$prev_before" ]'
ok "D04-AC-1 the commit is not recorded as rejected" '[ "$(head_of)" = "$n1" ] && ! in_rejected "$n1"'
ok "D04-AC-1 the next run prints nothing" '[ "$(head_of)" = "$n1" ] && [ -z "$(dep)" ]'
# two non-runtime commits in one range: still no make test
mk2 n2 docs/a.md; mk2 n3 nodes/N02.md; push_main
n3=$(head_w)
out=$(dep)
ok "D04-AC-1 a range of two non-runtime commits is fast-forwarded without make test" '[ "$(head_of)" = "$n3" ] && [ "$(ncalls)" = "$calls_before" ] && [ "$out" = "$(deployed_line "$n1" "$n3" " without make test: no runtime change")" ]'

# D04-AC-2: a commit that also changes scheduler/ is tested, and rejected when its stub fails.
mk s1 SPEC.md scheduler/x.sh
s1=$(head_w); failing "$s1"
before=$(head_of); n=$(ncalls)
out=$(dep)
ok "D04-AC-2 a commit that also changes scheduler/ runs the stub" '[ "$(callsof "$s1")" = 1 ]'
ok "D04-AC-2 and is rejected when it fails: the unchanged line, the live checkout stays" '[ "$(callsof "$s1")" = 1 ] && [ "$out" = "$(rejected_line "$s1")" ] && [ "$(head_of)" = "$before" ] && in_rejected "$s1"'
mk s2 SPEC.md scheduler/y.sh
s2=$(head_w)
prev_before=$(cat "$dd/previous" 2>/dev/null)
out=$(dep)
ok "D04-AC-2 a passing commit that also changes scheduler/ runs the stub and is deployed in full" '[ "$(callsof "$s2")" = 1 ] && [ "$(head_of)" = "$s2" ] && [ "$out" = "$(deployed_line "$before" "$s2" "")" ] && [ "$(cat "$dd/previous")" = "$before" ]'

# D04-AC-2: a range of two commits, the first runtime and the second not: tested (the tip alone is non-runtime).
mk2 t1 scheduler/z.sh; mk2 t2 docs/b.md; push_main
t2=$(head_w); failing "$t2"
before=$(head_of)
out=$(dep)
ok "D04-AC-2 a range of two commits whose first is runtime and second is not runs the stub" '[ "$(callsof "$t2")" = 1 ]'
ok "D04-AC-2 and is rejected when it fails" '[ "$(callsof "$t2")" = 1 ] && [ "$out" = "$(rejected_line "$t2")" ] && [ "$(head_of)" = "$before" ] && in_rejected "$t2"'
mk2 t3 scheduler/z2.sh; mk2 t4 nodes/N03.md; push_main
t4=$(head_w)
out=$(dep)
ok "D04-AC-2 the same range shape, passing, runs the stub and is deployed in full" '[ "$(callsof "$t4")" = 1 ] && [ "$(head_of)" = "$t4" ] && [ "$out" = "$(deployed_line "$before" "$t4" "")" ]'

# D04-AC-2: a commit that adds a new top-level path is tested.
mk u1 tools/new.sh
u1=$(head_w); failing "$u1"
before=$(head_of)
out=$(dep)
ok "D04-AC-2 a commit that adds a new top-level directory runs the stub" '[ "$(callsof "$u1")" = 1 ]'
ok "D04-AC-2 and is rejected when it fails" '[ "$(callsof "$u1")" = 1 ] && [ "$out" = "$(rejected_line "$u1")" ] && [ "$(head_of)" = "$before" ] && in_rejected "$u1"'
mk u2 TOPLEVEL.txt
u2=$(head_w)
out=$(dep)
ok "D04-AC-2 a commit that adds a new top-level file runs the stub and is deployed in full" '[ "$(callsof "$u2")" = 1 ] && [ "$(head_of)" = "$u2" ] && [ "$out" = "$(deployed_line "$before" "$u2" "")" ]'

# D04-AC-3: deploy.sh --runtime-changed <live> <from> [<to>]: 0 a runtime path changed, 1 none, 2 git failed.
# It needs no lock and no $NOODLEBOT_DATA state: it runs here with a HOME and a data root that do not exist.
rc=$tmp/rc
git init -q -b main "$rc"
rg() { git -C "$rc" -c user.name=t -c user.email=t@t "$@"; }
echo base >"$rc/base" && rg add -A && rg commit -q -m base
# rcmk <path>: a commit changing that path only; the status of --runtime-changed over it is in $st.
rcmk() {
	pre=$(git -C "$rc" rev-parse HEAD)
	mkdir -p "$(dirname "$rc/$1")"; echo "$1" >>"$rc/$1"
	rg add -A && rg commit -q -m "$1"
}
rcheck() { env -u NOODLEBOT_DATA HOME="$tmp/nohome" sh "$deploy" --runtime-changed "$rc" "$@" >"$tmp/rc.out" 2>&1; st=$?; }
for p in SPEC.md AGENTS.md CLAUDE.md README.md docs/graph.yaml docs/sub/x.md nodes/N01.md .github/workflows/t.yml; do
	rcmk "$p"; rcheck "$pre" HEAD
	ok "D04-AC-3 --runtime-changed exits 1 for a change of $p only" '[ "$st" = 1 ]'
done
for p in scheduler/loop.sh plugin/p.json site/s.js Makefile .claude/agents/a.md newtop/x tools.txt; do
	rcmk "$p"; rcheck "$pre" HEAD
	ok "D04-AC-3 --runtime-changed exits 0 for a change of $p" '[ "$st" = 0 ]'
done
rcmk docs/z.md; mid=$(git -C "$rc" rev-parse HEAD); rcmk scheduler/q.sh; rcmk docs/z2.md
first=$(git -C "$rc" rev-parse HEAD~3)
rcheck "$first" HEAD
ok "D04-AC-3 --runtime-changed exits 0 when a runtime path is anywhere in the range" '[ "$st" = 0 ]'
rcheck "$first" "$mid"
ok "D04-AC-3 --runtime-changed <from> <to> looks at that range only (exit 1 over a non-runtime range)" '[ "$st" = 1 ]'
rcheck "$first"
ok "D04-AC-3 --runtime-changed <from> defaults <to> to HEAD (exit 0)" '[ "$st" = 0 ]'
rcheck HEAD HEAD
ok "D04-AC-3 --runtime-changed over an empty range exits 1" '[ "$st" = 1 ]'
rcheck 0123456789abcdef0123456789abcdef01234567 HEAD
ok "D04-AC-3 --runtime-changed exits 2 when git fails (unknown <from>)" '[ "$st" = 2 ] && ! grep -q "usage" "$tmp/rc.out"'
rcheck HEAD 0123456789abcdef0123456789abcdef01234567
ok "D04-AC-3 --runtime-changed exits 2 when git fails (unknown <to>)" '[ "$st" = 2 ] && ! grep -q "usage" "$tmp/rc.out"'
rcheck "$first" HEAD
ok "D04-AC-3 --runtime-changed writes no state and takes no lock (no home or data folder is created)" '[ "$st" = 0 ] && [ ! -e "$tmp/nohome" ]'

echo
if [ "$fails" -eq 0 ]; then echo "all D04 deploy tests passed"; else echo "$fails D04 deploy test(s) FAILED"; exit 1; fi
