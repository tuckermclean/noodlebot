#!/bin/bash
# G02: a limit exit uses no start, FAILED holds the PR. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g02.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g02.sh"

# The state the main run is in when it comes to these cases: the throttle open (an allowed window), the PRs of the main part not wanting an update.
g02_rl 0.01 $(($(date +%s) + 7200))
g02_prs 201 MERGEABLE; g02_prs 205 MERGEABLE
g02_loop 0
wait_ticks 1   # setup: the loop has run a tick (the main run was warm when it came to these cases)
# G02-AC-2: a limit exit uses no start; the second end without rc 0 writes FAILED; FAILED holds the PR.
g02_prs 206 CONFLICTING
ok "G02-AC-2: a limit exit uses no start: two starts are both start 1 of 2" waitf 12 g02_evis 206 'start 1 of 2' 2
ok "G02-AC-2: the second end without rc 0 writes FAILED" waitf 12 test -e "$state/pr/206/FAILED"
ok "G02-AC-2: the third start is start 2 of 2" g02_evis 206 'start 2 of 2' 1
ok "G02-AC-2: each of the three ends is one status-log event" waitf 5 g02_evis 206 'rc 1' 3
wait_ticks 3
ok "G02-AC-2: with FAILED there, the PR gets no update" g02_runsis 206 3
rm -f "$state/pr/206/FAILED"
ok "G02-AC-2: after FAILED is deleted it is started again" waitf 8 g02_runsis 206 4
ok "G02-AC-2: and that end (rc 0) is one more event" waitf 6 g02_evis 206 'rc 0' 1
g02_prs 206 MERGEABLE

g02_stop

loop_end
