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
tmp=$(cd "$tmp" && pwd -P) && [ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
# `sh scheduler/scratch-guard.test.sh late` runs the late-signal case (D14-AC-5) alone.
late=
[ "${1:-}" = late ] && late=1

# The files of the Makefile's TESTS that exist (a name listed there without a file is left out).
tests=$(sed -n '/^TESTS *=/,/[^\\]$/p' "$root/Makefile" 2>/dev/null | tr -d '\\' | tr -s ' \t' '\n' | grep '\.test\.sh$')
if [ -z "$tests" ]; then
	fail "D12-AC-1:the Makefile's TESTS list could not be read"
fi

# scan <file>...: prints file:line for each line that assigns a mktemp command substitution with the -d form
# to a variable and is not, as a whole, `<var>=$(mktemp ...) && [ -d "$<var>" ] || exit 1`.
scan() {
	# (A) D12's rule, as D12 wrote it (see scan_d12): its candidate grep, its variable and its accepted form
	_d12='(^|[^A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*=\$\(mktemp -d'
	# (B) the wider rule: the -d form of mktemp (-d alone or among short options, --di ... --directory) followed by
	# any character that is not a letter or digit, or the end of the line
	_df='(-[A-Za-z]*d[A-Za-z]*|--di(r(e(c(t(o(r(y)?)?)?)?)?)?)?)'
	# mktemp's arguments in an accepted line: no operator, parenthesis, backtick or backslash
	_a='[^;&|()`\\]*'
	for _f in "$@"; do
		[ -f "$_f" ] || continue
		grep -nE '(^|[^A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*="?(\$\(|`)[[:space:]]*mktemp[[:space:]]|'"$_d12" "$_f" 2>/dev/null | while IFS= read -r _l; do
			_n=${_l%%:*}
			_t=${_l#*:}
			_t=${_t#"${_t%%[![:space:]]*}"}
			_rep=no
			# (A): a line D12's scan reports is reported, but for `local ` or `export ` followed by exactly a line
			# D12's check accepts (the one widening D14-AC-3 allows)
			if printf '%s\n' "$_t" | grep -qE "$_d12"; then
				_v=$(printf '%s\n' "$_t" | sed -E 's/.*(^|[^A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)=\$\(mktemp -d.*/\2/')
				case $_t in
				"$_v=\$(mktemp -d"*") && [ -d \"\$$_v\" ] || exit 1") ;;
				*) _rep=yes ;;
				esac
				case $_t in
				"local "* | "export "*)
					_r=${_t#* }
					_v=$(printf '%s\n' "$_r" | sed -E 's/.*(^|[^A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)=\$\(mktemp -d.*/\2/')
					case $_r in
					"$_v=\$(mktemp -d"*") && [ -d \"\$$_v\" ] || exit 1") _rep=no ;;
					esac
					;;
				esac
			fi
			# (B): a line with the -d form (one level of $( ... ) in an option value left out) is reported unless
			# the whole line, after an optional `local ` or `export `, is
			# <var>=<open>mktemp <args><close> && [ -d "$<var>" ] || exit 1
			# with <open><close> one of $( ), "$( )" or backticks, and in the $( forms at most one "$( ... )" in <args>
			if [ "$_rep" = no ]; then
				_s=$(printf '%s\n' "$_t" | sed -E 's/([[:space:]]"?)\$\([^()]*\)/\1/g')
				if printf '%s\n' "$_s" | grep -qE "mktemp.*[[:space:]]$_df([^A-Za-z0-9]|\$)"; then
					_rep=yes
					case $_t in
					"local "* | "export "*) _r=${_t#* } ;;
					*) _r=$_t ;;
					esac
					_v=${_r%%=*}
					case $_v in
					'' | [!A-Za-z_]* | *[!A-Za-z0-9_]*) ;;
					*)
						_m="[[:space:]]*mktemp[[:space:]]"
						_x="$_a(\"\\\$\\($_a\\)\"$_a)?"
						_g=" && \\[ -d \"\\\$$_v\" \\] \\|\\| exit 1\$"
						if printf '%s\n' "$_r" | grep -qE "^$_v=(\\\$\\($_m$_x\\)|\"\\\$\\($_m$_x\\)\"|\`$_m$_a\`)$_g"; then
							_rep=no
						fi
						;;
					esac
				fi
			fi
			[ "$_rep" = no ] || echo "$_f:$_n"
		done
	done
}

