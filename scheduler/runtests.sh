#!/bin/sh
# runtests.sh <test file>...       run the test files, in parallel, and time them
#
# Runs every file given (also after one fails) with bash when its basename is loop.test.sh and with
# sh otherwise, up to $TEST_JOBS at once (default: the number of CPUs, else 1). Each file's output is
# captured and printed whole when the file ends, so outputs never interleave. After each file prints
# "TIME <seconds> <file>", and "SLOW: <file> took <s>s, budget <n>s" when it took longer than
# $TEST_FILE_BUDGET seconds (default 30). At the end prints "SLOW: total took <s>s, budget <n>s" when
# the whole run took longer than $TEST_BUDGET seconds (default 120), and last "TOTAL <seconds>".
# Exits non-zero when any file failed; with TEST_BUDGET_ENFORCE=1 also when a file or the total is
# over its budget (without it time never fails the run).
set -u
jobs=${TEST_JOBS:-$(nproc 2>/dev/null || echo 1)}
fbudget=${TEST_FILE_BUDGET:-30}
tbudget=${TEST_BUDGET:-120}
enforce=${TEST_BUDGET_ENFORCE:-0}
[ "$jobs" -ge 1 ] 2>/dev/null || jobs=1
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

now() { date +%s.%N; }
# over <seconds> <budget>: true when seconds > budget
over() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }

# One worker per file; it records its output, status and times, and last of all the .done marker.
work() {
	case $(basename "$2") in loop.test.sh) sh=bash ;; *) sh=sh ;; esac
	s=$(now)
	"$sh" "$2" >"$tmp/$1.out" 2>&1 </dev/null
	echo $? >"$tmp/$1.rc"
	elapsed "$s" "$(now)" >"$tmp/$1.time"
	: >"$tmp/$1.done"
}

n=$#
start=$(now)
failed=0
slow=0
next=1 # next file to start
shown=0
running=""
while [ "$shown" -lt "$n" ]; do
	if [ "$next" -le "$n" ] && [ "$(echo $running | wc -w)" -lt "$jobs" ]; then
		eval "f=\${$next}"
		work "$next" "$f" &
		running="$running $next"
		next=$((next + 1))
		continue
	fi
	progressed=0
	for i in $running; do
		[ -e "$tmp/$i.done" ] || continue
		eval "f=\${$i}"
		cat "$tmp/$i.out"
		t=$(cat "$tmp/$i.time")
		echo "TIME $t $f"
		[ "$(cat "$tmp/$i.rc")" -eq 0 ] || failed=1
		if over "$t" "$fbudget"; then echo "SLOW: $f took ${t}s, budget ${fbudget}s"; slow=1; fi
		running=$(echo $running | tr ' ' '\n' | grep -vx "$i" | tr '\n' ' ')
		shown=$((shown + 1))
		progressed=1
	done
	[ "$progressed" = 1 ] || sleep 0.1
done
wait
total=$(elapsed "$start" "$(now)")
if over "$total" "$tbudget"; then echo "SLOW: total took ${total}s, budget ${tbudget}s"; slow=1; fi
echo "TOTAL $total"
[ "$failed" -eq 0 ] || exit 1
[ "$enforce" != 1 ] || [ "$slow" -eq 0 ] || exit 1
exit 0
