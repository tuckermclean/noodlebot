#!/bin/sh
# forge-cli.sh ARGS...: the forge CLI (forge.py) for a session. run-session.sh exports NOODLEBOT_FORGE=<this file> and no
# token script variable, so a session holds no token and no way to fetch one except through here. This wrapper alone
# (and the loop, for its own helpers) names the token script: a NOODLEBOT_FORGE_TOKEN_SCRIPT the caller set is kept;
# unset or empty, it becomes ~/.config/noodlebot/token when that file is executable, and otherwise stays unset so
# forge.py uses no token (gh uses its own login). It is exported for this process only, then forge.py runs with the
# same arguments, output and exit codes.
here=$(cd "$(dirname "$0")" && pwd -P)
if [ -z "${NOODLEBOT_FORGE_TOKEN_SCRIPT:-}" ]; then
	unset NOODLEBOT_FORGE_TOKEN_SCRIPT
	[ ! -x "$HOME/.config/noodlebot/token" ] || NOODLEBOT_FORGE_TOKEN_SCRIPT=$HOME/.config/noodlebot/token
fi
[ -z "${NOODLEBOT_FORGE_TOKEN_SCRIPT:-}" ] || export NOODLEBOT_FORGE_TOKEN_SCRIPT
exec python3 -I "$here/forge.py" "$@"