if [ -z "$late" ]; then
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

echo "# D14-AC-3: the scan sees every form of mktemp -d, with or without local or export"
BT=$(printf '\140')
# fxform <form> <prefix> <open> <command> <close>: a fixture line <prefix>tmp=<open><command><close>, alone and with D12's guard
fxform() {
	_u="$2tmp=$3$4$5"
	printf '%s\n' "set -u" "$_u" >"$fx/u-$1.sh"
	printf '%s\n' "set -u" "$_u && [ -d \"${D}tmp\" ] || exit 1" >"$fx/g-$1.sh"
	got=$(scan "$fx/u-$1.sh")
	[ "$got" = "$fx/u-$1.sh:2" ] && pass "D14-AC-3:an unguarded $1 line is reported by file:line" || fail "D14-AC-3:an unguarded $1 line is reported by file:line (got: ${got:-nothing})"
	got=$(scan "$fx/g-$1.sh")
	[ -z "$got" ] && pass "D14-AC-3:the guarded $1 line is not reported" || fail "D14-AC-3:the guarded $1 line is not reported (got: $got)"
}
fxform quoted '' "\"$D(" "$M" ')"'
fxform backtick '' "$BT" "$M" "$BT"
fxform spaced '' "$D( " "$M" ' )'
fxform directory '' "$D(" 'mktemp --directory' ')'
fxform d-after-options '' "$D(" 'mktemp -p "$x" -d' ')'
fxform combined-qd '' "$D(" 'mktemp -qd' ')'
fxform combined-td '' "$D(" 'mktemp -td x' ')'
fxform local 'local ' "$D(" "$M" ')'
fxform export 'export ' "$D(" "$M" ')'
fxform local-quoted 'local ' "\"$D(" "$M" ')"'
fxform export-backtick 'export ' "$BT" "$M" "$BT"
# fxfirst <name> <line>: a fixture line whose first assignment is not the guarded mktemp assignment is still reported, as D12 reported it
fxfirst() {
	printf '%s\n' "set -u" "$2" >"$fx/f-$1.sh"
	got=$(scan "$fx/f-$1.sh")
	[ "$got" = "$fx/f-$1.sh:2" ] && pass "D14-AC-3:a line whose first assignment is not the guarded mktemp one ($1) is reported by file:line" || fail "D14-AC-3:a line whose first assignment is not the guarded mktemp one ($1) is reported by file:line (got: ${got:-nothing})"
}
_g=" && [ -d \"${D}tmp\" ] || exit 1"
fxfirst plain-first "tmp=x; u=$D($M); tmp=$D($M)$_g"
fxfirst local-first "local tmp=x; u=$D($M); tmp=$D($M)$_g"
fxfirst export-first "export tmp=x; u=$D($M); tmp=$D($M)$_g"
fxfirst other-var-first "u=$D($M) && tmp=$D($M)$_g"
fxfirst local-other-var-first "local u=$D($M) && tmp=$D($M)$_g"
fxform pwd-option '' "$D(" "mktemp -p \"$D(pwd)\" -d" ')'
fxform dir-abbrev '' "$D(" 'mktemp --dir' ')'
fxform di-abbrev '' "$D(" 'mktemp --di' ')'
# D14-AC-3 loosens no check: for every corpus line D12's scan (kept below as the oracle scan_d12, verbatim from
# D12's commit 906abb5, renamed) reports, the scan reports it too.
scan_d12() {
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
cf=$fx/corpus.sh
_o="$D($M)"
_q="\"$D($M)\""
_b="$BT$M$BT"
_h="$D(mktemp -u)"
{
	echo "# corpus"
	echo "tmp=$D(mktemp -u); u=$_o; tmp=$_o$_g"
	echo "tmp=\"$D(mktemp -u)\"; u=$_o; tmp=$_o$_g"
	echo "tmp=$D(mktemp -p x); u=$_o; tmp=$_o$_g"
	echo "tmp=$_o; u=$_o; tmp=$D(mktemp -u)$_g"
	echo "tmp=$_h; u=$_o; tmp=$_h$_g"
	echo "tmp=$_o $BT""x$BT$_g"
	echo "tmp=x; u=$_o; tmp=$_o$_g"
	echo "local tmp=x; u=$_o; tmp=$_o$_g"
	echo "export tmp=x; u=$_o; tmp=$_o$_g"
	echo "u=$_o && tmp=$_o$_g"
	echo "local u=$_o && tmp=$_o$_g"
	echo "export u=$_o; tmp=$_o$_g"
	echo "local tmp=$_o; u=$_o; tmp=$_h$_g"
	echo "tmp=$_q; u=$_o; tmp=$_q$_g"
	echo "tmp=$_q$_g; u=$_o"
	echo "tmp=$_b; u=$_o; tmp=$_b$_g"
	echo "tmp=$_o || true"
	echo "tmp=$_o; [ -d \"${D}tmp\" ] || exit 1"
	echo "tmp=$_o && [ -d \"${D}u\" ] || exit 1"
	echo "tmp=$_o && [ -d \"${D}tmp\" ] || exit 1; u=$_o"
	echo "tmp=$_o && [ -d \"${D}tmp\" ] || exit 1 && u=$_o"
	echo "tmp=$_o && [ -d \"${D}tmp\" ] || exit 1; echo done"
	echo "tmp=$_o && [ -d \"${D}tmp\" ]"
	echo "tmp=$_o && [ -d \"${D}tmp\" ] || exit 2"
	echo "tmp=$_o$_g # trailing comment"
	echo "# tmp=$_o"
	echo "echo \"$D(mktemp -d) tmp=$_o\""
	echo "x=1 tmp=$_o$_g"
	echo "tmp=$_o tmp2=$_o$_g"
	echo "tmp=$_o && u=$_o && [ -d \"${D}tmp\" ] || exit 1"
	echo "tmp=$_o || u=$_o && [ -d \"${D}tmp\" ] || exit 1"
	echo "tmp=$_o; tmp=$_o$_g"
	echo "tmp=$_o;tmp=$_o$_g"
	echo "tmp=$D(mktemp -d -p \"$D(pwd)\")$_g"
	echo "tmp=$D(mktemp --dir)$_g"
	echo "tmp=$D(mktemp -p \"$D(pwd)\" -d)$_g"
	echo "tmp=$D(cd x && mktemp -d)$_g"
	echo "tmp=$_o$_g && echo ok"
	echo "tmp=$_o$_g || true"
	echo "	tmp=$_o$_g"
	echo "if true; then tmp=$_o$_g; fi"
	echo "tmp=$_o$_g"
	echo "local tmp=$_q$_g"
	echo "export tmp=$_b$_g"
} >"$cf"
d12=$(scan_d12 "$cf")
head=$(scan "$cf")
missed=
nd12=0
for r in $d12; do
	nd12=$((nd12 + 1))
	case "
$head
" in
	*"
$r
"*) ;;
	*) missed="$missed ${r##*:}" ;;
	esac
