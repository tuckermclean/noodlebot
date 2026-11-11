#!/bin/sh
# Test of scheduler/loops.sh (start | stop | status), part: the runtime root, the tmux server's environment, the probe races.
#   sh scheduler/loops-root.test.sh   (make test)
# The cases and helpers are in testdata/lib/loops-body.sh, which runs the cases of the parts named here; the
# parts run at the same time (each has its own temporary folder, and only its own processes are matched by pkill/pgrep).
parts="B B2"
. "$(cd "$(dirname "$0")" && pwd -P)/testdata/lib/loops-body.sh"
