# fixture.sh: the shared start for a background fixture of a test file (POSIX sh; also sourced from bash).
#   . "$src/testdata/lib/fixture.sh"
#   fixture_start <command> [args...] </dev/null >/dev/null 2>&1 &
# The caller writes the trailing `&`; the function runs in that background subshell, so `$!` is the pid the fixture
# keeps: it starts a watch (own session, stdio on /dev/null, in no group of the fixture, without the new mark) and
# `exec`s `setsid <command>`, so the fixture is a child of the test shell in a session and process group of its own,
# with NB_FIXTURE_MARK=<unique> in its environment, which everything it starts inherits, also across `setsid`.
# The watch polls about every second; when the test shell (NB_TEST_SHELL, exported here, $$ of the sourcing shell,
# unless set already to a live process) is gone or a zombie, or NB_FIXTURE_LIFETIME seconds (default 600) have passed,
# it stops the fixture's process group (while the fixture's environment carries the mark) and every process carrying
# the mark (TERM, then KILL a few seconds later; a second pass catches a fixture that had not `exec`d yet) and exits.
case ${NB_TEST_SHELL:-} in '' | *[!0-9]*) NB_TEST_SHELL=$$ ;; *) [ -e "/proc/$NB_TEST_SHELL" ] || NB_TEST_SHELL=$$ ;; esac
export NB_TEST_SHELL

fixture_start() {
	read -r _nb_me _ </proc/self/stat # the pid of this (sub)shell, which becomes the fixture
	_nb_mark=nbfx.${NB_TEST_SHELL}.${_nb_me}.$(date +%s%N)
	(
		cd / || exit 1
		env -u NB_FIXTURE_MARK setsid sh -c '
			ts=$1 fx=$2 mark=$3 life=$4
			gone() { [ ! -e "/proc/$ts/stat" ] || sed "s/^.*) //" "/proc/$ts/stat" | grep -q "^[ZX]"; }
			pids() { grep -l -a -z -x -F -s "NB_FIXTURE_MARK=$mark" /proc/[0-9]*/environ 2>/dev/null | sed "s|^/proc/\\([0-9]*\\)/environ\$|\\1|" | grep -vx "$$"; }
			grp() {
				[ "$(sed "s/^.*) //" "/proc/$fx/stat" 2>/dev/null | cut -d" " -f3)" = "$fx" ] &&
					grep -q -a -z -x -F -s "NB_FIXTURE_MARK=$mark" "/proc/$fx/environ" 2>/dev/null && echo "$fx"
				return 0
			}
			end=$(($(date +%s) + life))
			while ! gone && [ "$(date +%s)" -lt "$end" ]; do sleep 1; done
			p=$(pids)
			g=$(grp)
			[ -z "$g" ] || kill -s TERM -- "-$g" 2>/dev/null
			[ -z "$p" ] || kill -s TERM $p 2>/dev/null
			sleep 3
			p=$(pids)
			g=$(grp)
			[ -z "$g" ] || kill -s TERM -- "-$g" 2>/dev/null
			[ -z "$p" ] || kill -s TERM $p 2>/dev/null
			if [ -n "$p$g" ]; then
				sleep 1
				p=$(pids)
				g=$(grp)
				[ -z "$g" ] || kill -s KILL -- "-$g" 2>/dev/null
				[ -z "$p" ] || kill -s KILL $p 2>/dev/null
			fi
		' fixture-watch "$NB_TEST_SHELL" "$_nb_me" "$_nb_mark" "${NB_FIXTURE_LIFETIME:-600}" </dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
	)
	NB_FIXTURE_MARK=$_nb_mark
	export NB_FIXTURE_MARK
	exec setsid "$@"
}

# fixture_stop_all: stop every process that carries the mark of a fixture this test shell (NB_TEST_SHELL) started
# (TERM, then KILL 0.3 s later), for the EXIT trap of a test file; it never signals by a pattern that can be empty
# or by a path, and never the calling shell.
fixture_stop_all() {
	case ${NB_TEST_SHELL:-} in '' | *[!0-9]*) return 0 ;; esac
	_nb_pids() { grep -l -a -z -s "^NB_FIXTURE_MARK=nbfx\\.$NB_TEST_SHELL\\." /proc/[0-9]*/environ 2>/dev/null | sed "s|^/proc/\\([0-9]*\\)/environ\$|\\1|" | grep -vx "$$"; }
	_nb_p=$(_nb_pids)
	[ -z "$_nb_p" ] || kill -s TERM $_nb_p 2>/dev/null
	sleep 0.3
	_nb_p=$(_nb_pids)
	[ -z "$_nb_p" ] || kill -s KILL $_nb_p 2>/dev/null
	return 0
}