done
ncorp=$(wc -l <"$cf")
if [ "$ncorp" -lt 25 ] || [ "$nd12" -lt 15 ]; then
	fail "D14-AC-3:the corpus holds at least 25 lines, and D12's scan reports at least 15 of them (lines: $ncorp, reported by D12: $nd12)"
elif [ -z "$missed" ]; then
	pass "D14-AC-3:the scan reports every one of the $nd12 corpus lines D12's scan reports (of $ncorp)"
else
	fail "D14-AC-3:the scan reports every corpus line D12's scan reports (missed corpus lines:$missed)"
	for m in $missed; do
		fail "D14-AC-3:the scan reports corpus line $m, as D12's did: $(sed -n "${m}p" "$cf")"
	done
fi

# D14-AC-3, second corpus: the scan reports every line D12's scan reports whatever follows -d (or -qd, --directory):
# an operator, a redirection, a quote, a backslash, a nested substitution; the one exception is a guarded
# local/export line of D12's exact accepted form (the allowed widening).
echo "# D14-AC-3: the second corpus (what follows -d is any character)"
fxunguarded() {
	printf '%s\n' "set -u" "$2" >"$fx/x-$1.sh"
	got=$(scan "$fx/x-$1.sh")
	[ "$got" = "$fx/x-$1.sh:2" ] && pass "D14-AC-3:an unguarded $1 line is reported by file:line" || fail "D14-AC-3:an unguarded $1 line is reported by file:line (got: ${got:-nothing})"
}
for _p in '' 'local ' 'export '; do
	_k=${_p%% *}
	fxunguarded "qd-exit${_k:+-$_k}" "${_p}tmp=$D(mktemp -qd||exit 1)"
	fxunguarded "directory-semicolon${_k:+-$_k}" "${_p}tmp=$D(mktemp --directory;)"
