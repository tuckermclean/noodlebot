#!/bin/bash
# A07-AC-2: a scaffold unit whose WAITING-PR names a PR merged after the tick's fetch (main still has no graph): no second
# session and one status-log line in the tick that first sees it; the next tick whose fetch succeeds and still does not
# show it writes FAILED naming the PR; a tick whose fetch failed writes no FAILED.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
A07_TICK=2
. "$src/testdata/lib/loop-a07.sh"
a07_late none scaffold 21 "scaffold"
loop_end
