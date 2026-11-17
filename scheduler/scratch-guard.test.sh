#!/bin/sh
# Test of the scratch folders of the test files (D12-AC-1, D12-AC-3).
#   sh scheduler/scratch-guard.test.sh   (make test)
# A test file whose `mktemp -d` fails leaves its variable empty, which `set -u` does not catch, and a cleanup
# built on it (`pkill -f "$tmp/"`, `rm -rf "$tmp"`) can then signal every process or delete the checkout. So:
#  - D12-AC-1: every line of a file in the Makefile's TESTS or of testdata/lib/*.sh that assigns $(mktemp -d ...)
#    to a variable is `<var>=$(mktemp -d ...) && [ -d "$<var>" ] || exit 1`;
#  - D12-AC-3: in a user, pid and mount namespace of its own (the driver is its pid 1, every mount but the
#    scratch folder remounted read-only) every file of TESTS, run with a TMPDIR that cannot be made, stops within
#    5 s with a non-zero status, and a sentinel the driver started gets no signal. No test file ever runs
#    outside that namespace: where it is refused, or the read-only check fails, no file runs and the case skips.
# The records of the namespace run are read here, after the namespace has ended.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
root=$(dirname "$src")
. "$src/testdata/lib/common.sh"
unset TMUX USAGE_7D_MARGIN NOODLEBOT_DATA NOODLEBOT_VERSION
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT

# The files of the Makefile's TESTS that exist (a name listed there without a file is left out).
tests=$(sed -n '/^TESTS *=/,/[^\\]$/p' "$root/Makefile" 2>/dev/null | tr -d '\\' | tr -s ' \t' '\n' | grep '\.test\.sh$')
if [ -z "$tests" ]; then
	fail "D12-AC-1:the Makefile's TESTS list could not be read"
fi

# scan <file>...: prints file:line for each line that assigns $(mktemp -d ...) to a variable and is not
# `<var>=$(mktemp -d ...) && [ -d "$<var>" ] || exit 1`.
scan() {
	for _f in "$@"; do
		[ -f "$_f" ] || continue
		grep -nE '(^|[^A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*=\$\(mktemp -d' "$_f" 2>/dev/null | while IFS= read -r _l; do
			_n=${_l%%:*}
			_t=${_l#*:}
			_t=${_t#"${_t%%[![:space:]]*}"}
			_v=$(printf '%s\n' "$_t" | sed -E 's/.*(^|[^A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)=\$\(mktemp -d.*/\2/')
			ok_=no
			case $_t in
			"$_v=\$(mktemp -d"*") && [ -d \"\$$_v\" ] || exit 1") ok_=yes ;;
			esac
			[ "$ok_" = yes ] || echo "$_f:$_n"
		done
	done
}

echo "# D12-AC-1: every assignment of \$(mktemp -d ...) is guarded"
fx=$tmp/fixture
mkdir -p "$fx"
# the fixture lines are built from parts, so that this file holds no such assignment itself
D='$' M='mktemp -d'
{
	echo "# comment: $M is not an assignment"
	echo "set -u"
	echo "tmp=$D($M)"
	echo "echo \"reviewer cd \\$D($M) && echo hi\""
} >"$fx/unguarded.sh"
{
	echo "set -u"
	echo "tmp=$D($M) && [ -d \"${D}tmp\" ] || exit 1"
	printf '\tbase=%s(%s "%s/pidns.XXXXXX") && [ -d "%sbase" ] || exit 1\n' "$D" "$M" '$x' "$D"
} >"$fx/guarded.sh"
echo "tmp=$D($M) || exit 1" >"$fx/exitonly.sh"
got=$(scan "$fx/unguarded.sh")
[ "$got" = "$fx/unguarded.sh:3" ] && pass "D12-AC-1:a fixture file with one unguarded line is reported by file:line" || fail "D12-AC-1:a fixture file with one unguarded line is reported by file:line (got: ${got:-nothing})"
got=$(scan "$fx/guarded.sh")
[ -z "$got" ] && pass "D12-AC-1:guarded lines are not reported" || fail "D12-AC-1:guarded lines are not reported (got: $got)"
got=$(scan "$fx/exitonly.sh")
[ "$got" = "$fx/exitonly.sh:1" ] && pass "D12-AC-1:a line with only || exit 1 (no directory check) is reported" || fail "D12-AC-1:a line with only || exit 1 (no directory check) is reported (got: ${got:-nothing})"
got=$(scan "$fx/nonexistent.sh")
[ -z "$got" ] && pass "D12-AC-1:a listed file that does not exist is left out" || fail "D12-AC-1:a listed file that does not exist is left out"

files=""
for t in $tests; do files="$files $root/$t"; done
for l in "$src"/testdata/lib/*.sh; do files="$files $l"; done
# shellcheck disable=SC2086
bad=$(scan $files)
if [ -z "$bad" ]; then
	pass "D12-AC-1:every mktemp -d assignment in the TESTS files and testdata/lib/*.sh is guarded"
else
	for b in $bad; do
		fail "D12-AC-1:unguarded mktemp -d line ${b#"$root"/}"
	done
fi

echo "# D12-AC-3: every test file stops at once when its TMPDIR cannot be made, and signals nothing outside"
if ! timeout 20 unshare --user --map-root-user --pid --fork --kill-child --mount-proc sh -c 'test -r /proc/self/status && ! test -r /proc/1/status.nonexistent' >/dev/null 2>&1; then
	pass "D12-AC-3: unshare --user --map-root-user --pid --fork --mount-proc is refused here; the namespace case is skipped (no test file runs)"
else
	rec=$tmp/rec
	mkdir -p "$rec"
	: >"$tmp/afile"
	for t in $tests; do
		case ${t##*/} in scratch-guard.test.sh) continue ;; esac
		[ -f "$root/$t" ] && echo "$root/$t"
	done >"$tmp/files"
	cat >"$tmp/sentinel.sh" <<'EOT'
