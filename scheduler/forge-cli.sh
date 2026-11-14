#!/bin/sh
# forge-cli.sh ARGS...: the forge CLI (forge.py) for a session. run-session.sh exports NOODLEBOT_FORGE=<this file> and no
# token script variable, so a session holds no token and no way to fetch one except through here. This wrapper alone
# (and the loop, for its own helpers) names the token script: it exports NOODLEBOT_FORGE_TOKEN_SCRIPT, defaulting to
# ~/.config/noodlebot/token, for its own process only, then runs forge.py with the same arguments, output and exit codes.
here=$(cd "$(dirname "$0")" && pwd -P)
NOODLEBOT_FORGE_TOKEN_SCRIPT=${NOODLEBOT_FORGE_TOKEN_SCRIPT:-$HOME/.config/noodlebot/token}
export NOODLEBOT_FORGE_TOKEN_SCRIPT
exec python3 -I "$here/forge.py" "$@"
