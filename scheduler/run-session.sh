#!/bin/bash
# run-session.sh <worktree> <state-dir> <prompt> [<session id>]: one unattended session ("/node B03",
# "/noodlebot:triage 46"), with the bot's plugin (../plugin) loaded, started by loop.sh
# under setsid, so it has its own process group and no terminal: stopping the loop or closing its
# tmux window never stops a session. Writes the exit code to <node-state-dir>/session.rc (the loop
# reads it, even after a restart). stdout/stderr are set up by the loop. With a session id it resumes
# that conversation (the harness's resume) with the prompt in <state-dir>/resume-prompt.md, after the
# usage limit left it idle; <prompt> then only names the task, as the loop's process check reads it.
# S12: with SCHED_UNITS=1 (loop.sh: ~/.config/noodlebot/units exists) and a working `systemd-run --user`, the first stage runs
# in a transient scope (systemd-run execs: the agent CLI stays this script's direct child) with MemoryMax/MemorySwapMax from
# SCHED_MEMORY_MAX/SCHED_SWAP_MAX (default: half of MemTotal/SwapTotal of SCHED_MEMINFO, default /proc/meminfo) and
# <state-dir>/session.unit gets "<unit> <result> <MemoryMax>"; else it runs directly and one stderr line says why. The
# script raises its own oom_score_adj to SCHED_OOM_ADJ (default 500), never lowers it. TMPDIR of the session is
# <state-dir>/tmp, emptied first and removed at the end. As soon as the first stage exits, what it left is ended: the scope
# is stopped, else (or when that fails) its process group gets SIGTERM, SIGKILL after 3 s, except this script and the
# record stage; the exit code is still the first stage's.
set -u
wt=$1 dir=$2 prompt=$3 sid=${4:-}
here=$(cd "$(dirname "$0")" && pwd -P)   # before the cd: $0 may be relative
plugin=$(cd "$here/../plugin" && pwd -P)
cd "$wt" || { echo 2 >"$dir/session.rc"; exit 2; }
unset ANTHROPIC_API_KEY GH_TOKEN GITHUB_TOKEN
# the forge the session reaches (G04): the repository and the forge CLI wrapper, which alone sets the token script for its own
# process; the session has no token and no token script variable (the loop exports it to this script: dropped here)
unset NOODLEBOT_FORGE_TOKEN_SCRIPT
[ -z "${NOODLEBOT_FORGE_REPO:-}" ] || export NOODLEBOT_FORGE_REPO
export NOODLEBOT_FORGE="$here/forge-cli.sh"
[ -z "${NOODLEBOT_VERSION:-}" ] || export NOODLEBOT_VERSION
# the harness backend (harness.py, SCHED_HARNESS) runs the session, keeps its credential and writes events.jsonl: its
# first stage becomes the agent CLI (a direct child of this script, the process the loop signals), the second one
# passes the raw stream on and records the events. The exit code is the first stage's.
# oom_score_adj: raised to SCHED_OOM_ADJ when that is higher, before anything starts (a failed write is not an error)
adj=${SCHED_OOM_ADJ:-500}
case $adj in '' | *[!0-9]*) ;; *)
	cur=$(cat /proc/self/oom_score_adj 2>/dev/null) || cur=
	case ${cur#-} in '' | *[!0-9]*) ;; *)
		[ "$adj" -le "$cur" ] || { echo "$adj" >/proc/self/oom_score_adj; } 2>/dev/null || :
	esac
esac

# TMPDIR of the session: <state-dir>/tmp, emptied; when it cannot be, the inherited one stays
# (only below a <state-dir> that resolves to a real folder other than "/": "//", "/." or an empty one must never make this an rm -rf of /tmp)
tmpd= tmpmade=
real=$(cd "$dir" 2>/dev/null && pwd -P)
case $real in
/?*) tmpd=$dir/tmp ;;
esac
if [ -n "$tmpd" ] && rm -rf "$tmpd" 2>/dev/null && mkdir -p "$tmpd" 2>/dev/null; then
	tmpmade=1; export TMPDIR=$tmpd
else
	echo "run-session.sh: cannot make a tmp folder in '$dir': keeping the inherited TMPDIR" >&2
fi

# the unit's settings are read once; neither stage (the agent CLI, the tests it runs) inherits them
units=${SCHED_UNITS:-} mmax_in=${SCHED_MEMORY_MAX:-} smax_in=${SCHED_SWAP_MAX:-} mem=${SCHED_MEMINFO:-/proc/meminfo}
unset SCHED_UNITS SCHED_MEMORY_MAX SCHED_SWAP_MAX SCHED_MEMINFO SCHED_OOM_ADJ

# the unit: the first stage's scope when the units are on and systemd-run --user can make one
unit= mmax= smax= nounit=
if [ "$units" != 1 ]; then
	nounit="the units are off"
elif ! command -v systemd-run >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
	nounit="systemd-run or systemctl is missing"