# $1: records folder. A shell whose command line has a "/": records each TERM, HUP or INT it gets.
trap 'echo TERM >>"$1/sig"' TERM
trap 'echo HUP >>"$1/sig"' HUP
trap 'echo INT >>"$1/sig"' INT
: >"$1/sentinel.up"
while :; do sleep 0.2; done
EOT
	cat >"$tmp/driver.sh" <<'EOT'
# The namespace's pid 1. $1 scratch, $2 checkout, $3 real HOME, $4 real TMPDIR. No trap for TERM, HUP or INT.
s=$1 co=$2 rhome=$3 rtmp=$4
rec=$s/rec
mount --bind "$s" "$s" 2>/dev/null || { echo nobind >"$rec/state"; exit 0; }
while IFS=' ' read -r _a _b _c _d mp _rest; do
	mp=$(printf '%s' "$mp" | sed 's/\\040/ /g')
	[ "$mp" = "$s" ] && continue
	mount -o remount,bind,ro "$mp" >/dev/null 2>&1
done </proc/self/mountinfo
for d in "$co" "$rhome" "$rtmp"; do
	if touch "$d/.d12-probe" 2>/dev/null; then
		rm -f "$d/.d12-probe"
		echo "writable $d" >"$rec/state"
		exit 0
	fi
done
touch "$s/.w" 2>/dev/null || { echo scratch-readonly >"$rec/state"; exit 0; }
echo ready >"$rec/state"
HOME=$s; export HOME
cd "$s" || exit 0
sh "$s/sentinel.sh" "$rec" >/dev/null 2>&1 </dev/null &
spid=$!
i=0
while [ ! -e "$rec/sentinel.up" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done

alive() {
	{ read -r _l <"/proc/$1/stat"; } 2>/dev/null || return 1
	_s=${_l##*) }
	[ "${_s%% *}" != Z ]
}
# the clock is read with builtins only: a file that signals every process cannot stop it
nowms() {
	read -r _up _ </proc/uptime 2>/dev/null || return 0
	_c=${_up%.*}${_up#*.}
	case $_c in '' | *[!0-9]*) ;; *) last=$((_c * 10)) ;; esac
}
# finish <slot> <status or empty>: records the file's time and status, stops what is left of its session.
finish() {
	eval "_p=\$p_$1 _n=\$n_$1 _t0=\$t0_$1"
	nowms
	echo "$((last - _t0))" >"$rec/ms.$_n"
	case $_p in '' | *[!0-9]*) _p= ;; esac
	if [ -n "$_p" ] && [ "$2" = timeout ]; then
		# as the runner stops a file: TERM first, so that an EXIT trap runs, KILL when it does not end
		kill -s TERM -- "-$_p" 2>/dev/null
		_i=0
		while alive "$_p" && [ "$_i" -lt 20 ]; do sleep 0.1; _i=$((_i + 1)); done
	fi
	[ -n "$_p" ] && kill -s KILL -- "-$_p" 2>/dev/null
	_rc=1
	if [ -n "$_p" ]; then
		wait "$_p"
		_rc=$?
	fi
	[ -n "$2" ] && _rc=$2
	echo "$_rc" >"$rec/rc.$_n"
}
# The driver itself starts, watches and ends every file (nothing a file signals can stop a watcher).
total=0
while IFS= read -r _f; do
	total=$((total + 1))
	eval "f_$total=\$_f"
