#!/bin/sh
# Test of scheduler/loops.sh for M04 (loops-unit): the tmux server in a systemd user unit of its own, the check
# of where an already running server lives, the lingering line and the lines on where the loops run.
#   sh scheduler/loops-m04.test.sh   (make test)
# Fakes of tmux, systemd-run and loginctl come first on a scratch PATH made of the fakes and symlinks to the few
# tools loops.sh needs, so the real tmux, systemd-run and loginctl are never reached (a case with no systemd-run has
# none on its PATH). Every path is under $tmp/M04/<case>; no real tmux server, unit or lingering is touched.
# Interfaces the fakes give loops.sh:
#   NOODLEBOT_PROC_ROOT=<dir>  (tests only) loops.sh reads <dir>/<pid>/cgroup in place of /proc/<pid>/cgroup, for the
#                              pid `tmux display -p '#{pid}'` prints; a missing file means no line.
#   tmux: logs "$*" (prefixed "[sdr] " when run through systemd-run); the state file $TMUXSTATE holds the pid of
#         the running server (missing or empty: no server); display, ls, list-sessions, has-session answer from it
#         and fail when it is empty; `new -d -s <name> <cmd...>` runs <cmd> detached and, when no server ran, sets
#         the state (pid 4242).
#   systemd-run: logs "$*", parses its options (--unit X, --unit=X, ...) and execs the command after them; when
#         $SDRMODE says `fail` it exits 1 and runs nothing.
#   loginctl: logs "$*"; `show-user <user> -p Linger` prints Linger=yes or Linger=no per $LCMODE (yes, no); mode
#         `fail` exits 1, mode `empty` prints nothing; any other verb exits 1.
# The units file is $HOME/.config/noodlebot/units; without it loops.sh calls neither loginctl nor systemd-run.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
base=$tmp/M04
mkdir -p "$base" || exit 1
trap 'for d in "$base"/*/home; do touch "$d/STOP" 2>/dev/null; done; fixture_stop_all; rm -rf "$tmp"' EXIT
. "$src/testdata/lib/fixture.sh"; NB_FIXTURE_SH=$src/testdata/lib/fixture.sh; export NB_FIXTURE_SH
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
# eq <name> <got> <want>
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
ok() { name=$1; shift; if "$@" 2>/dev/null; then pass "$name"; else fail "$name"; fi; }
# cnt <file> <grep args...>: the number of matching lines (0 for a missing file)
cnt() { f=$1; shift; n=$(grep -c "$@" "$f" 2>/dev/null); echo "${n:-0}"; }

