#!/bin/bash
# A07-AC-4 (listings): a running adoption session (adopt/scaffold, held by the fake claude) is listed by scheduler/status.sh as
# a RUNNING session and by `scheduler/loops.sh status` in its "sessions:" list; neither says "none".
# Assumed (the spec leaves the label open): the listing names the unit, so the word "scaffold" is on the status.sh session line
# (a line starting "== " with RUNNING) and in loops.sh's "sessions: ..." field; status.sh is run on the fake forge's spec.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-a07.sh"

a07_fork a07
touch "$A07/hold.scaffold"
a07_run a07
need "A07-AC-4 setup: the adoption session runs (session.pid, the fake claude started)" 15 a07_logged '^scaffold run 1 '
need "A07-AC-4 setup: the unit has a session.pid" 15 test -s "$(a07_ud scaffold)/session.pid"
sp=$A07/status.out lp=$A07/loops.out
NOODLEBOT_DATA=$g04data bash "$G04/nb/scheduler/status.sh" "fake:$G04/fk/a07" >"$sp" 2>&1
printf 'fake:%s\n' "$G04/fk/a07" >"$HOME/.config/noodlebot/repos"
NOODLEBOT_DATA=$g04data bash "$G04/nb/scheduler/loops.sh" status >"$lp" 2>&1
list_ok() { grep -E '^== .*RUNNING' "$sp" | grep -qi scaffold; }
chk "A07-AC-4: status.sh lists the running adoption session (a == line with RUNNING naming the unit)" list_ok
chk "A07-AC-4: status.sh does not say that no session runs" test -z "$(grep -F 'sessions: none running' "$sp")"
chk "A07-AC-4: loops.sh status lists it under sessions:" sh -c "grep -E 'sessions: [^;]*scaffold' '$lp'"
chk "A07-AC-4: loops.sh status does not say sessions: none" test -z "$(grep -F 'sessions: none' "$lp")"
a07_stop
loop_end
