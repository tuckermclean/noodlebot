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
status_of() { printf '%s\n' "$1" | grep -v '^make test failed for '; }
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
ok "D04-AC-2 and is rejected when it fails: the unchanged line, the live checkout stays" '[ "$(callsof "$s1")" = 1 ] && [ "$(status_of "$out")" = "$(rejected_line "$s1")" ] && [ "$(head_of)" = "$before" ] && in_rejected "$s1"'
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
ok "D04-AC-2 and is rejected when it fails" '[ "$(callsof "$t2")" = 1 ] && [ "$(status_of "$out")" = "$(rejected_line "$t2")" ] && [ "$(head_of)" = "$before" ] && in_rejected "$t2"'
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
ok "D04-AC-2 and is rejected when it fails" '[ "$(callsof "$u1")" = 1 ] && [ "$(status_of "$out")" = "$(rejected_line "$u1")" ] && [ "$(head_of)" = "$before" ] && in_rejected "$u1"'
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

# D04-AC-4, D04-AC-5, D04-AC-6: a failed make test is rerun once, alone, for the files it named (FAILED <file> lines).
# From here the commits carry a second stub: a Makefile whose test target calls $tmp/stubs/test.sh, which records the same
# "call" line and behaves per commit from files in $beh: <sha>.first is the output of a failing first run (no TESTS),
# <sha>.rerun that of a failing rerun (TESTS set); every first run that fails prints "first-run-marker", every rerun
# prints "rerun-marker", so a kept log can be checked for both runs. The older failing <sha> files still make a first run fail.
beh=$tmp/beh scratchd=$tmp/scratch
mkdir -p "$beh" "$scratchd" "$tmp/stubs"
cat >"$tmp/stubs/test.sh" <<EOT
sha=\$1 tests=\$2 jobs=\$3 envj=\$4
echo "call \$sha jobs=[\$jobs] env=[\$envj] tests=[\$tests]" >>$log
if [ -n "\$tests" ]; then
	echo "rerun-marker \$sha"
	[ -e "$beh/\$sha.rerun" ] || exit 0
	cat "$beh/\$sha.rerun"; exit 1
fi
for f in "$failing/\$sha" "$beh/\$sha.first"; do
	[ -e "\$f" ] || continue
	echo "first-run-marker \$sha"; cat "\$f"; exit 1
done
exit 0
EOT
printf 'test:\n\t@sh %s/stubs/test.sh "$$(git rev-parse HEAD)" "$(TESTS)" "$(TEST_JOBS)" "$$TEST_JOBS"\n' "$tmp" >"$tmp/work/Makefile"
g add -A && g commit -q -m stub2 && g push -q "$tmp/remote.git" HEAD:main 2>/dev/null
st2=$(head_w)
out=$(dep)
ok "D04-AC-4 setup: the second stub's commit is deployed in full (guard)" '[ "$(head_of)" = "$st2" ] && [ "$(callsof "$st2")" = 1 ]'
# depe: a deploy run with the scratch folders made under $scratchd; stdout in $o, stderr in $e, status in $dst.
depe() {
	TMPDIR=$scratchd sh "$deploy" "$live" >"$tmp/o.out" 2>"$tmp/o.err"; dst=$?
	o=$(cat "$tmp/o.out"); e=$(cat "$tmp/o.err")
}
tflog=$dd/test-failed.log
# scratch_gone: nothing is left in the scratch folder, and the live checkout lists no worktree but itself.
scratch_gone() { [ -z "$(ls -A "$scratchd")" ] && [ "$(git -C "$live" worktree list | wc -l)" = 1 ]; }
# logcheck <sha> <outcome> <rerun marker: yes|no>: the kept log has a header naming the sha, its version and the outcome,
# then the first run's output, then (when yes) the rerun's.
logcheck() {
	[ -f "$tflog" ] || return 1
	lc_head=$(sed '/^first-run-marker/,$d' "$tflog")
	printf '%s\n' "$lc_head" | grep -Fq -- "$1" || return 1
	printf '%s\n' "$lc_head" | grep -Fq -- "$(ver "$1")" || return 1
	printf '%s\n' "$lc_head" | grep -Fq -- "$2" || return 1
	grep -Fqx "first-run-marker $1" "$tflog" || return 1
	if [ "$3" = yes ]; then
		grep -Fqx "rerun-marker $1" "$tflog" || return 1
		[ "$(grep -n '^first-run-marker' "$tflog" | head -n 1 | cut -d: -f1)" -lt "$(grep -n '^rerun-marker' "$tflog" | head -n 1 | cut -d: -f1)" ] || return 1
	else
		! grep -q '^rerun-marker' "$tflog" || return 1
	fi
}
fa=scheduler/a.test.sh fb=scheduler/b.test.sh

