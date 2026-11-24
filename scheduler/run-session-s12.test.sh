#!/bin/sh
# S12 session-scope, run-session.sh alone (S12-AC-1, S12-AC-2, S12-AC-3, S12-AC-6, S12-AC-7). The loop's half is
# scheduler/loop-s12.test.sh.
#   sh scheduler/run-session-s12.test.sh   (make test)
#
# THE INTERFACE (run-session.sh <worktree> <state-dir> <prompt> [<session id>] keeps its arguments). The settings come in the
# environment, which is what loop.sh exports to run-session.sh once it has read ~/.config/noodlebot/units (the test's HOME has
# none and run-session.sh never reads HOME for it):
#   SCHED_UNITS=1       the units are on (loop.sh: the units file exists); unset or empty: off
#   SCHED_MEMORY_MAX    MemoryMax of the scope, systemd's size syntax; unset: half of MemTotal of $SCHED_MEMINFO
#   SCHED_SWAP_MAX      MemorySwapMax of the scope; unset: half of SwapTotal of $SCHED_MEMINFO
#   SCHED_MEMINFO       the meminfo file the defaults come from (default /proc/meminfo)
#   SCHED_OOM_ADJ       the oom_score_adj of the session's processes, only ever raised (default 500)
# The state folder is <runtime root>/state/<runtime name>/<kind>/<key> (node/B03, issue/46, pr/12, adopt/<key>): the scope's
# unit name holds the runtime name, the kind and the key; TMPDIR is <state-dir>/tmp.
# The agent CLI is the fake claude (testdata/s12/claude.sh) of the Claude Code backend; systemd-run and systemctl are
# fakes (testdata/s12/) first on a scratch PATH, the scratch HOME has no units file: no real scope is ever made.
# Every case is a run of run-session.sh of its own, started together and checked after they all ended.
src=$(cd "$(dirname "$0")" && pwd -P)
. "$src/testdata/lib/common.sh"
. "$src/testdata/lib/kill-own.sh"
fx=$src/testdata/s12
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
tmp=$(cd "$tmp" && pwd -P) && [ -d "$tmp" ] || exit 1
cleanup() {
	chmod -R u+rwX "$tmp" 2>/dev/null
	for _f in "$tmp"/*/log/left.pid; do kill_own "$tmp" "$_f"; done
	kill_own "$tmp" "$tmp"/*/log/rs.pid
	rm -rf "$tmp"
}
trap cleanup EXIT
unset USAGE_7D_MARGIN NOODLEBOT_DATA NOODLEBOT_VERSION NOODLEBOT_FORGE NOODLEBOT_FORGE_REPO NOODLEBOT_FORGE_TOKEN_SCRIPT \
	SCHED_UNITS SCHED_MEMORY_MAX SCHED_SWAP_MAX SCHED_MEMINFO SCHED_OOM_ADJ SCHED_HARNESS TMPDIR \
	S12_LOG S12_DIR S12_RC S12_LEFT S12_SETSID S12_SD_FAIL S12_STOP_FAIL S12_RESULT S12_RAISE S12_UNIT_MARK FAKE_HARNESS_SCRIPT

home=$tmp/home
mkdir -p "$home/.config/noodlebot" "$tmp/fakes" "$tmp/nosd"
echo tok-S12 >"$home/.config/noodlebot/oauth-token"
cp "$fx/claude.sh" "$tmp/fakes/claude"
cp "$fx/systemd-run.sh" "$tmp/fakes/systemd-run"
cp "$fx/systemctl.sh" "$tmp/fakes/systemctl"
cp "$fx/leftover.sh" "$tmp/fakes/leftover.sh"
chmod +x "$tmp/fakes/claude" "$tmp/fakes/systemd-run" "$tmp/fakes/systemctl"
cp "$tmp/fakes/claude" "$tmp/nosd/claude"
# nosd: the PATH of the machine without any systemd-run or systemctl (an earlier directory of the PATH wins)
for _d in $(echo "$PATH" | tr ':' '\n' | tac); do
	[ -d "$_d" ] || continue
	find "$_d" -maxdepth 1 \( -type f -o -type l \) ! -name systemd-run ! -name systemctl ! -name claude \
		-exec ln -sf -t "$tmp/nosd" '{}' + 2>/dev/null
done
path_units=$tmp/fakes:$PATH
path_nosd=$tmp/nosd

