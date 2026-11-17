#!/bin/bash
# A07-AC-2: an area unit whose WAITING-PR names a PR merged after the tick's fetch (the area still listed): no second
# session (nor one for the next area) and one status-log line in the tick that first sees it; the next tick whose fetch
# succeeds and still does not show it writes FAILED naming the PR; a tick whose fetch failed writes no FAILED.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
A07_TICK=2
. "$src/testdata/lib/loop-a07.sh"
a07_late two one 22 "area one"
chk "A07-AC-2: area one: nothing started for the second area while the first is held" test "$(a07_runs two)" = 0
loop_end