# A file that fails the first run and passes alone: one rerun of the failed files only, then deployed, recorded as flaky.
mk fl1 scheduler/fl1.sh
fl1=$(head_w)
printf 'TIME 0.1 scheduler/ok.test.sh\nTIME 0.2 %s\nFAILED %s\nTIME 0.3 %s\nFAILED %s\n' "$fa" "$fa" "$fb" "$fb" >"$beh/$fl1.first"
before=$(head_of); prev_before=$before
depe
ok "D04-AC-4 a failed make test is followed by exactly one rerun (two calls in all)" '[ "$(callsof "$fl1")" = 2 ]'
ok "D04-AC-4 the first call runs the whole make test (TESTS empty)" '[ "$(grep -c "^call $fl1 .*tests=\[\]\$" "$log")" = 1 ]'
ok "D04-AC-4 the rerun is of only the failed files: TESTS=\"<files>\"" '[ "$(grep -c "^call $fl1 .*tests=\[$fa $fb\]\$" "$log")" = 1 ]'
ok "D04-AC-4 the rerun runs with TEST_JOBS=1" 'grep "^call $fl1 .*tests=\[$fa $fb\]\$" "$log" | grep -Eq "(jobs|env)=\[1\]"'
ok "D04-AC-4 the commit is deployed with the 'after a flaky make test' status line" '[ "$(head_of)" = "$fl1" ] && [ "$o" = "$(deployed_line "$before" "$fl1" " after a flaky make test: 2 file(s) failed and passed alone")" ] && [ "$dst" = 0 ]'
ok "D04-AC-4 the flaky commit is not in deploy/rejected" '[ "$(head_of)" = "$fl1" ] && ! in_rejected "$fl1"'
ok "D04-AC-4 exactly one stderr 'flaky: <sha> <files> failed in make test and passed alone; log in <path>' line" '[ "$(printf "%s\n" "$e" | grep -c "^flaky: ")" = 1 ] && printf "%s\n" "$e" | grep -Eq "^flaky: $fl1 .*scheduler/a\.test\.sh.*scheduler/b\.test\.sh.* failed in make test and passed alone; log in $tflog\$"'
ok "D04-AC-4 the flaky deploy keeps deploy/previous as a full deploy does (the commit before)" '[ "$(head_of)" = "$fl1" ] && [ "$(cat "$dd/previous" 2>/dev/null)" = "$prev_before" ]'
ok "D04-AC-4 the next run prints nothing and runs no make test" '[ "$(head_of)" = "$fl1" ] && [ -z "$(dep)" ] && [ "$(callsof "$fl1")" = 2 ]'
ok "D04-AC-6 after a flaky deploy test-failed.log has the header (sha, version, 'flaky') and both runs, and the scratch folder is gone" 'logcheck "$fl1" flaky yes && scratch_gone'
ok "D04-AC-6 a flaky deploy writes no 'make test failed for' line" '[ "$(head_of)" = "$fl1" ] && ! printf "%s\n" "$e" | grep -q "^make test failed for"'

