#!/bin/sh
# Tests the role guard (guard.py) and the plugin's generic role agents, part: the agents, the skill, the hook wiring, the role decisions by path (R01-AC-1, R01-AC-2).
#   sh plugin/hooks/guard-roles.test.sh   (make test)
# The cases and helpers are in scheduler/testdata/lib/guard-body.sh, which runs the cases of the parts named here; the
# parts run at the same time (each has its own temporary folder).
parts="1"
. "$(cd "$(dirname "$0")" && pwd -P)/../../scheduler/testdata/lib/guard-body.sh"
