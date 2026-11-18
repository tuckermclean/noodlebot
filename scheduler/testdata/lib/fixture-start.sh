#!/bin/sh
# fixture-start.sh <command> [args...]: fixture_start (fixture.sh) as a command, for a start that an `env` runs:
#   ( exec env VAR=val sh .../fixture-start.sh bash loop.sh ... ) &
# The process keeps its pid and becomes the fixture, in its own session, with a watch as fixture_start does.
. "$(dirname "$0")/fixture.sh"
fixture_start "$@"
