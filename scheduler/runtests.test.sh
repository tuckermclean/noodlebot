#!/bin/sh
# D03-AC-4: scheduler/runtests.sh runs every test file it is given, also after one fails, with
# each file's output whole; prints TIME per file, TOTAL at the end, SLOW: for a file or a total over
# TEST_FILE_BUDGET / TEST_BUDGET; exits non-zero when a file failed, and for a run over budget only
# with TEST_BUDGET_ENFORCE=1. Runs it on fake test files in a scratch folder.
#   sh scheduler/runtests.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
runner=$src/runtests.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
# has <name> <file> <egrep-pattern>: PASS when a line of the file matches.
has() { if grep -Eq -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1"; fi; }
hasnt() { if grep -Eq -- "$3" "$2" 2>/dev/null; then fail "$1"; else pass "$1"; fi; }

t=$tmp/t mk=$tmp/mk
mkdir -p "$t" "$mk" "$tmp/lp" "$tmp/out"
cat >"$t/ok.test.sh" <<'EOT'
echo "PASS: ok-ran"
touch "$MK/ok.ran"
EOT
cat >"$t/bad.test.sh" <<'EOT'
touch "$MK/bad.ran"
echo "FAIL: bad-case"
exit 1
EOT
cat >"$t/slow.test.sh" <<'EOT'
touch "$MK/slow.ran"
sleep 2
echo "PASS: slow-done"
EOT
# w1/w2: each announces itself, waits (up to 10 s) until the other has started, then writes
# 6 lines with pauses, so both are writing at the same time when the runner runs two at once.
for n in 1 2; do
	o=$([ $n = 1 ] && echo 2 || echo 1)
	cat >"$t/w$n.test.sh" <<EOT
touch "\$MK/w$n.started"
i=0
while [ ! -e "\$MK/w$o.started" ] && [ \$i -lt 100 ]; do sleep 0.1; i=\$((i + 1)); done
[ -e "\$MK/w$o.started" ] && touch "\$MK/w$n.saw-other"
j=1
while [ \$j -le 6 ]; do echo "W$n line \$j"; sleep 0.1; j=\$((j + 1)); done
echo "PASS: w$n-done"
EOT
done
# interpreter probes: loop.test.sh must run under bash, others under sh.
cat >"$tmp/lp/loop.test.sh" <<'EOT'
arr=(a b)
[[ ${#arr[@]} -eq 2 ]] && echo "PASS: loop-ran-under-bash" || echo "FAIL: loop-not-bash"
EOT
cat >"$t/probe.test.sh" <<'EOT'
echo "PROBE=${BASH_VERSION:-none}"
EOT
export MK=$mk
unset TEST_JOBS TEST_FILE_BUDGET TEST_BUDGET TEST_BUDGET_ENFORCE

# run <name> <env...> -- files: runs the runner in the background, output in out/<name>, status in out/<name>.rc.
run() {
	name=$1; shift
	envs=
	while [ "$1" != -- ]; do envs="$envs $1"; shift; done
	shift
	(
		for e in $envs; do export "${e?}"; done
		sh "$runner" "$@" >"$tmp/out/$name" 2>&1
		echo $? >"$tmp/out/$name.rc"
	) &
}
rc() { cat "$tmp/out/$1.rc" 2>/dev/null || echo 999; }

# main: sequential (TEST_JOBS=1), the failing file first, so later files prove it runs on after a failure.
run main TEST_JOBS=1 TEST_FILE_BUDGET=1 TEST_BUDGET=100 -- "$t/bad.test.sh" "$t/ok.test.sh" "$t/slow.test.sh"
# budgets: a slow file with no enforcement, with enforcement, a slow total likewise.
run fileonly TEST_FILE_BUDGET=1 TEST_BUDGET=100 -- "$t/ok.test.sh" "$t/slow.test.sh"
run fileenf TEST_FILE_BUDGET=1 TEST_BUDGET=100 TEST_BUDGET_ENFORCE=1 -- "$t/ok.test.sh" "$t/slow.test.sh"
run totonly TEST_FILE_BUDGET=100 TEST_BUDGET=1 -- "$t/ok.test.sh" "$t/slow.test.sh"
run totenf TEST_FILE_BUDGET=100 TEST_BUDGET=1 TEST_BUDGET_ENFORCE=1 -- "$t/ok.test.sh" "$t/slow.test.sh"
run fast TEST_BUDGET_ENFORCE=1 -- "$t/ok.test.sh"
run par TEST_JOBS=2 -- "$t/w1.test.sh" "$t/w2.test.sh"
run interp -- "$tmp/lp/loop.test.sh" "$t/probe.test.sh"
wait

m=$tmp/out/main
if [ -f "$runner" ]; then pass "D03-AC-4: scheduler/runtests.sh exists"; else fail "D03-AC-4: scheduler/runtests.sh exists"; fi

# every file ran, also after one failed
for f in bad ok slow; do
	if [ -e "$mk/$f.ran" ]; then pass "D03-AC-4: $f.test.sh ran (failing file first, TEST_JOBS=1)"; else fail "D03-AC-4: $f.test.sh ran (failing file first, TEST_JOBS=1)"; fi
done
has "D03-AC-4: output of the file after the failed one is printed" "$m" '^PASS: ok-ran'
has "D03-AC-4: output of the failing file is printed" "$m" '^FAIL: bad-case'
has "D03-AC-4: output of the last file is printed" "$m" '^PASS: slow-done'
[ "$(rc main)" -ne 0 ] && [ -e "$mk/bad.ran" ] && pass "D03-AC-4: exits non-zero when a file failed" || fail "D03-AC-4: exits non-zero when a file failed"

# TIME / TOTAL / SLOW
num='[0-9]+(\.[0-9]+)?'
for f in bad ok slow; do
	has "D03-AC-4: TIME <seconds> <file> for $f.test.sh" "$m" "^TIME $num .*$f\.test\.sh\$"
done
has "D03-AC-4: TOTAL <seconds> at the end" "$m" "^TOTAL $num"
if [ "$(grep -E '^TOTAL ' "$m" 2>/dev/null | wc -l)" -eq 1 ] && [ "$(tail -n 1 "$m" 2>/dev/null | cut -c1-5)" = TOTAL ]; then
	pass "D03-AC-4: TOTAL is the last line, printed once"
else fail "D03-AC-4: TOTAL is the last line, printed once"; fi
has "D03-AC-4: SLOW: <file> took <seconds>s, budget <n>s for the file over TEST_FILE_BUDGET" "$m" "^SLOW: .*slow\.test\.sh took $num"'s, budget 1s$'
hasnt "D03-AC-4: no SLOW: line for a file within its budget" "$m" '^SLOW: .*(ok|bad)\.test\.sh'
hasnt "D03-AC-4: no SLOW: total when the total is within TEST_BUDGET" "$m" '^SLOW: total'

# budgets and exit status
[ "$(rc fileonly)" -eq 0 ] && pass "D03-AC-4: all files pass, one over its budget, no TEST_BUDGET_ENFORCE: exits 0" || fail "D03-AC-4: all files pass, one over its budget, no TEST_BUDGET_ENFORCE: exits 0"
has "D03-AC-4: the over-budget file is still flagged SLOW without TEST_BUDGET_ENFORCE" "$tmp/out/fileonly" '^SLOW: .*slow\.test\.sh took'
[ "$(rc fileenf)" -ne 0 ] && [ -e "$mk/slow.ran" ] && grep -q "^TIME" "$tmp/out/fileenf" && pass "D03-AC-4: TEST_BUDGET_ENFORCE=1: a file over TEST_FILE_BUDGET exits non-zero" || fail "D03-AC-4: TEST_BUDGET_ENFORCE=1: a file over TEST_FILE_BUDGET exits non-zero"
has "D03-AC-4: SLOW: total ... when over TEST_BUDGET" "$tmp/out/totonly" '^SLOW: total'
hasnt "D03-AC-4: total over budget, files within theirs: no SLOW: line for a file" "$tmp/out/totonly" '^SLOW: [^t]'
[ "$(rc totonly)" -eq 0 ] && pass "D03-AC-4: total over TEST_BUDGET without TEST_BUDGET_ENFORCE: exits 0" || fail "D03-AC-4: total over TEST_BUDGET without TEST_BUDGET_ENFORCE: exits 0"
[ "$(rc totenf)" -ne 0 ] && grep -q "^TOTAL" "$tmp/out/totenf" && pass "D03-AC-4: TEST_BUDGET_ENFORCE=1: a total over TEST_BUDGET exits non-zero" || fail "D03-AC-4: TEST_BUDGET_ENFORCE=1: a total over TEST_BUDGET exits non-zero"
[ "$(rc fast)" -eq 0 ] && pass "D03-AC-4: passing file within budget with TEST_BUDGET_ENFORCE=1: exits 0" || fail "D03-AC-4: passing file within budget with TEST_BUDGET_ENFORCE=1: exits 0"
hasnt "D03-AC-4: default budgets: no SLOW: line for a fast file" "$tmp/out/fast" '^SLOW:'

# concurrency (TEST_JOBS=2) and whole outputs
p=$tmp/out/par
if [ -e "$mk/w1.saw-other" ] && [ -e "$mk/w2.saw-other" ]; then pass "D03-AC-4: TEST_JOBS=2 runs two files at once (each started before the other ended)"; else fail "D03-AC-4: TEST_JOBS=2 runs two files at once (each started before the other ended)"; fi
[ "$(rc par)" -eq 0 ] && pass "D03-AC-4: all files pass: exits 0" || fail "D03-AC-4: all files pass: exits 0"
for n in 1 2; do
	first=$(grep -n "^W$n line 1\$" "$p" 2>/dev/null | head -n 1 | cut -d: -f1)
	last=$(grep -n "^W$n line 6\$" "$p" 2>/dev/null | head -n 1 | cut -d: -f1)
	cnt=$(grep -c "^W$n line " "$p" 2>/dev/null)
	if [ -n "$first" ] && [ -n "$last" ] && [ "$cnt" -eq 6 ] && [ $((last - first)) -eq 5 ]; then
		pass "D03-AC-4: output of w$n.test.sh is printed whole, not interleaved"
	else fail "D03-AC-4: output of w$n.test.sh is printed whole, not interleaved"; fi
	has "D03-AC-4: w$n.test.sh output ends with its own last line" "$p" "^PASS: w$n-done"
done

# interpreter
i=$tmp/out/interp
has "D03-AC-4: loop.test.sh runs under bash" "$i" '^PASS: loop-ran-under-bash'
want=$(sh -c 'echo "PROBE=${BASH_VERSION:-none}"')
if grep -Fqx "$want" "$i" 2>/dev/null; then pass "D03-AC-4: other test files run under sh"; else fail "D03-AC-4: other test files run under sh"; fi

[ "$fails" -eq 0 ]