done
c2=$fx/corpus2.sh
_P="tmp=$D(mktemp"
_G=" && [ -d \"${D}tmp\" ] || exit 1"
_BQ="$BT"
{
	echo "# corpus2"
	echo "$_P -d||exit 1)"
	echo "$_P -d||true)"
	echo "$_P -d;)"
	echo "$_P -d&&:)"
	echo "$_P -d<&-)"
	echo "$_P -d>/dev/null)"
	echo "$_P -d'')"
	echo "$_P -d.)"
	echo "$_P -d2>/dev/null)"
	echo "$_P -d\\ )"
	echo "$_P -qd||exit 1)"
	echo "$_P --directory;)"
	echo "local $_P -qd||exit 1)"
	echo "export $_P -qd||exit 1)"
	echo "local $_P --directory;)"
	echo "export $_P --directory;)"
	echo "tmp=${_BQ}mktemp -d $D(u=$D(mktemp -d))${_BQ}$_G"
	echo "$_P -d|cat)"
	echo "$_P -d|)"
	echo "$_P -d&)"
	echo "$_P -d>x)"
	echo "$_P -d<x)"
	echo "$_P -d\"\")"
	echo "$_P -d'x')"
	echo "$_P -d\;)"
	echo "$_P -d#)"
	echo "$_P -d})"
	echo "$_P -d=)"
	echo "$_P -d -p x||exit 1)"
	echo "$_P -d||exit 1)$_G"
	echo "$_P -d;)$_G"
	echo "local $_P -d;)$_G"
	echo "export $_P -d>/dev/null)$_G"
	echo "local $_P -d)$_G"
	echo "export $_P -qd||exit 1)$_G"
	echo "	$_P -d||exit 1)"
	echo "$_P -d	)"
	echo "$_P -d	;)"
	echo "	local $_P -d;)"
	echo "export $_P -d>/dev/null)"
	echo "tmp=${_BQ}mktemp -d||exit 1${_BQ}"
	echo "tmp=${_BQ}mktemp -d;${_BQ}$_G"
	echo "tmp=${_BQ}mktemp -d $D(mktemp -d)${_BQ}$_G"
	echo "tmp=${_BQ}mktemp -d \\${_BQ}mktemp -d\\${_BQ}${_BQ}$_G"
	echo "tmp=${_BQ}mktemp -d $D(u=$D(mktemp -d))${_BQ}"
	echo "$_P -d)&&[ -d \"${D}tmp\" ]||exit 1"
	echo "$_P -d) && [ -d \"${D}tmp\" ] || exit 1 | cat"
	echo "$_P -d||exit 1) && [ -d \"${D}tmp\" ] || exit 1  "
	echo "$_P -d --tmpdir=x||exit 1)"
	echo "$_P -d ||exit 1)"
	echo "$_P -d   ;)"
	echo "x=1 $_P -d||exit 1)"
	echo "$_P -d||exit 1); u=$D(mktemp -d)"
	echo "$_P -d$D(u=$D(mktemp -d)))"
	echo "$_P -d\"$D(pwd)\"||exit 1)"
	echo "$_P -d)$D(mktemp -d)$_G"
	echo "$_P -d \"$D(u=$D(mktemp -d))\")$_G"
	echo "$_P -dp||exit 1)"
	echo "tmp=\"$D(mktemp -d||exit 1)\""
	echo "tmp=\"$D(mktemp -d;)\"$_G"
	echo "local tmp=\"$D(mktemp -d;)\""
	echo "tmp=$D(mktemp -d)"
} >"$c2"
d12=$(scan_d12 "$c2")
head=$(scan "$c2")
missed=
nd12=0
for r in $d12; do
	nd12=$((nd12 + 1))
	_ln=$(sed -n "${r##*:}p" "$c2")
	_ln=${_ln#"${_ln%%[![:space:]]*}"}
	_ex=no
	case $_ln in
	"local "* | "export "*)
		_rest=${_ln#local }
		_rest=${_rest#export }
		_vv=${_rest%%=*}
		case $_rest in
		"$_vv=\$(mktemp -d"*") && [ -d \"\$$_vv\" ] || exit 1") _ex=yes ;;
		esac
		;;
	esac
	[ "$_ex" = yes ] && continue
	case "
$head
" in
	*"
$r
"*) ;;
	*) missed="$missed ${r##*:}" ;;
	esac
