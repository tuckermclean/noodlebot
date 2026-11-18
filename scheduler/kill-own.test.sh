#!/bin/sh
# Test of the guarded kill of testdata/lib/kill-own.sh (D14-AC-2).
#   sh scheduler/kill-own.test.sh   (make test)
# A cleanup that kills the process group whose number a fake wrote from its own $PPID can run `kill -- -1` (the
# parent had ended, so $PPID is 1) and signal every process of the user. kill-own.sh gives
#   kill_own <folder> <pidfile>...   KILL to the group and to the pid each file holds,
#   kill_own_ok <folder> <pid>       the check alone (status 0 when the pid may be signalled),
# which act only on a number above 1 whose /proc/<pid>/cmdline names <folder>/, and never when <folder> is empty,
# /, canonically /, not absolute or not an existing directory.
#  - the behaviour case runs inside a user and pid namespace of its own (the driver is its pid 1, and its command
#    line names the folder), so that a broken guard that ran `kill -- -1` reaches only the namespace. Where the
#    namespace is refused, it runs nothing that signals and skips with a PASS line.
#  - the second case reads the five lines that call the guard (the four loop-s06* cleanups, the S04 fake).
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
. "$src/testdata/lib/common.sh"
unset TMUX USAGE_7D_MARGIN NOODLEBOT_DATA NOODLEBOT_VERSION
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
tmp=$(cd "$tmp" && pwd -P) && [ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
lib=$src/testdata/lib

# id|what it states. The driver runs c_<id> for each and records the result; this file reports them.
cat >"$tmp/cases" <<'EOT'
pid1names|the namespace's pid 1 has a command line that names <folder>/
one|a pid file holding 1 signals nothing (a group whose leader names <folder>/ still runs)
nothing|an empty pid file signals nothing
nonnum|pid files holding a value that is not a number (abc, 2x), 0 or -1 signal nothing
sentinel|the pid of a sentinel whose command line does not name <folder>/ is not signalled, nor its group
main|pid files holding 1, nothing, a non-number, the sentinel's pid and the leader's pid kill the leader's group and leave the sentinel and its group running
ok_main|kill_own_ok answers 0 for the leader's pid and nonzero for 1, nothing, a non-number and the sentinel's pid, and signals nothing
bad_empty|an empty folder signals nothing (the leader's command line holds a /)
bad_root|the folder / signals nothing (the leader's command line holds //)
bad_canon|a folder whose canonical form is / signals nothing (the leader's command line holds <folder>/ and //)
bad_rel|a relative folder that exists from the working directory signals nothing (the leader names <folder>/)
bad_missing|a folder that does not exist signals nothing (the leader names a path under it)
bad_file|a folder that is a file signals nothing (the leader names a path under it)
symlink_canon|a folder given through a symlink kills the group whose leader names the canonical path
symlink_given|a folder given through a symlink kills the group whose leader names the path as given
sibling|a command line that names a sibling <folder>x/ does not match <folder>
EOT

echo "# D14-AC-2: the guarded kill, in a namespace of its own"
if [ ! -f "$lib/kill-own.sh" ]; then
	while IFS='|' read -r id what; do
		fail "D14-AC-2:$what (testdata/lib/kill-own.sh does not exist)"
	done <"$tmp/cases"
elif ! timeout 20 unshare --user --map-root-user --pid --fork --kill-child --mount-proc sh -c 'test -r /proc/self/status && ! test -r /proc/1/status.nonexistent' >/dev/null 2>&1; then
	pass "D14-AC-2: unshare --user --map-root-user --pid --fork --mount-proc is refused here; the behaviour case is skipped (nothing was signalled)"
else
	mkdir -p "$tmp/res" "$tmp/sub"
	ln -s "$tmp/sub" "$tmp/lnk"
	: >"$tmp/afile"
	cat >"$tmp/driver.sh" <<'EOT'
# The namespace's pid 1. $1 scratch folder, $2 lib folder. Everything it starts dies with it.
F=$1 lib=$2
res=$F/res
. "$lib/common.sh"
. "$lib/kill-own.sh"
cd "$F" || exit 0
alive() {
	{ read -r _l <"/proc/$1/stat"; } 2>/dev/null || return 1
	_s=${_l##*) }
	[ "${_s%% *}" != Z ]
}
all_gone() { for _p in "$@"; do alive "$_p" && return 1; done; return 0; }
gone() { wait_until 5 all_gone "$@" || { why="still running: $*"; return 1; }; }
# stays <pid>...: none of them is signalled (a signal that is sent shows within a few tenths of a second)
stays() {
	_i=0
	while [ "$_i" -lt 3 ]; do
		for _p in "$@"; do alive "$_p" || { why="process $_p was signalled"; return 1; }; done
		sleep 0.1
		_i=$((_i + 1))
	done
}
# sentinel: a group leader of its own whose command line does not name the folder (relative file name, cwd is $F)
setsid sh -c 'sleep 300 & echo $! >sent.child; wait' sentinel >/dev/null 2>&1 </dev/null &
sp=$!
echo "$sp" >pf.sent
wait_line 5 '^[0-9]+$' sent.child
sc=$(cat sent.child)
# mkgroup <argument>: a group leader of its own whose command line holds <argument>, with a child; gp, gc, pid.g
mkgroup() {
	rm -f g.child
	setsid sh -c 'sleep 300 & echo $! >g.child; wait' grp "$1" >/dev/null 2>&1 </dev/null &
	gp=$!
	echo "$gp" >pid.g
	wait_line 5 '^[0-9]+$' g.child
	gc=$(cat g.child)
}
endgroup() { kill -KILL -- "-$gp" 2>/dev/null; }   # a group this driver started
at_root() { (cd / && "$@"); }
echo 1 >pf.one; : >pf.nothing; echo abc >pf.abc; echo 2x >pf.2x; echo -1 >pf.neg; echo 0 >pf.zero

c_pid1names() {
	_c=$(tr '\0' ' ' </proc/1/cmdline)
	case $_c in *"$F/"*) ;; *) why="pid 1 is: $_c"; return 1 ;; esac
	_c=$(tr '\0' ' ' </proc/$sp/cmdline)
	case $_c in *"$F/"*) why="the sentinel names the folder: $_c"; return 1 ;; esac
}
# keeps <id> <pidfile>...: the leader's group still runs after the guarded kill of these pid files
keeps() {
	mkgroup "$F/leader"
	at_root kill_own "$F" "$@"
	stays "$gp" "$gc" "$sp" "$sc"; _r=$?
	endgroup
	return "$_r"
}
c_one() { keeps "$F/pf.one"; }
c_nothing() { keeps "$F/pf.nothing"; }
c_nonnum() { keeps "$F/pf.abc" "$F/pf.2x" "$F/pf.neg" "$F/pf.zero"; }
c_sentinel() { keeps "$F/pf.sent"; }
c_main() {
	mkgroup "$F/leader"
	at_root kill_own "$F" "$F/pf.one" "$F/pf.nothing" "$F/pf.abc" "$F/pf.sent" "$F/pid.g"
	gone "$gp" "$gc" || { endgroup; return 1; }
	stays "$sp" "$sc"
}
c_ok_main() {
	mkgroup "$F/leader"
	at_root kill_own_ok "$F" "$gp" || { why="kill_own_ok refused the leader's pid"; endgroup; return 1; }
	for _v in 1 "" abc "$sp"; do
		if at_root kill_own_ok "$F" "$_v"; then why="kill_own_ok accepted '$_v'"; endgroup; return 1; fi
	done
	stays "$gp" "$gc" "$sp" "$sc"; _r=$?
	endgroup
	return "$_r"
}
# bad <folder> <argument>: with the leader's command line holding <argument>, the folder is refused by both
bad() {
	mkgroup "$2"
	if at_root kill_own_ok "$1" "$gp"; then why="kill_own_ok accepted the folder '$1'"; endgroup; return 1; fi
	at_root kill_own "$1" "$F/pid.g"
	stays "$gp" "$gc"; _r=$?
	endgroup
	return "$_r"
}
c_bad_empty() { bad "" "$F/leader"; }
c_bad_root() { bad / "//"; }
c_bad_canon() { bad /proc/.. "/proc/..//"; }
c_bad_rel() { bad "${F#/}" "${F#/}/leader"; }
c_bad_missing() { bad "$F/missing" "$F/missing/leader"; }
c_bad_file() { bad "$F/afile" "$F/afile/leader"; }
# kills <folder> <argument>: the group is killed (by kill_own, and kill_own_ok says 0)
kills() {
	mkgroup "$2"
	at_root kill_own_ok "$1" "$gp" || { why="kill_own_ok refused the folder '$1'"; endgroup; return 1; }
	at_root kill_own "$1" "$F/pid.g"
	gone "$gp" "$gc"; _r=$?
	endgroup
	return "$_r"
}
c_symlink_canon() { kills "$F/lnk" "$F/sub/leader"; }
c_symlink_given() { kills "$F/lnk" "$F/lnk/leader"; }
c_sibling() { bad "$F/sub" "${F}/subx/leader"; }

while IFS='|' read -r id _what; do
	why=
	"c_$id"
	if [ $? -eq 0 ]; then echo ok >"$res/$id"; else echo "${why:-failed}" >"$res/$id.bad"; fi
done <"$F/cases"
echo done >"$res/done"
EOT
	timeout -k 5 100 unshare --user --map-root-user --pid --fork --kill-child --mount-proc \
		sh "$tmp/driver.sh" "$tmp" "$lib" >"$tmp/ns.out" 2>&1 </dev/null
	if [ ! -f "$tmp/res/done" ]; then
		fail "D14-AC-2:the driver ran every case to its end (it ended early; $(tr '\n' ' ' <"$tmp/ns.out" | cut -c1-200))"
	fi
	while IFS='|' read -r id what; do
		if [ -f "$tmp/res/$id" ]; then
			pass "D14-AC-2:$what"
		elif [ -f "$tmp/res/$id.bad" ]; then
			fail "D14-AC-2:$what ($(cat "$tmp/res/$id.bad"))"
		else
			fail "D14-AC-2:$what (no record of the case)"
		fi
	done <"$tmp/cases"
fi

echo "# D14-AC-2: the five cleanup and fake lines kill only through the guard"
# one_line <file> <pattern>: the only line of the file that holds the fixed string
one_line() { grep -F -- "$2" "$1" 2>/dev/null; }
rest_ok="kill -KILL -- \"-\$(cat \"\$f\")\" 2>/dev/null; kill -KILL \"\$(cat \"\$f\")\" 2>/dev/null; done"
for t in loop-s06 loop-s06-update loop-s06-later loop-s06-review; do
	f=$src/$t.test.sh
	line=$(one_line "$f" '/child.*')
	n=$(printf '%s\n' "$line" | grep -c .)
	if [ "$n" -ne 1 ]; then
		fail "D14-AC-2:$t.test.sh: its cleanup line (the one holding /child.*) is found ($n lines)"
		continue
	fi
	ok_=yes
	g1='kill_own "$tmp" "$S06"/pg.* "$S06"/pg2.*'
	g2='kill_own "${S06%/*}" "$S06"/pg.* "$S06"/pg2.*'
	case $line in
	*"$g1"*) after=${line#*"$g1"} before=${line%%"$g1"*} ;;
	*"$g2"*) after=${line#*"$g2"} before=${line%%"$g2"*} ;;
	*) ok_=no ;;
	esac
	if [ "$ok_" = yes ]; then
		# pg.* and pg2.* occur only as the arguments of the call; the loop that is left takes only child.*
		case $before$after in *pg*) ok_=no ;; esac
		case $after in *'for f in "$S06"/child.*; do '*"$rest_ok"*) ;; *) ok_=no ;; esac
	fi
	if [ "$ok_" = yes ]; then
		pass "D14-AC-2:$t.test.sh: its pg.* and pg2.* kills go through kill_own (a call to kill-own.sh), the child.* kill stays"
	else
		fail "D14-AC-2:$t.test.sh: its pg.* and pg2.* kills go through kill_own \"\$tmp\" \"\$S06\"/pg.* \"\$S06\"/pg2.* followed by the child.* loop alone (line: $line)"
	fi
