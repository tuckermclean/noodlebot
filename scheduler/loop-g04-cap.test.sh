#!/bin/bash
# G04-AC-7: the fake forge lacks the capability `site`, site publishing is configured (gist and gist-token files): the
# status log says `forge fake lacks site: site publishing off` once per loop start, nothing is published, ticks go on.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g04.sh"

g04_gh_fail
g04_fake fk2 pin,resolve_threads,visibility
fk=$G04/fk/fk2
st=$g04data/state/fk2
echo gistid >"$HOME/.config/noodlebot/gist"; printf 'fake-gist-token' >"$HOME/.config/noodlebot/gist-token"; chmod 600 "$HOME/.config/noodlebot/gist-token"
: >"$G04/order.log"
line='forge fake lacks site: site publishing off'
n_line() { local n; n=$(grep -cF "$line" "$st/status.log" 2>/dev/null); echo "${n:-0}"; }
has_line() { [ "$(n_line)" -ge 1 ]; }
tick_ok=1
for start in 1 2; do
	g04_run "fake:$fk" fk2
	ticked=0
	# the tick count is the condition for every check of "it did not happen": without ticks in state/fk2 they all fail at once
	if wait_until 12 g04_ticking "$st" && wait_ticks 3 "$st"; then ticked=1; fi
	if [ "$ticked" = 1 ]; then
		pass "G04-AC-7: start $start: the tick carries on (the loop made three more ticks in state/fk2)"
		ok "G04-AC-7: start $start: the status log says '$line'" wait_until 5 has_line
		ok "G04-AC-7: start $start: the line is there exactly $start time(s) in all (once per loop start, not once per tick)" test "$(n_line)" = "$start"
		ok "G04-AC-7: start $start: no publish was attempted" test ! -s "$G04/order.log"
		ok "G04-AC-7: start $start: no 'status site' line of a publish ('publish failed', 'no gist configured')" sh -c "! grep -qE 'status site|no gist' '$st/status.log'"
		ok "G04-AC-7: start $start: nothing was written to the fake forge's site.json" test ! -s "$fk/site.json"
	else
		for c in "the tick carries on (the loop made three more ticks in state/fk2)" "the status log says '$line'" \
			"the line is there exactly $start time(s) in all (once per loop start, not once per tick)" "no publish was attempted" \
			"no 'status site' line of a publish ('publish failed', 'no gist configured')" "nothing was written to the fake forge's site.json"; do
			fail "G04-AC-7: start $start: $c"
		done
	fi
	g04_stop
	[ "$ticked" = 1 ] || break
done
if [ "$ticked" = 1 ]; then ok "G04-AC-7: the failing gh was never called" test ! -e "$G04/gh.called"; else fail "G04-AC-7: the failing gh was never called (the loop did not tick on the fake forge)"; fi
loop_end