# go <name> <kind/key> [VAR=value...]: one run of run-session.sh under setsid (as loop.sh starts it), its state folder
# $tmp/<name>/data/state/myrepo-<name>/<kind>/<key> with a stale tmp folder, the fakes' records in $tmp/<name>/log. $sid, when set,
# resumes that session; $path is the PATH. Writes rs.rc (the exit code) and t.end (the time it ended, ns) there.
sid= path=$path_units
go() {
	n=$1 kk=$2
	shift 2
	b=$tmp/$n
	dir=$b/data/state/myrepo-$n/$kk   # a runtime name of its own: the runs are at once, their unit names must differ
	mkdir -p "$b/log" "$b/inh" "$b/wt" "$dir"
	echo "$dir" >"$b/dirpath"
	echo "the system prompt" >"$dir/unattended.md"
	echo "the resume prompt" >"$dir/resume-prompt.md"
	mkdir -p "$dir/tmp/sub"
	echo stale >"$dir/tmp/stale"
	echo stale >"$dir/tmp/sub/x"
	env HOME="$home" PATH="$path" NOODLEBOT_DATA="$b/data" TMPDIR="$b/inh" S12_LOG="$b/log" S12_DIR="$dir" \
		S12_LEFTOVER="$tmp/fakes/leftover.sh" "$@" \
		timeout -k 2 40 setsid -w sh -c '
			echo "$$" >"$S12_LOG/rs.pid"
			[ -z "${S12_RAISE:-}" ] || echo "$S12_RAISE" >/proc/self/oom_score_adj 2>/dev/null
			cat /proc/self/oom_score_adj >"$S12_LOG/oom.start"
			exec bash "$0" "$@"' "$src/run-session.sh" "$b/wt" "$dir" "/node B03" $sid >"$b/out" 2>"$b/err"
	echo "$?" >"$b/rs.rc"
	date +%s%N >"$b/t.end"
}

# the runs (all at once; the checks follow)
SC='SCHED_UNITS=1 SCHED_OOM_ADJ='
if [ "$(id -u)" != 0 ]; then
	( # a stale tmp folder that cannot be emptied
	mkdir -p "$tmp/lock/data/state/myrepo-lock/node/B03/tmp/locked"
	echo stale >"$tmp/lock/data/state/myrepo-lock/node/B03/tmp/locked/f"
	chmod 555 "$tmp/lock/data/state/myrepo-lock/node/B03/tmp/locked"
	go lock node/B03 S12_RC=4 ) &
fi
go on_ok node/B03 SCHED_UNITS=1 SCHED_MEMORY_MAX=3G SCHED_SWAP_MAX=1G S12_RC=7 S12_RESULT=success &
go on_oom node/B03 SCHED_UNITS=1 SCHED_MEMINFO="$fx/meminfo" SCHED_OOM_ADJ=650 S12_RC=0 S12_RESULT=oom-kill &
go on_left node/B03 SCHED_UNITS=1 SCHED_MEMORY_MAX=1G SCHED_SWAP_MAX=1G S12_RC=5 S12_LEFT=1 S12_SETSID=1 &
go on_nostop node/B03 SCHED_UNITS=1 SCHED_MEMORY_MAX=1G SCHED_SWAP_MAX=1G S12_RC=6 S12_LEFT=1 S12_STOP_FAIL=1 &
go off node/B03 S12_RC=3 S12_LEFT=1 SCHED_OOM_ADJ=200 S12_RAISE=700 &
go off_clean node/B03 S12_RC=0 &
go sd_fail node/B03 SCHED_UNITS=1 SCHED_MEMORY_MAX=1G S12_RC=2 S12_LEFT=1 S12_SD_FAIL=1 &
path=$path_nosd go sd_missing node/B03 SCHED_UNITS=1 SCHED_MEMORY_MAX=1G S12_RC=2 S12_LEFT=1 &
go bad_abc node/B03 S12_RC=4 SCHED_OOM_ADJ=abc &
go bad_big node/B03 SCHED_UNITS=1 SCHED_MEMORY_MAX=1G S12_RC=5 SCHED_OOM_ADJ=5000 &
sid=s12-sid go resumed issue/46 SCHED_UNITS=1 SCHED_MEMORY_MAX=2G SCHED_SWAP_MAX=0 S12_RC=0 &
# an empty, "//" or "/." <state-dir>: rm and mkfifo are fakes that only log (rm removes nothing, whatever run-session.sh does;
# mkfifo fails and logs the TMPDIR the session has by then); a user that is not root cannot write to / either
mkdir -p "$tmp/fakerm"
cat >"$tmp/fakerm/rm" <<'EOF'
#!/bin/sh
{ echo "CALL"; for _a in "$@"; do printf '%s\n' "$_a"; done; } >>"$S12_LOG/rm.log"
exit 0
EOF
cat >"$tmp/fakerm/mkfifo" <<'EOF'
#!/bin/sh
printf '%s\n' "${TMPDIR-UNSET}" >>"$S12_LOG/mkfifo.tmpdir"
exit 1
EOF
chmod +x "$tmp/fakerm/rm" "$tmp/fakerm/mkfifo"
# weird <name> <state-dir argument as given>
weird() {
	n=$1 b=$tmp/$1
	mkdir -p "$b/log" "$b/inh" "$b/wt"
	env HOME="$home" PATH="$tmp/fakerm:$path_units" TMPDIR="$b/inh" S12_LOG="$b/log" \
		timeout -k 2 40 setsid -w bash "$src/run-session.sh" "$b/wt" "$2" "/node B03" >"$b/out" 2>"$b/err" </dev/null
	echo "$?" >"$b/rs.rc"
}
if [ "$(id -u)" != 0 ]; then
	weird w_empty "" &
	weird w_slash2 "//" &
	weird w_dot "/." &
