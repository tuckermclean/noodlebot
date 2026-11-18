# fixture.sh: the shared start for a background fixture of a test file (POSIX sh; also sourced from bash).
#   . "$src/testdata/lib/fixture.sh"
#   fixture_start <command> [args...] </dev/null >/dev/null 2>&1 &
# The caller writes the trailing `&`; the function runs in that background subshell, so `$!` is the pid the fixture
# keeps: it starts a watch (own session, stdio on /dev/null, in no group of the fixture) and `exec`s `setsid
# <command>`, so the fixture is a child of the test shell in a session and process group of its own, with
# NB_FIXTURE_MARK=<unique> in its environment, which everything it starts inherits, also across `setsid`.
# The watch polls about every second; when the test shell (NB_TEST_SHELL, exported here, $$ of the sourcing shell,
# unless set already) is gone or a zombie, or NB_FIXTURE_LIFETIME seconds (default 600) have passed, it stops the
# fixture's process group and every process carrying the mark (TERM, then KILL a few seconds later) and exits.
NB_TEST_SHELL=${NB_TEST_SHELL:-$$}
export NB_TEST_SHELL

fixture_start() {
	read -r _nb_me _ </proc/self/stat # the pid of this (sub)shell, which becomes the fixture
	NB_FIXTURE_MARK=nbfx.${NB_TEST_SHELL}.${_nb_me}.$(date +%s%N)
	(
		cd / || exit 1
		setsid sh -c '
			ts=$1 fx=$2 mark=$3 life=$4
			gone() { [ ! -e "/proc/$ts/stat" ] || sed "s/^.*) //" "/proc/$ts/stat" | grep -q "^[ZX]"; }
			pids() { grep -l -a -z -x -F -s "NB_FIXTURE_MARK=$mark" /proc/[0-9]*/environ 2>/dev/null | sed "s|^/proc/\\([0-9]*\\)/environ\$|\\1|" | grep -vx "$$"; }
			end=$(($(date +%s) + life))
			while ! gone && [ "$(date +%s)" -lt "$end" ]; do sleep 1; done
			p=$(pids)
			g=""
			[ "$(sed "s/^.*) //" "/proc/$fx/stat" 2>/dev/null | cut -d" " -f3)" = "$fx" ] && g=$fx
			[ -n "$p$g" ] || exit 0
			[ -z "$g" ] || kill -s TERM -- "-$g" 2>/dev/null
			[ -z "$p" ] || kill -s TERM $p 2>/dev/null
			sleep 3
			p=$(pids)
			[ -z "$g" ] || kill -s KILL -- "-$g" 2>/dev/null
			[ -z "$p" ] || kill -s KILL $p 2>/dev/null
		' fixture-watch "$NB_TEST_SHELL" "$_nb_me" "$NB_FIXTURE_MARK" "${NB_FIXTURE_LIFETIME:-600}" </dev/null >/dev/null 2>&1 &
	)
	export NB_FIXTURE_MARK
	exec setsid "$@"
}
