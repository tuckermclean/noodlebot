#!/bin/sh
# noodlebot's version: `git describe --tags --always` of a checkout, or "unknown".
#   version.sh [--signature] [<checkout>]
# Default checkout: the one this script lives in. --signature prints the line that ends every
# comment, PR body and commit message noodlebot writes: "— n00dl3b0t [<version>](<commit link>)",
# the link only when origin is a GitHub repository. Always exits 0.
sig=0
if [ "${1:-}" = --signature ]; then sig=1; shift; fi
dir=${1:-$(dirname "$0")/..}
v=$(cd "$dir" 2>/dev/null && git describe --tags --always 2>/dev/null) || v=
[ -n "$v" ] || v=unknown
if [ $sig = 0 ]; then echo "$v"; exit 0; fi
link=
if [ "$v" != unknown ]; then
	url=$(git -C "$dir" remote get-url origin 2>/dev/null)
	full=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
	# the forge module turns the remote's URL into the commit's link (none: origin is no forge repository it knows)
	out=$(python3 -I "$(dirname "$0")/forge.py" remote-commit-link "$url" "$full" 2>/dev/null) && { link=${out#\"}; link=${link%\"}; }
fi
if [ -n "$link" ]; then echo "— n00dl3b0t [$v]($link)"; else echo "— n00dl3b0t $v"; fi
exit 0
