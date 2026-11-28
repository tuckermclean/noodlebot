#!/bin/sh
# Tests scheduler/report.py: the status issue's Usage section says whether the weekly pace hold is on (T04-AC-4).
#   sh scheduler/report-t04.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
fakegh_lib=$src/testdata/lib
. "$fakegh_lib/report-fakegh.sh"
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
pyc_setup
. "$fakegh_lib/report-units.sh"
ustatus_init
# Three runs on a state folder each, whose usage.json differs only in limits: pace on with margin 0.1, pace off, no
# seven_day_pace key (a file from before T03). TZ=UTC: the window resets are printed in local time.
# usagejson <limits JSON> <file>: the fixed readings with the given "limits".
usagejson() {
	printf '{"updated": 1800000000, "windows": {"five_hour": {"utilization": 0.62, "resetsAt": 1800000000, "status": "allowed"}, "seven_day": {"utilization": 0.4, "resetsAt": 1800500000, "status": "allowed"}}, "samples5h": [], "projected5h": 0.5, "weekElapsed": 0.5, "hold": false, "reason": "", "summary": "x", "limits": %s}\n' "$1" >"$2"
}
# body <case>: the status issue's body after a run over that case's folder (state/proj, usage.json beside it).
body() {
	mkdir -p "$tmp/c-$1/state/proj"
	: >"$tmp/c-$1/state/proj/status.log"
	usagejson "$2" "$tmp/c-$1/state/usage.json"
	env TZ=UTC PATH="$ubin:$PATH" python3 -I "$src/report.py" --repo owner/repo --state "$tmp/c-$1/state/proj" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/uerr"
	uq "db['issues']['$ustatus']['body']" >"$tmp/body-$1"
}
# section <file>: the Usage section (from its heading to the next heading, without the blank line before it).
section() { awk '/^## Usage$/ {f=1; print; next} f && /^## / {exit} f' "$1" | sed '$d'; }
# What report.py at the base 8a14b9b gives for those readings, in TZ=UTC (the same for all three files).
cat >"$tmp/base-section" <<'BASE'
## Usage

- **5-hour** `████████████░░░░░░░░` 62%, resets 2027-01-15 08:00 UTC (projected 50% at the reset)
- **7-day** `████████░░░░░░░░░░░░` 40%, resets 2027-01-21 02:53 UTC (50% of the week gone)
- **Throttle:** open (new sessions start)
BASE
# the base's section with the weekly pace hold line right after the Throttle line
{ cat "$tmp/base-section"; printf '%s\n' '- **Weekly pace hold:** on (holds new sessions while the 7-day window is more than 10% ahead of pace)'; } >"$tmp/want-on"
{ cat "$tmp/base-section"; printf '%s\n' '- **Weekly pace hold:** off (`USAGE_7D_PACE=0`)'; } >"$tmp/want-off"
body on '{"five_hour": 0.9, "seven_day_margin": 0.1, "seven_day_pace": true}'
body off '{"five_hour": 0.9, "seven_day_margin": 0.1, "seven_day_pace": false}'
body none '{"five_hour": 0.9, "seven_day_margin": 0.1}'
grep -v '^_Updated' "$tmp/body-none" >"$tmp/body-none2"
for c in on off none; do section "$tmp/body-$c" >"$tmp/sec-$c"; done
ok "T04-AC-4 setup: the Usage section of the base's readings is found" test -s "$tmp/sec-none"
ok "T04-AC-4: seven_day_pace true: the Usage section has the line 'on (holds new sessions while the 7-day window is more than 10% ahead of pace)'" grep -qxF -- '- **Weekly pace hold:** on (holds new sessions while the 7-day window is more than 10% ahead of pace)' "$tmp/sec-on"
ok "T04-AC-4: seven_day_pace true: the section is the base's, with that line after the Throttle line, and nothing else changed" cmp -s "$tmp/sec-on" "$tmp/want-on"
ok "T04-AC-4: seven_day_pace false: the Usage section has the line 'off (\`USAGE_7D_PACE=0\`)'" grep -qxF -- '- **Weekly pace hold:** off (`USAGE_7D_PACE=0`)' "$tmp/sec-off"
ok "T04-AC-4: seven_day_pace false: the section is the base's, with that line after the Throttle line, and nothing else changed" cmp -s "$tmp/sec-off" "$tmp/want-off"
ok "T04-AC-4: no seven_day_pace key: no 'Weekly pace hold' line anywhere in the status issue" sh -c "! grep -q 'Weekly pace hold' '$tmp/body-none'"
ok "T04-AC-4: no seven_day_pace key: the section is the base's, unchanged" cmp -s "$tmp/sec-none" "$tmp/base-section"
ok "T04-AC-4: the line is in the Usage section only: one line in each of the first two bodies" sh -c "[ \"\$(grep -c 'Weekly pace hold' '$tmp/body-on')\" = 1 ] && [ \"\$(grep -c 'Weekly pace hold' '$tmp/body-off')\" = 1 ]"
ok "T04-AC-4: outside the Usage section the body is the same in all three (on, off, none differ by that one line)" sh -c "grep -v 'Weekly pace hold' '$tmp/body-on' | grep -v '^_Updated' | cmp -s - '$tmp/body-none2' && grep -v 'Weekly pace hold' '$tmp/body-off' | grep -v '^_Updated' | cmp -s - '$tmp/body-none2'"
body m25 '{"five_hour": 0.9, "seven_day_margin": 0.25, "seven_day_pace": true}'
section "$tmp/body-m25" >"$tmp/sec-m25"
ok "T04-AC-4: the percentage is the margin's: 0.25 gives 'more than 25% ahead of pace'" grep -qxF -- '- **Weekly pace hold:** on (holds new sessions while the 7-day window is more than 25% ahead of pace)' "$tmp/sec-m25"
if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