fi
wait
sid=

# --- readers
rd() { cat "$tmp/$1" 2>/dev/null; }
# bytes <size>: a size of systemd's syntax (a number, K M G T) in bytes, "x" when it is none
bytes() {
	awk -v v="$1" 'BEGIN {
		if (v !~ /^[0-9]+[KMGTkmgt]?[Bb]?$/) { print "x"; exit }
		u = toupper(substr(v, length(v), 1)); if (u == "B") u = toupper(substr(v, length(v) - 1, 1))
		m = 1; if (u == "K") m = 1024; if (u == "M") m = 1024 ^ 2; if (u == "G") m = 1024 ^ 3; if (u == "T") m = 1024 ^ 4
		printf "%.0f\n", (v + 0) * m }'
}
prop() { sed -n "s/^$2=//p" "$tmp/$1/log/sd.props" 2>/dev/null | tail -n 1; }
unitname() { rd "$1/log/sd.unit"; }
# is_unit <run> <name>: the name is the unit's, with or without the ".scope"
is_unit() { u=$(unitname "$1"); [ -n "$u" ] && { [ "$2" = "$u" ] || [ "$2" = "$u.scope" ]; }; }
# secs <value>: systemd's time value in seconds ("5", "5s", "2500ms"), "x" when it is none
secs() {
	awk -v v="$1" 'BEGIN {
		if (v ~ /^[0-9]+(ms)$/) { sub(/ms$/, "", v); print v / 1000; exit }
		if (v ~ /^[0-9.]+s?$/) { sub(/s$/, "", v); print v + 0; exit }
		print "x" }'
}
ms_since_claude() { echo $((($(rd "$1/t.end") - $(rd "$1/log/claude.end")) / 1000000)); }
gone() {
	_st=$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -c1)
	[ -z "$_st" ] || [ "$_st" = Z ]
}
left_gone() { _p=$(rd "$1/log/left.pid"); [ -n "$_p" ] && wait_until 1 gone "$_p"; }
ck() { n=$1; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }
t_eq() { [ "$1" = "$2" ]; }
t_ge() { [ "$1" -ge "$2" ] 2>/dev/null; }
t_le() { [ "$1" -le "$2" ] 2>/dev/null; }
count_no_unit() { grep -ci 'no unit' "$tmp/$1/err"; }

