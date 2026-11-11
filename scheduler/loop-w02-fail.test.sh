#!/bin/bash
# W02: the publish step and the visibility record. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-w02.sh). Failure and recovery.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-w02.sh"

# W02-AC-5: the first failure after the start is one line, repeated failures add none, the recovery is one line
rm -rf "$W02/data/site"   # the sf case starts with no publish record: the 60 s min-interval spans all loops of the machine
w02_run sf both 500 false
w02_wait 20 w02_ge '^publish' "$W02/order.log" 4
w02_wait 20 w02_ge '^patch' "$W02/order.log" 4   # the fourth failed call has been made (the checks below say "four ticks failed")
failed_lines=$(w02_n 'status site: publish failed (')
sitelog_lines=$(wc -l <"$w02_state/site.log" 2>/dev/null || echo 0)
echo ok >"$W02/patch-mode"
w02_wait 15 sh -c "grep -qF 'status site: publishing again' '$w02_state/status.log'"
wait_ticks 2 "$w02_state"
w02_stop
ok "W02-AC-5: the first failure is one status line 'status site: publish failed (<status>)' naming the status" sh -c "[ '$failed_lines' = 1 ] && grep -qE 'status site: publish failed \(.*500.*\)\$' '$w02_state/status.log'"
ok "W02-AC-5: repeated failures add no status line (four ticks failed, one line in all)" sh -c "[ \"\$(grep -c '^patch' '$W02/order.log')\" -ge 5 ] && [ \"\$(grep -cF 'status site: publish failed (' '$w02_state/status.log')\" = 1 ]"
ok "W02-AC-5: repeated failures are in site.log (stderr of the publish)" test "$sitelog_lines" -ge 2
ok "W02-AC-5: the recovery is one 'status site: publishing again' line" test "$(w02_n 'status site: publishing again')" = 1
ok "W02-AC-5: the recovery line comes after the failure line" sh -c "[ \"\$(grep -nF 'status site: publish failed (' '$w02_state/status.log' | head -1 | cut -d: -f1)\" -lt \"\$(grep -nF 'status site: publishing again' '$w02_state/status.log' | head -1 | cut -d: -f1)\" ]"
ok "W02-AC-5: the failing loop kept working (a node session started)" sh -c "ls '$W02'/env.* >/dev/null 2>&1 && grep -qE 'started A02' '$w02_state/status.log'"
ok "W02-AC-5: the token is in nothing under the runtime root after failures" sh -c "! grep -rqF -- '$W02TOK' '$W02/data'"

# W02-AC-5: a failure after a success is one line; after a recovery a second failure is one more line
rm -rf "$W02/data/site"
w02_run sr both ok false
w02_wait 20 w02_ge '^patch' "$W02/order.log" 1
sr_ok_patches=$(w02_cnt '^patch' "$W02/order.log")
sr_fail_before=$(w02_n 'status site: publish failed (')
echo 500 >"$W02/patch-mode"; rm -f "$W02/data/site/published.json"   # a record from the success would hold the next PATCH back (60 s)
w02_wait 20 sh -c "grep -qF 'status site: publish failed (' '$w02_state/status.log'"
wait_ticks 2 "$w02_state"
sr_fail1=$(w02_n 'status site: publish failed (')
echo ok >"$W02/patch-mode"
w02_wait 15 sh -c "grep -qF 'status site: publishing again' '$w02_state/status.log'"
echo 500 >"$W02/patch-mode"; rm -f "$W02/data/site/published.json"
w02_wait 20 sh -c "[ \"\$(grep -cF 'status site: publish failed (' '$w02_state/status.log')\" -ge 2 ]"
wait_ticks 2 "$w02_state"
w02_stop
sr_failn() { grep -nF 'status site: publish failed (' "$w02_state/status.log" | sed -n "$1p" | cut -d: -f1; }
sr_again() { grep -nF 'status site: publishing again' "$w02_state/status.log" | head -1 | cut -d: -f1; }
ok "W02-AC-5: a publish succeeded first (a PATCH went through and no failure line yet)" sh -c "[ '$sr_ok_patches' -ge 1 ] && [ '$sr_fail_before' = 0 ]"
ok "W02-AC-5: the first failure after a success is one 'status site: publish failed (<status>)' line naming 500" sh -c "[ '$sr_fail1' = 1 ] && grep -qE 'status site: publish failed \(.*500.*\)\$' '$w02_state/status.log'"
ok "W02-AC-5: after the recovery a second failure is one more line (two failure lines in all)" test "$(w02_n 'status site: publish failed (')" = 2
ok "W02-AC-5: the order is failure, 'publishing again', failure" sh -c "a=\$(grep -nF 'status site: publish failed (' '$w02_state/status.log' | sed -n 1p | cut -d: -f1); r=\$(grep -nF 'status site: publishing again' '$w02_state/status.log' | head -1 | cut -d: -f1); b=\$(grep -nF 'status site: publish failed (' '$w02_state/status.log' | sed -n 2p | cut -d: -f1); [ -n \"\$a\" ] && [ -n \"\$r\" ] && [ -n \"\$b\" ] && [ \"\$a\" -lt \"\$r\" ] && [ \"\$r\" -lt \"\$b\" ]"
ok "W02-AC-5: the recovery is still one 'publishing again' line" test "$(w02_n 'status site: publishing again')" = 1


loop_end
