#!/bin/bash
# W02: the publish step and the visibility record. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-w02.sh). Publishing, SCHED_SITE=0, README.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-w02.sh"

# W02-AC-5: both files present, patches succeed
w02_run sp both ok false
w02_wait 20 w02_ge '^publish' "$W02/order.log" 3
w02_wait 10 sh -c "ls '$W02'/env.* >/dev/null 2>&1"
w02_stop
ok "W02-AC-5: every tick runs the publish (at least three publish calls in three ticks)" w02_ge '^publish' "$W02/order.log" 3
ok "W02-AC-5: the publish runs after report on every tick (each report line is followed by a publish line)" sh -c "
	[ \"\$(grep -c '^report' '$W02/order.log')\" -ge 3 ] && grep -v '^patch' '$W02/order.log' | awk '/^report/ {if (want) bad=1; want=1; next} /^publish/ {if (!want) bad=1; want=0; next} END {exit bad}'"
ok "W02-AC-5: the publish step is site.py publish for --gist w02gistid" sh -c "grep '^publish' '$W02/order.log' | grep -q -- 'publish .*--gist w02gistid'"
ok "W02-AC-5: GH_TOKEN of every publish equals the token file's contents" sh -c "[ -s '$W02/ghtok.log' ] && ! grep -vxF -- '$W02TOK' '$W02/ghtok.log'"
ok "W02-AC-5: the gist PATCH is made with that GH_TOKEN" sh -c "grep '^patch' '$W02/order.log' | grep -qxF 'patch GH_TOKEN=$W02TOK' && ! grep '^patch' '$W02/order.log' | grep -vxF 'patch GH_TOKEN=$W02TOK'"
ok "W02-AC-5: the token is on no command line (publish arguments, gh arguments)" sh -c "[ -s '$W02/gh-args.log' ] && ! grep -qF -- '$W02TOK' '$W02/gh-args.log' && ! grep -E '^publish' '$W02/order.log' | grep -qF -- '$W02TOK'"
ok "W02-AC-5: the token is in nothing under the runtime root (status.log, site.log, report.log, sessions)" sh -c "[ -s '$w02_state/status.log' ] && ! grep -rqF -- '$W02TOK' '$W02/data'"
ok "W02-AC-5: a node session started in that loop ran, and its environment and prompt lack the gist token" sh -c "ls '$W02'/env.* >/dev/null 2>&1 && ls '$W02'/prompt.* >/dev/null 2>&1 && ! grep -qF -- '$W02TOK' '$W02'/env.* '$W02'/prompt.*"
ok "W02-AC-5: no failure and no 'publishing again' line when every publish succeeds" sh -c "! grep -qE 'status site: (publish failed|publishing again)' '$w02_state/status.log'"
ok "W02-AC-5: with both files present the loop does not say the site is off" sh -c "! grep -qF 'status site off' '$w02_state/status.log'"
ok "W02-AC-6: a public repository is recorded as public" test "$(cat "$w02_state/visibility" 2>/dev/null)" = public
ok "W02-AC-6: visibility is asked with gh api repos/o/sp --jq .private and the label step's App token" sh -c "grep -qxF 'api repos/o/sp --jq .private GH_TOKEN=fake-token' '$W02/vis.sp.log'"
ok "W02-AC-6: a known visibility is asked once, not on every tick" test "$(w02_cnt . "$W02/vis.sp.log")" = 1


# W02-AC-5: SCHED_SITE=0 runs no publish
w02_run s0 both ok false SCHED_SITE=0
w02_wait 20 sh -c "grep -q 'started A02' '$w02_state/status.log' 2>/dev/null"
wait_ticks 3 "$w02_state"
w02_stop
ok "W02-AC-5: SCHED_SITE=0 runs no publish (and no gist PATCH) although both files exist" sh -c "! grep -qE '^(publish|patch)' '$W02/order.log' && ! grep -q 'gists/' '$W02/gh-args.log'"
ok "W02-AC-5: SCHED_SITE=0: the loop still ticked, report ran each tick" w02_ge '^report' "$W02/order.log" 2

# W02-AC-5: the README
ok "W02-AC-5: README names ~/.config/noodlebot/gist" grep -Eq '~/\.config/noodlebot/gist([^-]|$)' "$src/../README.md"
ok "W02-AC-5: README names ~/.config/noodlebot/gist-token" grep -q '~/\.config/noodlebot/gist-token' "$src/../README.md"
ok "W02-AC-5: README names the token's only scope, gist" grep -Eiq '(only|just).{0,40}`?gist`? (scope|permission)|`gist` scope|scope.{0,30}`gist`' "$src/../README.md"


loop_end
