#!/bin/sh
# Test of scheduler/loops.sh (start | stop | status), part: start passes SCHED_HARNESS to each loop (S08-AC-5).
#   sh scheduler/loops-s08.test.sh   (make test)
# The cases and helpers are in testdata/lib/loops-body.sh, which runs the cases of the parts named here.
parts="H"
. "$(cd "$(dirname "$0")" && pwd -P)/testdata/lib/loops-body.sh"