done
ncorp=$(wc -l <"$c2")
if [ "$ncorp" -lt 60 ] || [ "$nd12" -lt 40 ]; then
	fail "D14-AC-3:corpus2 holds at least 60 lines, and D12's scan reports at least 40 of them (lines: $ncorp, reported by D12: $nd12)"
elif [ -z "$missed" ]; then
	pass "D14-AC-3:the scan reports every corpus2 line D12's scan reports (D12 reports $nd12 of $ncorp)"
else
	fail "D14-AC-3:the scan reports every corpus2 line D12's scan reports (missed corpus2 lines:$missed)"
	for m in $missed; do
		fail "D14-AC-3:the scan reports corpus2 line $m, as D12's did: $(sed -n "${m}p" "$c2")"
	done
fi

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
[ -z "$bad" ] && pass "D14-AC-3:no line of the TESTS files or testdata/lib/*.sh assigns mktemp -d of any form unguarded" || fail "D14-AC-3:no line of the TESTS files or testdata/lib/*.sh assigns mktemp -d of any form unguarded"
fi

echo "# D12-AC-3: every test file stops at once when its TMPDIR cannot be made, and signals nothing outside"
if ! timeout 20 unshare --user --map-root-user --net --pid --fork --kill-child --mount-proc sh -c 'test -r /proc/self/status && ! test -r /proc/1/status.nonexistent' >/dev/null 2>&1; then
	pass "D12-AC-3: unshare --user --map-root-user --net --pid --fork --mount-proc is refused here (the availability probe failed); the namespace case is skipped (no test file runs)"
