# Shared by the scheduler's test files (source it with: . "$src/testdata/lib/common.sh").
# POSIX sh: usable from the files the runner runs with sh as well as from bash ones.
#
#   pass <name> / fail <name>      print "PASS: <name>" / "FAIL: <name>" (fail counts in $fails)
#   wait_until <seconds> <cmd...>   run the command (a shell function works) every 0.1 s until it
#                                   succeeds (status 0) or the wall-clock time is over (status 1). The wait is a
#                                   condition, never a fixed sleep: use it where a test used to sleep.
#   wait_file / wait_line           wait_until for a file that exists, a file that has a matching line.
# A fixed sleep stays in a test only where nothing can be observed, with a comment saying why.
fails=${fails:-0}
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
wait_until() {
	_wu_end=$(($(date +%s%N) + $1 * 1000000000)); shift
	until "$@"; do
		[ "$(date +%s%N)" -lt "$_wu_end" ] || return 1
		sleep 0.1
	done
}
wait_file() { wait_until "$1" test -e "$2"; }
_wu_line() { grep -qE -- "$1" "$2" 2>/dev/null; }
wait_line() { wait_until "$1" _wu_line "$2" "$3"; }
