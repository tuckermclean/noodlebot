#!/bin/sh
# Tests the role guard (guard.py) and the plugin's generic role agents, part: cd and pushd, stash, roles.yaml as a spec path, quoting, subshells, line continuation, other repositories.
#   sh plugin/hooks/guard-shell.test.sh   (make test)
# The cases and helpers are in scheduler/testdata/lib/guard-body.sh, which runs the cases of the parts named here; the
# parts run at the same time (each has its own temporary folder).
parts="3"
. "$(cd "$(dirname "$0")" && pwd -P)/../../scheduler/testdata/lib/guard-body.sh"