# --- checks every run has: session.rc, the harness ran, TMPDIR, oom_score_adj
# common <run> <label> <exit code> <oom_score_adj as given or 500>
common() {
	r=$1 l=$2 rc=$3 adj=$4
	dir=$(rd "$r/dirpath")
	ck "S12-AC-1: $l: the agent CLI ran, session.rc holds its exit code $rc" t_eq "$(rd "$r/log/claude.pid")$(cat "$dir/session.rc" 2>/dev/null)" "$(rd "$r/log/claude.pid")$rc"
	ck "S12-AC-1: $l: the agent CLI is the process agent.pid names" sh -c "[ -n '$(rd "$r/log/claude.pid")' ] && [ '$(rd "$r/log/claude.pid")' = '$(rd "$r/log/claude.agentpid")' ]"
	ck "S12-AC-1: $l: the agent CLI is a direct child of run-session.sh" sh -c "[ -n '$(rd "$r/log/rs.pid")' ] && [ '$(rd "$r/log/claude.ppid")' = '$(rd "$r/log/rs.pid")' ]"
	ck "S12-AC-7: $l: TMPDIR of the harness is exactly <state-dir>/tmp" t_eq "$(rd "$r/log/claude.tmpdir")" "$dir/tmp"
	ck "S12-AC-7: $l: that is not the TMPDIR run-session.sh was started with" sh -c "[ '$(rd "$r/log/claude.tmpdir")' != '$tmp/$r/inh' ] && [ '$(rd "$r/log/claude.tmpdir")' != UNSET ]"
	ck "S12-AC-7: $l: the folder was emptied before the harness started (it saw none of the stale files)" t_eq "$(rd "$r/log/claude.tmpls")" ""
	ck "S12-AC-7: $l: the harness wrote a file in it and the folder is gone when run-session.sh has exited" sh -c "[ -s '$tmp/$r/log/claude.tmpdir' ] && [ ! -e '$dir/tmp' ]"
	st=$(rd "$r/log/oom.start")
	want=$st
	[ "$adj" -le "$st" ] 2>/dev/null || want=$adj
	ck "S12-AC-2: $l: the agent CLI's oom_score_adj is $want (SCHED_OOM_ADJ $adj, run-session.sh started with $st)" t_eq "$(rd "$r/log/claude.oom")" "$want"
}

echo "== S12-AC-1: with the units on, the first stage starts in a scope"
r=on_ok
common $r "units on" 7 500
ck "S12-AC-1: units on: systemd-run --user --scope was called with a MemoryMax" sh -c "grep -E '^systemd-run .*--user' '$tmp/$r/log/sd.log' | grep -- --scope | grep -q MemoryMax"
ck "S12-AC-1: units on: the unit name holds the runtime name, the kind and the key, in systemd's characters" sh -c "case '$(unitname $r)' in *myrepo*node*B03*) echo '$(unitname $r)' | grep -qE '^[A-Za-z0-9:_.@-]+\$' ;; *) false ;; esac"
ck "S12-AC-1: units on: MemoryMax is SCHED_MEMORY_MAX (3G)" t_eq "$(bytes "$(prop $r MemoryMax)")" "$(bytes 3G)"
ck "S12-AC-1: units on: MemorySwapMax is SCHED_SWAP_MAX (1G)" t_eq "$(bytes "$(prop $r MemorySwapMax)")" "$(bytes 1G)"
ts=$(secs "$(prop $r TimeoutStopSec)")
ck "S12-AC-1: units on: TimeoutStopSec is set and at most 5 s ($ts)" sh -c "[ '$ts' != x ] && awk -v t='$ts' 'BEGIN { exit !(t > 0 && t <= 5) }'"
ck "S12-AC-1: units on: the agent CLI runs in the scope (the fake marked it)" sh -c "[ -n '$(unitname $r)' ] && [ '$(rd $r/log/claude.mark)' = '$(unitname $r)' ]"
set -- $(cat "$(rd $r/dirpath)/session.unit" 2>/dev/null)
ck "S12-AC-1: units on: session.unit is '<unit> <result> <MemoryMax>' (this one: success, 3G)" sh -c "[ $# = 3 ] && [ '$2' = success ] && [ '$(bytes "${3:-}")' = '$(bytes 3G)' ]"
is_unit $r "${1:-}" && pass "S12-AC-1: units on: session.unit names the unit" || fail "S12-AC-1: units on: session.unit names the unit"
ck "S12-AC-1: units on: a result of success writes session.unit without oom-kill" sh -c "! grep -q oom-kill '$(rd $r/dirpath)/session.unit' && [ -s '$(rd $r/dirpath)/session.unit' ]"
ck "S12-AC-6: units on: a first stage that leaves nothing behind adds no wait (ended $(ms_since_claude $r) ms after it)" t_le "$(ms_since_claude $r)" 3000
ck "S12-AC-3: units on: no 'no unit' line on stderr" t_eq "$(count_no_unit $r)" 0

