#!/bin/bash
# W02: the publish step and the visibility record. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-w02.sh). Missing files; visibility.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-w02.sh"

# W02-AC-5: a missing file: one line per start, no publish
for mode in none gist; do
	w02_run "sn$mode" "$mode" ok false
	w02_wait 20 sh -c "[ \"\$(grep -c 'state/sn$mode' /dev/null)\" = 0 ] && grep -q 'started A02' '$w02_state/status.log' 2>/dev/null"
	wait_ticks 3 "$w02_state"
	w02_stop
	ok "W02-AC-5: with files '$mode' the status log says once: status site off: no gist configured" test "$(w02_n 'status site off: no gist configured')" = 1
	ok "W02-AC-5: with files '$mode' the loop ticked and made no publish and no gist PATCH" sh -c "! grep -qE '^(publish|patch)' '$W02/order.log' && ! grep -q 'gists/' '$W02/gh-args.log'"
done
# a restart writes one more line
w02_run snnone none ok false
w02_wait 10 sh -c "grep -qF 'status site off' '$w02_state/status.log' 2>/dev/null"
w02_stop; rm -f "$HOME/STOP-snnone"
w02_run snnone none ok false
wait_ticks 3 "$w02_state"; w02_stop
ok "W02-AC-5: a second start gives a second 'site off' line (one line per start)" test "$(w02_n 'status site off: no gist configured')" = 2


# W02-AC-6: private, unknown (asked again on the next tick), public
w02_run svp none ok true
w02_wait 15 sh -c "[ -s '$w02_state/visibility' ]"
wait_ticks 3 "$w02_state"
w02_stop
ok "W02-AC-6: a private repository is recorded as private" test "$(cat "$w02_state/visibility" 2>/dev/null)" = private
ok "W02-AC-6: a known (private) visibility is asked once only" test "$(w02_cnt . "$W02/vis.svp.log")" = 1
w02_run svu none ok fail
w02_wait 15 sh -c "[ -s '$w02_state/visibility' ]"
wait_ticks 2 "$w02_state"
unknown_v=$(cat "$w02_state/visibility" 2>/dev/null)
asked_while_unknown=$(w02_cnt . "$W02/vis.svu.log")
echo false >"$W02/vis-mode.svu"
w02_wait 10 sh -c "[ \"\$(cat '$w02_state/visibility' 2>/dev/null)\" = public ]"
w02_stop
ok "W02-AC-6: a failed call is recorded as unknown" test "$unknown_v" = unknown
ok "W02-AC-6: an unknown is asked again on the next tick (asked more than once while it failed)" test "$asked_while_unknown" -ge 2
ok "W02-AC-6: once the call succeeds the record becomes public" test "$(cat "$w02_state/visibility" 2>/dev/null)" = public


loop_end
