#!/bin/bash
# W05 (slice 2 review): the same end-to-end fixture as loop-w05.test.sh (testdata/lib/loop-w05.sh), more cases.
# W05-AC-1: a site file that holds no valid address (a blank first line, an empty file, https:/// , https://) is said once
# and gives no --site; W05-AC-5: a node, triage, follow-up and update prompt is checked in each off case.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-w05.sh"

ADDR=https://owner.example/noodlebot
w05_start w5on all "$ADDR/" yes false
w05_start w5http all "http://owner.example/noodlebot/" yes false
w05_start w5nogist all "$ADDR/" no false
w05_start w5sched0 all "$ADDR/" yes false SCHED_SITE=0
w05_start w5priv all "$ADDR/" yes true
w05_start w5unk all "$ADDR/" yes fail
w05_start w5blank node "" yes false
w05_start w5blank2 node $'\nhttps://ok.example/x' yes false
w05_start w5nohost node "https:///" yes false
w05_start w5bare node "https://" yes false
# an existing 0-byte site file: made before the loop starts (w05_start with - leaves it alone)
mkdir -p "$W5/h/w5empty/.config/noodlebot" && : >"$W5/h/w5empty/.config/noodlebot/site"
w05_start w5empty node - yes false
w05_kinds() { case $1 in w5on|w5http|w5nogist|w5sched0|w5priv|w5unk) echo all ;; *) echo node ;; esac; }
for n in $W5_ALL; do
	wait_until 90 w05_ready "$n" "$(w05_kinds "$n")" || echo "      (harness) $n: prompts or report calls missing after 90 s"
done
w05_stop_all

w05_off() { # <name> <keys>: no --site, the prompts are the links-on ones minus the site line, no placeholder
	local n=$1 k; shift
	[ "$(w05_reports "$n")" -ge 2 ] && ! grep -q -- '--site' "$W5/report.$n" || return 1
	for k in "$@"; do
		[ -s "$W5/rec/$n.$k" ] && [ -s "$W5/rec/w5on.$k" ] || return 1
		! grep -qF "owner.example" "$W5/rec/$n.$k" && ! grep -qE '@[A-Z][A-Z-]*@' "$W5/rec/$n.$k" || return 1
		[ "$(w05_norm "$n" "$k")" = "$(w05_norm w5on "$k" | grep -vF "$ADDR")" ] || return 1
	done
}
w05_said_once() { [ "$(w05_log "$1" | grep -c '^.*status site links off: .')" = 1 ]; }
w05_nosite() { # <name>: no --site and no site line in the node prompt (not compared with the on case)
	[ "$(w05_reports "$1")" -ge 4 ] && ! grep -q -- '--site' "$W5/report.$1" && [ -s "$W5/rec/$1.A02" ] &&
		! grep -qE 'status site is at|@[A-Z][A-Z-]*@' "$W5/rec/$1.A02"
}

ok "W05-AC-1: (control) the links-on loop got --site" grep -qE -- " --site $ADDR( |\$)" "$W5/report.w5on"
for pair in "a blank first line:w5blank" "a blank first line, a valid second line:w5blank2" "an empty file:w5empty" "https:///:w5nohost" "https://:w5bare"; do
	label=${pair%:*} n=${pair##*:}
	ok "W05-AC-1: ($label) it is said once in the status log over at least 3 ticks: 'status site links off: <reason>'" w05_said_once "$n"
	ok "W05-AC-1: ($label) report.py gets no --site and the node prompt has no site line" w05_nosite "$n"
done

for pair in "invalid address, http://:w5http" "no gist:w5nogist" "SCHED_SITE=0:w5sched0" "visibility private:w5priv" "visibility unknown:w5unk"; do
	label=${pair%:*} n=${pair##*:}
	ok "W05-AC-5: ($label) the node, triage, follow-up and update prompts have no site line, no blank line where it was, no placeholder" w05_off "$n" A02 issue-46 A05 pr-101
done

loop_end