echo "== S12-AC-1: the defaults, an out-of-memory result"
r=on_oom
common $r "units on, defaults, oom-kill" 0 650
ck "S12-AC-1: defaults: MemoryMax is half of MemTotal of the meminfo (4 GiB of 8)" t_eq "$(bytes "$(prop $r MemoryMax)")" "$(bytes 4G)"
ck "S12-AC-1: defaults: MemorySwapMax is half of SwapTotal of the meminfo (1 GiB of 2)" t_eq "$(bytes "$(prop $r MemorySwapMax)")" "$(bytes 1G)"
set -- $(cat "$(rd $r/dirpath)/session.unit" 2>/dev/null)
is_unit $r "${1:-}" && pass "S12-AC-1: oom-kill: session.unit names the unit" || fail "S12-AC-1: oom-kill: session.unit names the unit"
ck "S12-AC-1: oom-kill: session.unit holds oom-kill and the ceiling (4 GiB)" sh -c "[ $# = 3 ] && [ '$2' = oom-kill ] && [ '$(bytes "${3:-}")' = '$(bytes 4G)' ]"
ck "S12-AC-1: oom-kill: the failed unit is reset (systemctl --user reset-failed <unit> logged)" sh -c "grep -E '^systemctl .*reset-failed' '$tmp/$r/log/ctl.log' | grep -q -- '$(unitname $r)'"

echo "== S12-AC-1: a resumed session is scoped the same way"
r=resumed
common $r "resume" 0 500
ck "S12-AC-1: resume: the unit name holds the runtime name, the kind (issue) and the key (46)" sh -c "case '$(unitname $r)' in *myrepo*issue*46*) true ;; *) false ;; esac"
ck "S12-AC-1: resume: MemoryMax 2G and a TimeoutStopSec of at most 5 s" sh -c "[ '$(bytes "$(prop $r MemoryMax)")' = '$(bytes 2G)' ] && awk -v t='$(secs "$(prop $r TimeoutStopSec)")' 'BEGIN { exit !(t > 0 && t <= 5) }'"
ck "S12-AC-1: resume: the agent CLI runs in the scope" sh -c "[ -n '$(unitname $r)' ] && [ '$(rd $r/log/claude.mark)' = '$(unitname $r)' ]"

echo "== S12-AC-6: what the first stage left is killed"
# left <run> <label> <exit code>
left() {
	ck "S12-AC-6: $2: the child (ignores HUP and TERM, holds the output) is gone when run-session.sh has exited" left_gone "$1"
	ck "S12-AC-6: $2: session.rc holds the first stage's exit code ($3)" t_eq "$(cat "$(rd $1/dirpath)/session.rc" 2>/dev/null)" "$3"
	ck "S12-AC-6: $2: run-session.sh ended within 8 s of the first stage's exit ($(ms_since_claude "$1") ms), not when the child would have" t_le "$(ms_since_claude "$1")" 8000
}
r=on_left
common $r "units on, child out of the process group" 5 500
left $r "units on, setsid child" 5
ck "S12-AC-6: units on: the child left the process group (setsid), so only the stop could end it" sh -c "[ -n '$(rd $r/log/left.pid.pg)' ] && [ '$(rd $r/log/left.pid.pg)' != '$(rd $r/log/rs.pid)' ]"
ck "S12-AC-6: units on: systemctl --user stop <unit> is logged" sh -c "grep -E '^systemctl .*stop' '$tmp/$r/log/ctl.log' | grep -q -- '$(unitname $r)'"
ck "S12-AC-6: units on: the stop is logged before the read of Result (show -p Result)" sh -c "awk '/^systemctl .*stop/ { if (!s) s = NR } /^systemctl .*show/ { if (!r) r = NR } END { exit !(s && r && s < r) }' '$tmp/$r/log/ctl.log'"
r=on_nostop
common $r "units on, stop fails" 6 500
left $r "units on, systemctl stop fails (process-group kill)" 6
ck "S12-AC-6: stop fails: the stop was tried" sh -c "grep -qE '^systemctl .*stop' '$tmp/$r/log/ctl.log'"
r=off
common $r "units off" 3 200
left $r "units off (process-group kill)" 3
r=sd_fail
common $r "systemd-run fails" 2 500
left $r "systemd-run --user fails (process-group kill)" 2
r=sd_missing
common $r "systemd-run missing" 2 500
left $r "systemd-run missing (process-group kill)" 2
r=off_clean
common $r "units off, nothing left" 0 500
ck "S12-AC-6: units off: a first stage that leaves nothing behind adds no wait ($(ms_since_claude $r) ms)" t_le "$(ms_since_claude $r)" 3000

