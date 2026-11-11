#!/bin/sh
# Test of scheduler/loops.sh (start | stop | status), part: start, stop and status, the version line, the usage variables passed to the loops.
#   sh scheduler/loops-basic.test.sh   (make test)
# The cases and helpers are in testdata/lib/loops-body.sh, which runs the cases of the parts named here; the
# parts run at the same time (each has its own temporary folder, and only its own processes are matched by pkill/pgrep).
parts="A D F"
. "$(cd "$(dirname "$0")" && pwd -P)/testdata/lib/loops-body.sh"