# tools: symlinks to what loops.sh, the fakes and fixture.sh need; no /usr/bin on the PATH of a case
tools=$base/tools
mkdir -p "$tools"
for t in bash sh env flock stat grep sed tr findmnt readlink python3 sleep mkdir rm cat id timeout setsid date cut \
	basename dirname touch ls cp mv head tail wc awk sort uname printf echo test expr kill pgrep mktemp; do
	p=$(command -v "$t" 2>/dev/null)
	case $p in /*) ln -s "$p" "$tools/$t" ;; esac
done

# mkfakes <bindir>: the fake tmux, systemd-run (unless missing) and loginctl
mkfakes() {
	mkdir -p "$1"
	cat >"$1/tmux" <<'EOT'
#!/bin/sh
echo "${FAKE_VIA:-}$*" >>"$TMUXLOG"
case $1 in
display | display-message)
	[ -s "$TMUXSTATE" ] || { echo "no server running" >&2; exit 1; }
	cat "$TMUXSTATE"; exit 0 ;;
ls | list-sessions | has-session | has | list-clients | info)
	[ -s "$TMUXSTATE" ] || { echo "no server running" >&2; exit 1; }
	[ "$1" = ls ] || [ "$1" = list-sessions ] && echo "sched-x: 1 windows"
	exit 0 ;;
new | new-session)
	shift
	while [ $# -gt 0 ]; do case $1 in -d) shift ;; -s) shift 2 ;; *) break ;; esac; done
	[ -s "$TMUXSTATE" ] || echo 4242 >"$TMUXSTATE"
	. "$NB_FIXTURE_SH"
	fixture_start sh -c "$*" >/dev/null 2>&1 </dev/null &
	exit 0 ;;
esac
exit 1
EOT
	cat >"$1/loginctl" <<'EOT'
#!/bin/sh
echo "$*" >>"$LCLOG"
m=$(cat "$LCMODE" 2>/dev/null)
case $m in
fail) echo "Failed to get user: no" >&2; exit 1 ;;
empty) exit 0 ;;
esac
[ "$1" = show-user ] || exit 1
case " $* " in
*" --value "*) echo "$m" ;;
*) echo "Linger=$m" ;;
esac
EOT
	chmod +x "$1/tmux" "$1/loginctl"
	[ "$2" = missing ] && return 0
	cat >"$1/systemd-run" <<'EOT'
#!/bin/sh
echo "$*" >>"$SDRLOG"
[ "$(cat "$SDRMODE" 2>/dev/null)" = fail ] && { echo "Failed to connect to bus" >&2; exit 1; }
while [ $# -gt 0 ]; do
	case $1 in
	--) shift; break ;;
	--unit | -u | --description | --slice | -p | --property | -E | --setenv | --working-directory | -G) shift 2 ;;
	-*) shift ;;
	*) break ;;
	esac
done
FAKE_VIA='[sdr] '; export FAKE_VIA
exec "$@"
EOT
	chmod +x "$1/systemd-run"
}

# newcase <name> <units on|off> <linger yes|no|fail|empty> <systemd-run ok|fail|missing>
newcase() {
	cn=$1; c=$base/$cn; nb=$c/nb; bin=$c/bin
	HOME=$c/home root=$c/data
	TMUXLOG=$c/tmux.log TMUXSTATE=$c/tmux.state SDRLOG=$c/sdr.log SDRMODE=$c/sdr.mode LCLOG=$c/lc.log LCMODE=$c/lc.mode
	NOODLEBOT_DATA=$root NOODLEBOT_PROC_ROOT=$c/proc XDG_RUNTIME_DIR=$c/run
	export HOME TMUXLOG TMUXSTATE SDRLOG SDRMODE LCLOG LCMODE NOODLEBOT_DATA NOODLEBOT_PROC_ROOT XDG_RUNTIME_DIR
	mkdir -p "$HOME/.config/noodlebot" "$nb/scheduler" "$root" "$c/run"
	cp "$src/loops.sh" "$nb/scheduler/"
	printf 'o/alpha\no/beta\n' >"$HOME/.config/noodlebot/repos"
	[ "$2" = on ] && : >"$HOME/.config/noodlebot/units"
	echo "$3" >"$LCMODE"
	echo "$4" >"$SDRMODE"
	mkfakes "$bin" "$4"
	cat >"$nb/scheduler/loop.sh" <<'EOT'
#!/bin/sh
name=${1#*/}
mkdir -p "$NOODLEBOT_DATA/state/$name"
exec 9>"$NOODLEBOT_DATA/state/$name/loop.lock"
flock -n 9 || exit 1
echo $$ >"$NOODLEBOT_DATA/state/$name/loop.pid"
while [ ! -e "$HOME/STOP" ] && [ ! -e "$HOME/STOP-$name" ]; do sleep 0.2; done
EOT
	cat >"$nb/scheduler/api.py" <<'EOT'
import fcntl, os, time
root = os.environ["NOODLEBOT_DATA"]
f = open(os.path.join(root, "api.lock"), "w")
fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
open(os.path.join(root, "api.pid"), "w").write(str(os.getpid()))
while not os.path.exists(os.path.join(os.environ["HOME"], "STOP")):
    time.sleep(0.2)
