#!/bin/sh
# Runs the given test files (default: every tests/t_*.sh) and prints one line per test, "ok   <name>" or
# "FAIL <name>", then a summary line that names no test. Exits non-zero when a test fails.
cd "$(dirname "$0")/.." || exit 2
if [ $# -eq 0 ]; then set -- tests/t_*.sh; fi
pass=0
fail=0
for t in "$@"; do
	name=$(basename "$t" .sh)
	if sh "$t" >/dev/null 2>&1; then
		echo "ok   $name"
		pass=$((pass + 1))
	else
		echo "FAIL $name"
		fail=$((fail + 1))
	fi
done
echo "summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