else
	half() { awk -v k="$1" '$1 == k":" { printf "%.0f\n", $2 * 512; f = 1 } END { exit !f }' "$mem" 2>/dev/null; }
	mmax=${mmax_in:-$(half MemTotal)} smax=${smax_in:-$(half SwapTotal)}
	[ -n "$mmax" ] || mmax=infinity
	[ -n "$smax" ] || smax=infinity
	# a probe with the session's own properties: only a scope that ran its command proves `systemd-run --user` works with them
	# (its failure, e.g. an invalid setting, comes before the command)
	why=$(systemd-run --user --scope --quiet -p "MemoryMax=$mmax" -p "MemorySwapMax=$smax" -p TimeoutStopSec=5 true 2>&1 >/dev/null) \
		|| nounit="systemd-run --user failed: $(echo "$why" | tr '\n' ' ')"
fi
if [ -z "$nounit" ]; then
	key=$(echo "$dir" | awk -F/ '{ print $(NF-2) "-" $(NF-1) "-" $NF }' | tr -c 'A-Za-z0-9:_.\n-' '-')
	unit="noodlebot-$key-$(date +%s).scope"
else
	echo "run-session.sh: no unit used for this session: $nounit" >&2
fi

# the first stage ends the session's own work; the second records the stream and reads to EOF. They talk through a fifo, so
# that this script sees the first stage's exit at once (not when the record stage has ended, which a leftover holding the
# stream open would delay)
pf="$dir/agent.pid"; rm -f "$pf"
fifo="$dir/stream.fifo"; rm -f "$fifo"
mkfifo "$fifo" || { [ -z "$tmpmade" ] || rm -rf "$tmpd"; echo 2 >"$dir/session.rc"; exit 2; }
if [ -n "$sid" ]; then
	first=(python3 -I "$here/harness.py" exec-resume "$pf" "$wt" "$dir" "$sid" "$(cat "$dir/resume-prompt.md")")
	rec=(python3 -I "$here/harness.py" record "$dir" append "$pf")
else
	first=(python3 -I "$here/harness.py" exec-start "$pf" "$wt" "$dir" "$prompt" "$dir/unattended.md" "$plugin")
	rec=(python3 -I "$here/harness.py" record "$dir" fresh "$pf")
fi
if [ -n "$unit" ]; then
	first=(systemd-run --user --scope --quiet --unit "$unit" -p "MemoryMax=$mmax" -p "MemorySwapMax=$smax" -p TimeoutStopSec=5 "${first[@]}")
fi
"${rec[@]}" <"$fifo" &
recpid=$!
"${first[@]}" >"$fifo" &
wait $!
rc=$?

# what the first stage left: every process of the session except this script and the record stage
pgid= st=
{ read -r st </proc/$$/stat; } 2>/dev/null && { set -- ${st##*) }; pgid=${3:-}; }
left() {   # the pids of the group other than us (and our $(...) subshell) and the record stage, zombies apart
	local s st p
	for s in /proc/[0-9]*/stat; do
		{ read -r st <"$s"; } 2>/dev/null || continue
		set -- ${st##*) }
		p=${s#/proc/}; p=${p%%/*}
		[ "${3:-}" = "$pgid" ] && [ "$1" != Z ] && [ "$p" != "$$" ] && [ "$p" != "$BASHPID" ] && [ "$p" != "$recpid" ] && echo "$p"
	done
}
group_kill() {
	[ -n "$pgid" ] && [ "$pgid" = "$$" ] || return 0   # not a session of its own (loop.sh uses setsid): signal nothing
	local p t0=$SECONDS
	p=$(left); [ -n "$p" ] || return 0
	kill -s TERM $p 2>/dev/null
	# the grace is 3 s of the clock (a scan of /proc takes its time on a loaded machine)
	while [ $((SECONDS - t0)) -lt 3 ]; do
		p=$(left); [ -n "$p" ] || return 0
		sleep 0.1
	done
	p=$(left); [ -z "$p" ] || kill -s KILL $p 2>/dev/null
	return 0
}
stopped=
if [ -n "$unit" ]; then
	systemctl --user stop "$unit" >/dev/null 2>&1 && stopped=1
	res=$(systemctl --user show -p Result --value "$unit" 2>/dev/null) || res=
	echo "$unit ${res:-unknown} $mmax" >"$dir/session.unit.tmp" && mv "$dir/session.unit.tmp" "$dir/session.unit"
	[ "${res:-unknown}" = success ] || systemctl --user reset-failed "$unit" >/dev/null 2>&1
fi
[ -n "$stopped" ] || group_kill
wait "$recpid"
rm -f "$pf" "$fifo"
[ -z "$tmpmade" ] || [ "$tmpd" != "$dir/tmp" ] || rm -rf "$tmpd"
echo "$rc" >"$dir/session.rc.tmp" && mv "$dir/session.rc.tmp" "$dir/session.rc"
exit "$rc"
