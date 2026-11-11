#!/bin/bash
# W05: the status site's links. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-w05.sh).
# W05-AC-1: --site is passed to report.py exactly when ~/.config/noodlebot/site holds a valid https address, the loop publishes
# the site and the visibility is public (each condition in turn); W05-AC-5: the site line of the rendered session prompts; the README.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-w05.sh"

ADDR=https://owner.example/noodlebot
# <name> <kinds> <site file> <gist> <visibility> [env]: the on case first, then every off case.
w05_start w5on all "$ADDR/" yes false
w05_start w5nofile all - yes false
w05_start w5http node "http://owner.example/noodlebot/" yes false
w05_start w5space node "https://owner.example/no odle/" yes false
w05_start w5lpar node "https://owner.example/a(b/" yes false
w05_start w5rpar node "https://owner.example/a)b/" yes false
w05_start w5lt node "https://owner.example/a<b/" yes false
w05_start w5gt node "https://owner.example/a>b/" yes false
w05_start w5quot node 'https://owner.example/a"b/' yes false
w05_start w5nogist triage "$ADDR/" no false
w05_start w5sched0 triage "$ADDR/" yes false SCHED_SITE=0
w05_start w5priv triage "$ADDR/" yes true
w05_start w5unk triage "$ADDR/" yes fail
w05_kinds() { case $1 in w5on|w5nofile) echo all ;; w5nogist|w5sched0|w5priv|w5unk) echo triage ;; *) echo node ;; esac; }
for n in $W5_ALL; do
	wait_until 60 w05_ready "$n" "$(w05_kinds "$n")" || echo "      (harness) $n: prompts or report calls missing after 60 s"
done
w05_stop_all

# ---- links on (W05-AC-1, W05-AC-5) ----
w05_not_off() { ! w05_log "$1" | grep -qF 'site links off'; }
ok "W05-AC-1: (all conditions hold) the loops ran: report.py was called at least four times" test "$(w05_reports w5on)" -ge 2
ok "W05-AC-1: (all conditions hold) every report.py call gets --site <address without the trailing />" sh -c "[ -s '$W5/report.w5on' ] && ! grep -qvE -- ' --site $ADDR( |\$)' '$W5/report.w5on'"
ok "W05-AC-1: (all conditions hold) the --site value has no trailing /" sh -c "! grep -qF -- ' --site $ADDR/' '$W5/report.w5on'"
ok "W05-AC-1: (all conditions hold) nothing is said about links being off" w05_not_off w5on
w05_one() { # <name> <key>: exactly one line names the address, and that line has the node link form of o/<name>
	local f=$W5/rec/$1.$2
	[ -s "$f" ] && [ "$(grep -cF "$ADDR" "$f")" = 1 ] && grep -F "$ADDR" "$f" | grep -qF "$ADDR/#/repo/o/$1?node="
}
for k in A02 A05 issue-46 pr-101; do
	case $k in A02) kind="node" ;; A05) kind="follow-up" ;; issue-46) kind="triage" ;; *) kind="update" ;; esac
	ok "W05-AC-5: (links on) the $kind prompt has exactly one site line, naming the address and the node link form <s>/#/repo/o/<name>?node=<ID>" w05_one w5on "$k"
	ok "W05-AC-5: (links on) the $kind prompt has no unrendered @...@ placeholder" sh -c "[ -s '$W5/rec/w5on.$k' ] && ! grep -qE '@[A-Z][A-Z-]*@' '$W5/rec/w5on.$k'"
done

# ---- links off: no --site, no site line, no blank line left, no placeholder ----
w05_off() { # <name> <keys>: no report.py call has --site; the prompts are the links-on ones minus the site line, with no placeholder
	local n=$1 k; shift
	[ "$(w05_reports "$n")" -ge 2 ] && ! grep -q -- '--site' "$W5/report.$n" || return 1
	for k in "$@"; do
		[ -s "$W5/rec/$n.$k" ] && [ -s "$W5/rec/w5on.$k" ] || return 1
		! grep -qF "owner.example" "$W5/rec/$n.$k" && ! grep -qE '@[A-Z][A-Z-]*@' "$W5/rec/$n.$k" || return 1
		[ "$(w05_norm "$n" "$k")" = "$(w05_norm w5on "$k" | grep -vF "$ADDR")" ] || return 1
	done
}
w05_said_once() { [ "$(w05_log "$1" | grep -c 'status site links off: ')" = 1 ]; }
w05_cond() { # <label> <name> <keys...>
	local label=$1 n=$2; shift 2
	ok "W05-AC-1/5: ($label) report.py gets no --site, the prompts have no site line, no blank line where it was, no placeholder" w05_off "$n" "$@"
}
w05_cond "no site file" w5nofile A02 A05 issue-46 pr-101
for pair in "http://...:w5http" "a space:w5space" "a (:w5lpar" "a ):w5rpar" "a <:w5lt" "a >:w5gt" 'a ":w5quot'; do
	label=${pair%:*} n=${pair##*:}
	w05_cond "invalid address, $label" "$n" A02
	ok "W05-AC-1: (invalid address, $label) it is said once in the status log: 'status site links off: <reason>'" w05_said_once "$n"
done
w05_cond "no gist" w5nogist A02 issue-46
w05_cond "SCHED_SITE=0" w5sched0 A02 issue-46
w05_cond "visibility private" w5priv A02 issue-46
w05_cond "visibility unknown" w5unk A02 issue-46
ok "W05-AC-1: (visibility records) public, public, ... private and unknown are what the loops recorded" sh -c "[ \"\$(cat '$W5/data/state/w5on/visibility')\" = public ] && [ \"\$(cat '$W5/data/state/w5priv/visibility')\" = private ] && [ \"\$(cat '$W5/data/state/w5unk/visibility')\" = unknown ]"

# ---- the README ----
awk '/^## Status site/ {f = 1; next} /^## / {f = 0} f' "$src/../README.md" >"$tmp/readme-site.txt"
w05_readme_when() { local f=$tmp/readme-site.txt; grep -iE 'link' "$f" | grep -qiE 'public' && grep -qE 'https://' "$f" && grep -qiE 'site.{0,40}link|link.{0,60}site' "$f"; }
ok "W05-AC-1: README's status-site section names ~/.config/noodlebot/site" grep -qF '~/.config/noodlebot/site' "$tmp/readme-site.txt"
ok "W05-AC-1: README's status-site section says when links appear (https address, public repository, the loop publishes)" w05_readme_when

loop_end