done <"$s/files"
next=1 running= last=0
while [ "$next" -le "$total" ] || [ -n "$running" ]; do
	set -- $running
	while [ "$next" -le "$total" ] && [ "$#" -lt 8 ]; do
		eval "f=\$f_$next"
		sh_=sh
		case ${f##*/} in loop.test.sh) sh_=bash ;; esac
		nowms
		env -u TMUX -u USAGE_7D_MARGIN -u NOODLEBOT_DATA -u NOODLEBOT_VERSION TMPDIR="$s/afile/missing" HOME="$s" \
			setsid "$sh_" "$f" >"$rec/out.$next" 2>&1 </dev/null &
		eval "p_$next=$! n_$next=$next t0_$next=$last"
		running="$running $next"
		next=$((next + 1))
		set -- $running
	done
	left=
	for k in $running; do
		eval "_p=\$p_$k _t0=\$t0_$k"
		nowms
		if ! alive "$_p"; then
			finish "$k" ""
		elif [ $((last - _t0)) -gt 5000 ]; then
			finish "$k" timeout
		else
			left="$left $k"
		fi
	done
	running=$left
	sleep 0.1
done
if alive "$spid"; then echo alive >"$rec/sentinel.state"; else echo dead >"$rec/sentinel.state"; fi
echo done >"$rec/done"
EOT
	rtmp=${TMPDIR:-/tmp}
	timeout -k 5 110 unshare --user --map-root-user --pid --fork --kill-child --mount-proc \
		sh "$tmp/driver.sh" "$tmp" "$root" "${HOME:-/nonexistent}" "$rtmp" >"$tmp/ns.out" 2>&1 </dev/null
	state=$(cat "$rec/state" 2>/dev/null)
	case $state in
	ready)
		if [ -f "$rec/done" ]; then
			pass "D12-AC-3:the driver ran every file to its end"
		else
			fail "D12-AC-3:the driver ran every file to its end (it ended early; see $tmp/ns.out)"
		fi
		n=0
		while IFS= read -r f; do
			n=$((n + 1))
			name=${f#"$root"/}
			rc=$(cat "$rec/rc.$n" 2>/dev/null)
			ms=$(cat "$rec/ms.$n" 2>/dev/null)
			if [ -z "$rc" ]; then
				fail "D12-AC-3:$name: no record of its run (the driver was stopped before it ended)"
			elif [ "$rc" = timeout ]; then
				fail "D12-AC-3:$name: still running after 5 s with an unmakeable TMPDIR"
			elif [ "$rc" = 0 ]; then
				fail "D12-AC-3:$name: exited 0 with an unmakeable TMPDIR"
			elif grep -q '^PASS:' "$rec/out.$n" 2>/dev/null; then
				fail "D12-AC-3:$name: printed a PASS: line with an unmakeable TMPDIR"
			elif [ "${ms:-99999}" -gt 5000 ]; then
				fail "D12-AC-3:$name: took ${ms} ms, over 5 s"
			else
				pass "D12-AC-3:$name: stops at once (status $rc, ${ms} ms)"
			fi
		done <"$tmp/files"
		sst=$(cat "$rec/sentinel.state" 2>/dev/null)
		if [ "$sst" = alive ]; then
			pass "D12-AC-3:the sentinel (command line with a /) is still running after the last file"
		else
			fail "D12-AC-3:the sentinel (command line with a /) is still running after the last file (${sst:-no record})"
		fi
		if [ -s "$rec/sig" ]; then
			fail "D12-AC-3:the sentinel recorded no TERM, HUP or INT (recorded: $(tr '\n' ' ' <"$rec/sig"))"
		else
			pass "D12-AC-3:the sentinel recorded no TERM, HUP or INT"
		fi
		;;
	*)
		pass "D12-AC-3: the namespace could not be made read-only here (${state:-driver did not start}); the namespace case is skipped, no test file ran"
		;;
	esac
fi

[ "$fails" -eq 0 ]