echo "== S12-AC-3: no unit: the session runs as today, one stderr line says so and why"
for r in off off_clean sd_fail sd_missing; do
	ck "S12-AC-3: $r: no scope was started (the harness was not marked)" t_eq "$(rd $r/log/claude.mark)" UNSET
	ck "S12-AC-3: $r: one stderr line says no unit was used" t_eq "$(count_no_unit $r)" 1
done
ck "S12-AC-3: units off: systemd-run and systemctl were never called" sh -c "[ ! -e '$tmp/off/log/sd.log' ] && [ ! -e '$tmp/off/log/ctl.log' ]"
ck "S12-AC-3: systemd-run failing: its message was the 'why' (the stderr line names systemd-run)" sh -c "grep -i 'no unit' '$tmp/sd_fail/err' | grep -qi 'systemd-run'"
ck "S12-AC-3: systemd-run missing: the stderr line names systemd-run" sh -c "grep -i 'no unit' '$tmp/sd_missing/err' | grep -qi 'systemd-run'"
ck "S12-AC-3: systemd-run failing: no stop or reset of a unit that never started" sh -c "! grep -qE 'stop|reset-failed' '$tmp/sd_fail/log/ctl.log' 2>/dev/null"

echo "== S12-AC-2: a write of oom_score_adj that fails leaves the session running"
common bad_abc "SCHED_OOM_ADJ not a number" 4 0
common bad_big "SCHED_OOM_ADJ 5000, units on" 5 0

echo "== S12-AC-7: a tmp folder that cannot be made"
if [ -d "$tmp/lock" ]; then
	r=lock
	dir=$tmp/lock/data/state/myrepo-lock/node/B03
	ck "S12-AC-7: tmp folder that cannot be emptied: the session ran, session.rc holds 4" t_eq "$(cat "$dir/session.rc" 2>/dev/null)" 4
	ck "S12-AC-7: tmp folder that cannot be emptied: the harness ran with the inherited TMPDIR" t_eq "$(rd lock/log/claude.tmpdir)" "$tmp/lock/inh"
	ck "S12-AC-7: tmp folder that cannot be emptied: one stderr line says so (names TMPDIR)" t_eq "$(grep -c TMPDIR "$tmp/lock/err")" 1
else
	echo "SKIP: S12-AC-7: a folder that cannot be emptied needs a user that is not root"
fi

echo "== S12-AC-7: an empty or root <state-dir> never makes run-session.sh remove or empty /tmp (or any folder outside the state dir)"
# no argument of a logged rm call (run in the worktree, as run-session.sh was) resolves to / or to /tmp or below
rm_outside() {
	[ -s "$tmp/$1/log/rm.log" ] || return 0
	(cd "$tmp/$1/wt" && while IFS= read -r _a; do
		case $_a in CALL | -* | '') continue ;; esac
		case $(realpath -m -- "$_a") in / | /tmp | /tmp/*) exit 1 ;; esac
	done <"$tmp/$1/log/rm.log")
}
if [ "$(id -u)" != 0 ]; then
	for r in w_empty w_slash2 w_dot; do
		case $r in w_empty) l="an empty" ;; w_slash2) l="a //" ;; *) l="a /." ;; esac
		ck "S12-AC-7: $l <state-dir>: no rm argument is / or /tmp or below it (rm calls: $(grep -c CALL "$tmp/$r/log/rm.log" 2>/dev/null))" rm_outside $r
		ck "S12-AC-7: $l <state-dir>: the session's TMPDIR stays the inherited one" t_eq "$(rd $r/log/mkfifo.tmpdir)" "$tmp/$r/inh"
		ck "S12-AC-7: $l <state-dir>: one stderr line says the tmp folder cannot be made (names TMPDIR)" t_eq "$(grep -c TMPDIR "$tmp/$r/err")" 1
	done
else
	echo "SKIP: S12-AC-7: an empty or root <state-dir> needs a user that is not root"
fi

[ "$fails" = 0 ]