else
	rec=$tmp/rec
	mkdir -p "$rec"
	: >"$tmp/afile"
	for t in $tests; do
		case ${t##*/} in scratch-guard.test.sh) continue ;; esac
		[ -f "$root/$t" ] && echo "$root/$t"
	done >"$tmp/files"
	cat >"$tmp/sentinel.sh" <<'EOT'
case ${D12_SENTINEL:-} in '') D12_SENTINEL=1 exec env --default-signal=INT,HUP,TERM sh "$0" "$@" ;; esac
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
echo "the scratch folder was read-only after the remount, or the driver stopped early" >"$rec/state"
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
nbrt=$(env | grep -m 1 '^NBRT_[0-9][0-9]*=')
while [ "$next" -le "$total" ] || [ -n "$running" ]; do
	set -- $running
	while [ "$next" -le "$total" ] && [ "$#" -lt 8 ]; do
		eval "f=\$f_$next"
		sh_=sh
		case ${f##*/} in loop.test.sh) sh_=bash ;; esac
		nowms
		env -i PATH="$PATH" HOME="$s" TMPDIR="$s/afile/missing" ${nbrt:+"$nbrt"} \
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
# a signal sent as the last file ended is recorded by the sentinel when its tick (sleep 0.2) ends
sleep 0.6
if alive "$spid"; then echo alive >"$rec/sentinel.state"; else echo dead >"$rec/sentinel.state"; fi
echo done >"$rec/done"
EOT
	rtmp=${TMPDIR:-/tmp}
	# === MECHANISM (D14 changes 4-5): every run of the driver goes through run_ns; the unshare options are here ===
	# run_ns <scratch> [NAME=value...]: the driver in a user, pid and mount namespace of its own, with the given
	# variables set on the namespace's command.
	run_ns() {
		_s=$1
		shift
		env "$@" timeout -k 5 110 unshare --user --map-root-user --net --pid --fork --kill-child --mount-proc \
			sh "$_s/driver.sh" "$_s" "$root" "${HOME:-/nonexistent}" "$rtmp" >"$_s/ns.out" 2>&1 </dev/null
	}
	# === end of the mechanism ===
	# mkns <name>: a scratch folder $tmp/<name> for a short driver run; the caller writes its files list
	mkns() {
		mkdir -p "$tmp/$1/rec"
		: >"$tmp/$1/afile"
		cp "$tmp/sentinel.sh" "$tmp/driver.sh" "$tmp/$1/"
	}
	probe_case() {
		echo "# D14-AC-4: a file the driver runs sees none of the forge's variables and only the loopback interface"
		mkns probe
		cat >"$tmp/probe/p.test.sh" <<'EOT'
n=${0##*/}
env -0 | tr '\0' '\n' | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | sort >"$HOME/rec/penv.$n"
cat /proc/net/dev >"$HOME/rec/pnet.$n"
EOT
		# the driver runs a file named loop.test.sh with bash, any other with sh
		mkdir -p "$tmp/probe/b"
		cp "$tmp/probe/p.test.sh" "$tmp/probe/b/loop.test.sh"
		printf '%s\n' "$tmp/probe/p.test.sh" "$tmp/probe/b/loop.test.sh" >"$tmp/probe/files"
		run_ns "$tmp/probe" NOODLEBOT_FORGE=https://forge.invalid GH_TOKEN=fake-gh GITHUB_TOKEN=fake-github CLAUDE_CODE_OAUTH_TOKEN=fake-oauth ANTHROPIC_API_KEY=fake-key
		pst=$(cat "$tmp/probe/rec/state" 2>/dev/null)
		if [ "$pst" != ready ]; then
			pass "D14-AC-4: the namespace could not be made here (${pst:-driver did not start}); the probe case is skipped, no file ran"
			return 0
		fi
		for _p in p.test.sh loop.test.sh; do
			pe=$tmp/probe/rec/penv.$_p
			if [ ! -s "$pe" ]; then
				fail "D14-AC-4:$_p: no record of its environment"
				continue
			fi
			extra=
			while IFS= read -r _v; do
				case $_v in
				PATH | HOME | TMPDIR | PWD) ;;
				NBRT_*) case ${_v#NBRT_} in '' | *[!0-9]*) extra="$extra $_v" ;; esac ;;
				SHLVL | _) [ "$_p" = loop.test.sh ] || extra="$extra $_v" ;;
				*) extra="$extra $_v" ;;
				esac
			done <"$pe"
			if [ -z "$extra" ]; then
				pass "D14-AC-4:$_p: its environment holds only the allow-list and what the shell sets"
			else
				fail "D14-AC-4:$_p: its environment holds more than the allow-list:$extra"
			fi
			ifs=$(sed -n 's/^[[:space:]]*\([^:[:space:]]*\):.*/\1/p' "$tmp/probe/rec/pnet.$_p" 2>/dev/null | tr '\n' ' ')
			if [ "$ifs" = "lo " ]; then
				pass "D14-AC-4:$_p: the loopback is its only interface"
			else
				fail "D14-AC-4:$_p: the loopback is its only interface (saw: ${ifs:-no record})"
			fi
		done
	}
	late_case() {
		echo "# D14-AC-5: a TERM sent to the sentinel as the last file ends is recorded"
		mkns late
		cat >"$tmp/late/standin.test.sh" <<'EOT'
# Waits until the sentinel has just started a new sleep, sends it TERM and ends at once.
spid=
i=0
while [ -z "$spid" ] && [ "$i" -lt 200 ]; do
	for _d in /proc/[0-9]*; do
		_a=$(tr '\0' ' ' <"$_d/cmdline" 2>/dev/null)
		case $_a in *sentinel.sh*) spid=${_d#/proc/}; break ;; esac
	done
	[ -n "$spid" ] || { sleep 0.05; i=$((i + 1)); }
done
[ -n "$spid" ] || exit 1
# The driver, the namespace's pid 1, polls every 0.1 s by starting a sleep. The TERM is sent as a sentinel tick
# starts and while the driver's sleep has run 40-85 ms (the driver then sees this file end at its next poll,
# about 0.1 s before its end), so that the signal is as late for the driver as it can be: the shortest wait
# between the driver's last poll and the end of the namespace is shorter than the sentinel's tick. After 3 s it
# sends the TERM whatever the phase.
now() { _n=$(date +%s%N); _n=$((_n / 1000000)); }
now
deadline=$((_n + 3000))
lastsp= dsl= dt0=0 j=0
while [ "$j" -lt 5000 ]; do
	sp= dp=
	for _d in /proc/[0-9]*; do
		{ read -r _l <"$_d/stat"; } 2>/dev/null || continue
		_c=${_l#*\(}
		_c=${_c%%\)*}
		[ "$_c" = sleep ] || continue
		_r=${_l##*) }
		set -- $_r
		case $2 in
		"$spid") sp=${_d#/proc/} ;;
		1) dp=${_d#/proc/} ;;
		esac
	done
	if [ -n "$dp" ] && [ "$dp" != "$dsl" ]; then
		dsl=$dp
		now
		dt0=$_n
	fi
	if [ -n "$sp" ] && [ "$sp" != "$lastsp" ]; then
		now
		if [ -n "$lastsp" ] && { [ "$_n" -ge "$deadline" ] || { [ $((_n - dt0)) -ge 40 ] && [ $((_n - dt0)) -le 85 ]; }; }; then
			kill -s TERM "$spid"
			exit 0
		fi
		lastsp=$sp
	fi
	j=$((j + 1))
done
exit 1
EOT
		printf '%s\n' "$tmp/late/standin.test.sh" >"$tmp/late/files"
		run_ns "$tmp/late"
		lst=$(cat "$tmp/late/rec/state" 2>/dev/null)
		if [ "$lst" != ready ]; then
			pass "D14-AC-5: the namespace could not be made here (${lst:-driver did not start}); the late-signal case is skipped, no file ran"
		elif grep -qx TERM "$tmp/late/rec/sig" 2>/dev/null; then
			pass "D14-AC-5:the TERM sent to the sentinel as the last file ended is recorded"
		else
			fail "D14-AC-5:the TERM sent to the sentinel as the last file ended is recorded (record: $(tr '\n' ' ' <"$tmp/late/rec/sig" 2>/dev/null))"
		fi
	}
	if [ -n "$late" ]; then
		late_case
		[ "$fails" -eq 0 ]
		exit
	fi
	run_ns "$tmp"
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
		pass "D12-AC-3: the namespace check failed here (${state:-unshare with --net was refused, the driver did not run: $(head -c 200 "$tmp/ns.out" 2>/dev/null | tr '\n' ' ')}); the namespace case is skipped, no test file ran"
		;;
	esac
	probe_case
	late_case
fi

[ "$fails" -eq 0 ]