done
if grep -Eq '^[[:space:]]*\.[[:space:]].*kill-own\.sh' "$lib/loop-s06.sh" 2>/dev/null; then
	pass "D14-AC-2:testdata/lib/loop-s06.sh sources kill-own.sh for the four loop-s06* files"
else
	fail "D14-AC-2:testdata/lib/loop-s06.sh sources kill-own.sh for the four loop-s06* files"
fi
want='E06.1) commits 1; brief; echo more >>base.txt; . "$S04_LIB/kill-own.sh" && kill_own_ok "${S04%/*}" "$PPID" && kill -KILL $PPID; exit 0 ;;'
line=$(one_line "$src/loop-s04.test.sh" 'E06.1)')
line=${line#"${line%%[![:space:]]*}"}
if [ "$line" = "$want" ]; then
	pass "D14-AC-2:loop-s04.test.sh: the fake kills its \$PPID only after kill_own_ok \"\${S04%/*}\" \"\$PPID\" (not \$S04)"
else
	fail "D14-AC-2:loop-s04.test.sh: the fake kills its \$PPID only after kill_own_ok \"\${S04%/*}\" \"\$PPID\" (line: $line)"
fi
if grep -qxF 'S04_LIB=$src/testdata/lib; export S04_LIB' "$lib/loop-s04.sh" 2>/dev/null; then
	pass "D14-AC-2:testdata/lib/loop-s04.sh exports S04_LIB"
else
	fail "D14-AC-2:testdata/lib/loop-s04.sh exports S04_LIB"
fi

[ "$fails" -eq 0 ]
