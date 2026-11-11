#!/bin/sh
# Tests the role guard (guard.py) and the plugin's generic role agents, part: git commit and add with staged paths, heredocs, fd redirects, sed and directory operands.
#   sh plugin/hooks/guard-git.test.sh   (make test)
# The cases and helpers are in scheduler/testdata/lib/guard-body.sh, which runs the cases of the parts named here; the
# parts run at the same time (each has its own temporary folder).
parts="2"
. "$(cd "$(dirname "$0")" && pwd -P)/../../scheduler/testdata/lib/guard-body.sh"
