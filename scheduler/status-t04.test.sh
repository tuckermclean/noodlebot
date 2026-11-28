#!/bin/sh
# Tests scheduler/status.sh: its usage: line says whether the weekly pace hold is on (T04-AC-5).
#   sh scheduler/status-t04.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
# status.sh runs from a copy of the scheduler, over a runtime root of its own, with a fake forge (a gh that lists no PRs)
# and a fake token script; TZ=UTC: it prints the windows' resets in local time.
nb=$tmp/nb root=$tmp/root
mkdir -p "$nb/scheduler" "$tmp/bin" "$tmp/home/.config/noodlebot"
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$nb/scheduler/" ;; esac; done
[ -f "$src/harness.py" ] && { mkdir -p "$nb/scheduler/harnesses"; cp "$src"/harnesses/*.py "$nb/scheduler/harnesses/"; }
[ -f "$src/forge.py" ] && { mkdir -p "$nb/scheduler/forges"; cp "$src"/forges/*.py "$nb/scheduler/forges/"; }
printf '#!/bin/sh\necho fake-token\n' >"$tmp/home/.config/noodlebot/token"
chmod +x "$tmp/home/.config/noodlebot/token"
printf '#!/bin/sh\necho "[]"\nexit 0\n' >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
usagejson() {
	printf '{"updated": 1800000000, "windows": {"five_hour": {"utilization": 0.62, "resetsAt": 1800000000, "status": "allowed"}, "seven_day": {"utilization": 0.4, "resetsAt": 1800500000, "status": "allowed"}}, "samples5h": [], "projected5h": 0.5, "weekElapsed": 0.5, "hold": false, "reason": "", "summary": "x", "limits": %s}\n' "$1" >"$2"
}
# screen <case> <limits JSON>: status.sh's output for that usage.json, its clock line (first) dropped and this run's
# scheduler path made $NB.
screen() {
	mkdir -p "$root/state/proj"
	usagejson "$2" "$root/state/usage.json"
	env -u NOODLEBOT_FORGE -u NOODLEBOT_FORGE_REPO -u NOODLEBOT_FORGE_TOKEN_SCRIPT -u GH_TOKEN TZ=UTC HOME="$tmp/home" PATH="$tmp/bin:$PATH" NOODLEBOT_DATA="$root" \
		bash "$nb/scheduler/status.sh" o/proj 2>&1 | sed '1d' | sed "s|$nb|\$NB|g" >"$tmp/screen-$1"
}
# What status.sh at the base 8a14b9b prints for those readings (the same for all three files), without its clock line.
cat >"$tmp/base-screen" <<'BASE'
loop:    NOT running; start with: tmux new -d -s sched-proj $NB/scheduler/loop.sh o/proj
last GitHub check: never
usage:   5-hour 62% (resets Fri 08:00), projected 50%, 7-day 40% (resets Thu 02:53); throttle open
last change: 
sessions: none running (last started: )
-- waiting on you:
   nothing
-- open PRs:
[]
BASE
# the base's screen with <suffix> at the end of its usage: line
want() { sed "s|^\(usage: .*\)\$|\1$1|" "$tmp/base-screen"; }
screen on '{"five_hour": 0.9, "seven_day_margin": 0.1, "seven_day_pace": true}'
screen off '{"five_hour": 0.9, "seven_day_margin": 0.1, "seven_day_pace": false}'
screen none '{"five_hour": 0.9, "seven_day_margin": 0.1}'
screen m25 '{"five_hour": 0.9, "seven_day_margin": 0.25, "seven_day_pace": true}'
want ', weekly pace hold on (margin 10%)' >"$tmp/want-on"
want ', weekly pace hold off' >"$tmp/want-off"
ok "T04-AC-5 setup: the base's screen is what status.sh gives with no seven_day_pace key" cmp -s "$tmp/screen-none" "$tmp/base-screen"
ok "T04-AC-5: seven_day_pace true: the usage: line ends with ', weekly pace hold on (margin 10%)'" sh -c "grep '^usage: ' '$tmp/screen-on' | grep -q -- ', weekly pace hold on (margin 10%)\$'"
ok "T04-AC-5: seven_day_pace true: the rest of the screen is the base's" cmp -s "$tmp/screen-on" "$tmp/want-on"
ok "T04-AC-5: seven_day_pace false: the usage: line ends with ', weekly pace hold off'" sh -c "grep '^usage: ' '$tmp/screen-off' | grep -q -- ', weekly pace hold off\$'"
ok "T04-AC-5: seven_day_pace false: the rest of the screen is the base's" cmp -s "$tmp/screen-off" "$tmp/want-off"
ok "T04-AC-5: no seven_day_pace key: the usage: line has no weekly pace hold clause" sh -c "! grep -q 'weekly pace hold' '$tmp/screen-none'"
ok "T04-AC-5: no seven_day_pace key: the whole screen is the base's" cmp -s "$tmp/screen-none" "$tmp/base-screen"
ok "T04-AC-5: the margin is the file's: 0.25 gives 'margin 25%'" grep -qF -- ', weekly pace hold on (margin 25%)' "$tmp/screen-m25"
if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