EOT
	chmod +x "$nb/scheduler/loop.sh"
}
# server <pid> <cgroup line>: a tmux server runs with that pid, its cgroup in the fixture
server() { echo "$1" >"$TMUXSTATE"; mkdir -p "$NOODLEBOT_PROC_ROOT/$1"; echo "$2" >"$NOODLEBOT_PROC_ROOT/$1/cgroup"; }
# run <start|status>: loops.sh on the case's PATH; output in $c/out.<cmd>, status in $c/rc.<cmd>
run() { env -u TMUX PATH="$bin:$tools" timeout 60 sh "$nb/scheduler/loops.sh" "$1" >"$c/out.$1" 2>&1 </dev/null; echo $? >"$c/rc.$1"; }
endcase() { touch "$HOME/STOP"; }
# the session variables of a loop run must not leak into the scratch loops
for v in $(env | sed -n 's/^\(\(USAGE\|SCHED\|PICKUP\)[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done

# started <name> <out>: every listed loop and the API started, once each, with no new line naming a repository
started() {
	eq "$1:alpha-started-one-line" "$(cnt "$2" -i alpha)" 1
	eq "$1:beta-started-one-line" "$(cnt "$2" -i beta)" 1
	eq "$1:api-started" "$(cnt "$2" '^api: started in tmux session sched-api')" 1
	eq "$1:start-exits-0" "$(cat "$c/rc.start")" 0
	ok "$1:loops-and-api-hold-their-locks" sh -c "[ -s '$root/state/alpha/loop.pid' ] && [ -s '$root/state/beta/loop.pid' ] && [ -s '$root/api.pid' ]"
	eq "$1:three-tmux-new" "$(cnt "$TMUXLOG" '^\(\[sdr\] \)\{0,1\}new ')" 3
	ok "$1:session-names" sh -c "grep -q 'sched-alpha' '$TMUXLOG' && grep -q 'sched-beta' '$TMUXLOG' && grep -q 'sched-api' '$TMUXLOG'"
}
nosystemd() { ok "$1:nothing-under-.config/systemd" test ! -e "$HOME/.config/systemd"; }
# nolingerchange <name>: loginctl was only asked to show
nolingerchange() {
	eq "$1:loginctl-never-changes-anything" "$(cnt "$LCLOG" -v '^show-user ')" 0
}
# loginline <out>: the lines saying the loops end with a login (not the lingering line)
loginline() { grep -i 'login' "$1" | grep -vi 'linger' | grep -vi 'logout'; }
lingerlines() { cnt "$1" -i 'linger'; }

echo "# M04-AC-1: units on, no tmux server: the first tmux new runs through systemd-run --user --scope"
newcase ac1-nosrv on yes ok
run start
started M04-AC-1:nosrv "$c/out.start"
eq "M04-AC-1:nosrv:one-systemd-run-call" "$(cnt "$SDRLOG" '')" 1
ok "M04-AC-1:nosrv:systemd-run-user-scope-collect-unit" sh -c "grep -q -e '--user' '$SDRLOG' && grep -q -e '--scope' '$SDRLOG' && grep -q -e '--collect' '$SDRLOG' && grep -q -E -e '--unit[= ]noodlebot-loops( |\$)' '$SDRLOG'"
ok "M04-AC-1:nosrv:systemd-run-runs-a-tmux-new" sh -c "grep -q -E 'tmux new .*-s sched-(alpha|beta|api) ' '$SDRLOG'"
eq "M04-AC-1:nosrv:one-tmux-new-through-systemd-run" "$(cnt "$TMUXLOG" '^\[sdr\] new ')" 1
ok "M04-AC-1:nosrv:the-first-tmux-new-is-the-one-through-systemd-run" sh -c "grep -E '^(\\[sdr\\] )?new ' '$TMUXLOG' | sed -n 1p | grep -q '^\\[sdr\\] new '"
eq "M04-AC-1:nosrv:no-calling-shell-line" "$(cnt "$c/out.start" -F "calling shell")" 0
eq "M04-AC-1:nosrv:no-login-line" "$(loginline "$c/out.start" | wc -l | tr -d ' ')" 0
eq "M04-AC-1:nosrv:no-lingering-line-with-linger-yes" "$(lingerlines "$c/out.start")" 0
nosystemd M04-AC-1:nosrv
endcase

echo "# M04-AC-1: units on, a server already running in a login session's scope"
newcase ac1-login on yes ok
server 4100 "0::/user.slice/user-1000.slice/session-3.scope"
run start
started M04-AC-1:login "$c/out.start"
eq "M04-AC-1:login:one-line-the-loops-end-with-the-login" "$(loginline "$c/out.start" | wc -l | tr -d ' ')" 1
ok "M04-AC-1:login:line-says-how-to-move" sh -c "grep -i login '$c/out.start' | grep -vi linger | grep -i stop | grep -i server | grep -iq start"
eq "M04-AC-1:login:no-systemd-run" "$(cnt "$SDRLOG" '')" 0
eq "M04-AC-1:login:tmux-new-directly" "$(cnt "$TMUXLOG" '^\[sdr\] ')" 0
nosystemd M04-AC-1:login
endcase

echo "# M04-AC-1: a server in a noodlebot-loops scope or a user service gets no line"
newcase ac1-unitscope on yes ok
server 4101 "0::/user.slice/user-1000.slice/user@1000.service/app.slice/noodlebot-loops.scope"
run start
started M04-AC-1:unitscope "$c/out.start"
eq "M04-AC-1:unitscope:no-login-line" "$(loginline "$c/out.start" | wc -l | tr -d ' ')" 0
eq "M04-AC-1:unitscope:no-systemd-run" "$(cnt "$SDRLOG" '')" 0
endcase
newcase ac1-service on yes ok
server 4102 "0::/user.slice/user-1000.slice/user@1000.service/app.slice/tmux-server.service"
run start
started M04-AC-1:service "$c/out.start"
eq "M04-AC-1:service:no-login-line" "$(loginline "$c/out.start" | wc -l | tr -d ' ')" 0
endcase

echo "# M04-AC-2: Linger=no: one line in start and in status"
newcase ac2-no on no ok
run start
started M04-AC-2:no-start "$c/out.start"
eq "M04-AC-2:no-start:one-lingering-line" "$(lingerlines "$c/out.start")" 1
ok "M04-AC-2:no-start:line-names-enable-linger-and-logout" sh -c "grep -i linger '$c/out.start' | grep -q 'loginctl enable-linger' && grep -i linger '$c/out.start' | grep -iq logout && grep -i linger '$c/out.start' | grep -i stop | grep -i loops | grep -iq api"
run status
eq "M04-AC-2:no-status:one-lingering-line" "$(lingerlines "$c/out.status")" 1
ok "M04-AC-2:no-status:line-names-enable-linger-and-logout" sh -c "grep -i linger '$c/out.status' | grep -q 'loginctl enable-linger' && grep -i linger '$c/out.status' | grep -iq logout && grep -i linger '$c/out.status' | grep -i stop | grep -i loops | grep -iq api"
ok "M04-AC-2:no:loginctl-asked-for-the-user-linger" sh -c "grep -q '^show-user .*Linger' '$LCLOG' && grep -q \"show-user $(id -un)\" '$LCLOG'"
nolingerchange M04-AC-2:no
nosystemd M04-AC-2:no
endcase

for m in yes fail empty; do
	echo "# M04-AC-2: loginctl $m: no lingering line"
	newcase ac2-$m on $m ok
	run start
	started M04-AC-2:$m-start "$c/out.start"
	eq "M04-AC-2:$m-start:no-lingering-line" "$(lingerlines "$c/out.start")" 0
	run status
	eq "M04-AC-2:$m-status:no-lingering-line" "$(lingerlines "$c/out.status")" 0
	eq "M04-AC-2:$m-status:three-lines" "$(wc -l <"$c/out.status" | tr -d ' ')" 3
	nolingerchange M04-AC-2:$m
	nosystemd M04-AC-2:$m
	endcase
done

echo "# M04-AC-2 and M04-AC-3: units off (no file), a fake loginctl answering Linger=no"
newcase ac3-off off no ok
run start
started M04-AC-3:off "$c/out.start"
eq "M04-AC-3:off:one-calling-shell-line" "$(cnt "$c/out.start" -F "calling shell's session")" 1
ok "M04-AC-3:off:the-line-names-no-repository-or-api" sh -c "! grep -F \"calling shell's session\" '$c/out.start' | grep -iq -e alpha -e beta -e api"
eq "M04-AC-3:off:api-one-line" "$(cnt "$c/out.start" -i api)" 1
eq "M04-AC-3:off:no-systemd-run" "$(cnt "$SDRLOG" '')" 0
eq "M04-AC-3:off:tmux-new-directly" "$(cnt "$TMUXLOG" '^\[sdr\] ')" 0
eq "M04-AC-2:off:no-lingering-line-in-start" "$(lingerlines "$c/out.start")" 0
run status
eq "M04-AC-2:off:no-lingering-line-in-status" "$(lingerlines "$c/out.status")" 0
eq "M04-AC-3:off:status-three-lines" "$(wc -l <"$c/out.status" | tr -d ' ')" 3
eq "M04-AC-2:off:loginctl-not-called" "$(cnt "$LCLOG" '')" 0
nosystemd M04-AC-3:off
endcase

echo "# M04-AC-3: units on, systemd-run missing from the PATH"
newcase ac3-missing on yes missing
ok "M04-AC-3:missing:harness-has-no-systemd-run" sh -c "! env PATH='$bin:$tools' sh -c 'command -v systemd-run' >/dev/null 2>&1"
run start
started M04-AC-3:missing "$c/out.start"
eq "M04-AC-3:missing:one-calling-shell-line" "$(cnt "$c/out.start" -F "calling shell's session")" 1
eq "M04-AC-3:missing:tmux-new-directly" "$(cnt "$TMUXLOG" '^\[sdr\] ')" 0
nosystemd M04-AC-3:missing
endcase

echo "# M04-AC-3: units on, systemd-run --user failing (exit 1, no command run)"
newcase ac3-fail on yes fail
run start
started M04-AC-3:fail "$c/out.start"
eq "M04-AC-3:fail:one-calling-shell-line" "$(cnt "$c/out.start" -F "calling shell's session")" 1
eq "M04-AC-3:fail:systemd-run-tried-once" "$(cnt "$SDRLOG" '')" 1
eq "M04-AC-3:fail:tmux-new-directly" "$(cnt "$TMUXLOG" '^\[sdr\] ')" 0
nosystemd M04-AC-3:fail
endcase

[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
