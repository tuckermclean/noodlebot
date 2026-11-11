# The start of every scheduler/loop*.test.sh (bash; source it first: . "$(dirname "$0")/testdata/lib/loop-prelude.sh").
# Sets up what the end-to-end tests of scheduler/loop.sh share: a scratch folder $tmp (removed on exit, with every
# process whose command line names it: pgrep/pkill patterns in these files always contain "$tmp/", so files that
# run at the same time never touch each other's processes), $HOME with a fake token script, the remote
# $tmp/remote.git (main carries A01 -> (A02, A03, A04, A05)) and the generic helpers.
set -u
unset NOODLEBOT_VERSION   # V01: run from a clean environment, even inside a noodlebot session
export SCHED_RAMP=0   # S07: the start queue is off for every run; the start-queue run sets SCHED_RAMP=1 on its own loops
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
pids=()
# extra_cleanup: a file that starts processes of its own that are not in $pids and not named by $tmp redefines it.
extra_cleanup() { :; }
# shellcheck disable=SC2154 # p is the trap's own loop variable
trap 'for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; extra_cleanup; pkill -f "$tmp/" 2>/dev/null; rm -rf "$tmp"' EXIT
fails=0
. "$src/testdata/lib/common.sh"
# ok <name> <command...>: PASS when the command succeeds.
ok() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; echo "      status.log:"; sed 's/^/      /' "$state/status.log" 2>/dev/null; fi; }

export HOME=$tmp/home
nb=$tmp/nb state=$tmp/nb/state/proj
export NOODLEBOT_DATA=$nb   # D02: the runs keep their layout under $nb; the D02 runs set or unset it
mkdir -p "$HOME/.config/noodlebot" "$tmp/bin" "$nb/scheduler" "$nb/plugin"
printf '#!/bin/sh\necho fake-token\n' >"$HOME/.config/noodlebot/token"
echo fake-oauth >"$HOME/.config/noodlebot/oauth-token"
chmod +x "$HOME/.config/noodlebot/token"

# The remote: main carries A01 -> (A02, A03).
git init -q -b main "$tmp/work"
mkdir -p "$tmp/work/docs"
printf 'nodes:\n  - {id: A01, name: first-node, deps: []}\n  - {id: A02, name: second-node, deps: [A01]}\n  - {id: A03, name: third-node, deps: [A01]}\n  - {id: A04, name: fourth-node, deps: [A01]}\n  - {id: A05, name: fifth-node, deps: [A01]}\n' >"$tmp/work/docs/graph.yaml"
git -C "$tmp/work" add -A && git -C "$tmp/work" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work" "$tmp/remote.git"

# within <seconds> <pattern>: a status.log line matches within that time.
within() { wait_line "$1" "$2" "$state/status.log"; }
count() { grep -cE "$1" "$state/status.log"; }
# waitf <seconds> <command...>: wait_until under its older name.
waitf() { wait_until "$@"; }
# loop_end <file>: the last line of a part: FAIL and status 1 when a check failed. (loop.test.sh prints the PASS line.)
loop_end() { if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi; }
# cp_scheduler <dir>: the scheduler's files (not the tests) into <dir>.
cp_scheduler() { local f; for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$1/" ;; esac; done; }
# wait_ticks <n> [<state dir>]: the loop that owns that state dir (default $state) has started n more ticks: its heartbeat
# file (one epoch second per tick) changed n times. Where a check says something did NOT happen, this is the wait: the
# loop has had at least as many ticks as the old fixed sleep covered. Gives up after 10 s a tick.
_hbchg() { [ "$(cat "$2/heartbeat" 2>/dev/null)" != "$1" ]; }
wait_ticks() {
	local n=$1 sd=${2:-$state} last
	last=$(cat "$sd/heartbeat" 2>/dev/null)
	while [ "$n" -gt 0 ]; do
		wait_until 10 _hbchg "$last" "$sd" || return 1
		last=$(cat "$sd/heartbeat" 2>/dev/null); n=$((n - 1))
	done
}
# Ticks counted by the fake gh: a loop asks for the merged PRs once a tick, so a fake gh that appends a line to <file> on
# `--state merged` counts ticks. polls <file>: how many so far. wait_polls <file> <count> <n>: n more ticks than <count>
# were counted (take <count> with polls when the thing to wait for happened). Checks of "this did not happen" use these
# to run later, after other phases have used up the ticks they need, instead of sleeping.
polls() { local n; n=$(wc -l <"$1" 2>/dev/null) && echo "${n:-0}" || echo 0; }
_polls_ge() { [ "$(polls "$1")" -ge "$2" ]; }
wait_polls() { wait_until $(($3 * 10 + 10)) _polls_ge "$1" $(($2 + $3)); }
# rl_event <file> <five-hour utilization> <its resetsAt>: appends an allowed rate_limit_event line (seven-day window at 0, 3 days out) to <file>.
rl_event() { printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":%s,"resetsAt":%s,"status":"allowed"},"seven_day":{"utilization":0.0,"resetsAt":%s,"status":"allowed"}}}}\n' "$2" "$3" $(($(date +%s) + 3 * 86400)) >>"$1"; }