# The same file fails the rerun too: rejected as D01 says, at most one rerun, not tried again.
mk rp1 scheduler/rp1.sh
rp1=$(head_w)
printf 'TIME 0.2 %s\nFAILED %s\n' "$fa" "$fa" >"$beh/$rp1.first"
printf 'TIME 0.2 %s\nFAILED %s\n' "$fa" "$fa" >"$beh/$rp1.rerun"
before=$(head_of)
depe
ok "D04-AC-5 a failure that repeats on the rerun: one rerun, no more (two calls)" '[ "$(callsof "$rp1")" = 2 ] && grep "^call $rp1 .*tests=\[$fa\]\$" "$log" | grep -Eq "(jobs|env)=\[1\]"'
ok "D04-AC-5 and the commit is rejected with the unchanged 'not deployed: <sha> (version <v>) fails make test' line" '[ "$(callsof "$rp1")" = 2 ] && [ "$o" = "$(rejected_line "$rp1")" ] && [ "$dst" = 1 ] && [ "$(head_of)" = "$before" ]'
ok "D04-AC-5 the sha is in deploy/rejected" '[ "$(callsof "$rp1")" = 2 ] && in_rejected "$rp1"'
ok "D04-AC-5 a repeated failure is not recorded as flaky" '[ "$(callsof "$rp1")" = 2 ] && ! printf "%s\n" "$e" | grep -q "^flaky: "'
ok "D04-AC-5 it is not tried again on the next run (no output, no call)" '[ "$(callsof "$rp1")" = 2 ] && [ -z "$(dep)" ] && [ "$(callsof "$rp1")" = 2 ]'
ok "D04-AC-6 after a rejection test-failed.log has the header (sha, version, 'rejected') and both runs, and the scratch folder is gone" 'logcheck "$rp1" rejected yes && scratch_gone'
ok "D04-AC-6 on a rejection one stderr line 'make test failed for <sha> in: <files>; log in <path>'" '[ "$(printf "%s\n" "$e" | grep -c "^make test failed for ")" = 1 ] && printf "%s\n" "$e" | grep -Eq "^make test failed for $rp1 in: .*scheduler/a\.test\.sh.*; log in $tflog\$"'

# A failed make test that names no file: rejected at once, no rerun.
mk nf1 scheduler/nf1.sh
nf1=$(head_w)
printf 'Traceback: something broke, no file named\n' >"$beh/$nf1.first"
before=$(head_of)
depe
ok "D04-AC-5 a failed make test that names no failed file is run once and not rerun" '[ "$(callsof "$nf1")" = 1 ]'
ok "D04-AC-5 and is rejected with the unchanged 'fails make test' line, the sha in deploy/rejected" '[ "$o" = "$(rejected_line "$nf1")" ] && [ "$dst" = 1 ] && [ "$(head_of)" = "$before" ] && in_rejected "$nf1" && [ "$(callsof "$nf1")" = 1 ]'
ok "D04-AC-5 it is not tried again on the next run" '[ "$(callsof "$nf1")" = 1 ] && [ -z "$(dep)" ] && [ "$(callsof "$nf1")" = 1 ]'
ok "D04-AC-6 a rejection naming no file: test-failed.log holds the header (sha, version, 'rejected') and the run's output, and the scratch folder is gone" 'logcheck "$nf1" rejected no && scratch_gone'
ok "D04-AC-6 a rejection naming no file: one stderr line 'make test failed for <sha> in: no file named; log in <path>'" '[ "$(printf "%s\n" "$e" | grep -c "^make test failed for ")" = 1 ] && printf "%s\n" "$e" | grep -Fqx "make test failed for $nf1 in: no file named; log in $tflog"'
ok "D04-AC-6 the log is a whole file: no temporary file is left in deploy/" '[ -f "$tflog" ] && [ -z "$(ls "$dd" | grep -v -E "^(previous|rejected|lock|test-failed\.log|tries|passed|plain-tries)\$")" ]'

echo
if [ "$fails" -eq 0 ]; then echo "all D04 deploy tests passed"; else echo "$fails D04 deploy test(s) FAILED"; exit 1; fi
