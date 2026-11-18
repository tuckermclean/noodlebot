#!/bin/sh
# Tests scheduler/api.py (node P04), part: P04-AC-1, on its own root (its own data, HOME, checkout and server). /v1/deploy's
# last_deploy.repo and last_failed.repo name the live checkout's repository (its origin, read through a forge backend) whichever
# listed loop logged the line, and are that loop's repository when the checkout's cannot be read (no origin, or a remote no forge
# backend knows, such as a local path). Listed: acme/alpha, acme/beta; the live checkout is acme/beta's, the line is in alpha's log.
# The helpers are in testdata/lib/.
#   sh scheduler/api-p04.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
. "$src/testdata/lib/api-common.sh"
. "$src/testdata/lib/api-setup.sh"
sl=$data/state/alpha/status.log
SD=7777777777777777777777777777777777777777 SF=8888888888888888888888888888888888888888
printf '2026-11-09T12:00:00Z deployed %s (version v0.9.7-fixture)\n' "$SD" >>"$sl"
printf '2026-11-09T12:01:00Z not deployed: %s (version v0.9.8-fixture) fails make test\n' "$SF" >>"$sl"
grep -qx 'acme/beta' "$data/../home/.config/noodlebot/repos" 2>/dev/null || grep -q '^acme/beta' "$home/.config/noodlebot/repos" || fail "P04-AC-1: acme/beta is not a listed repository in the fixture"
[ -d "$data/state/beta" ] || fail "P04-AC-1: the fixture has no state folder for acme/beta"

restart() { # restart: stop the server and start it again, so that it reads the checkout's origin afresh
	[ -z "$srv_pid" ] || { kill "$srv_pid" 2>/dev/null; i=0; while [ $i -lt 50 ] && kill -0 "$srv_pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done; kill -9 "$srv_pid" 2>/dev/null; wait "$srv_pid" 2>/dev/null; }
	rm -f "$sock"
	start_server || { fail "P04-AC-1: the server did not start: $(head -c 200 "$tmp/api.out")"; return 1; }
}
both() { # both <repo> <what>: both entries are of that repository, with the lines and times written above
	chk P04-AC-1 "$2: last_deploy is of $1" "d['last_deploy']['repo'] == '$1' and d['last_deploy']['time'] == $(ep 2026-11-09T12:00:00Z) and d['last_deploy']['line'].startswith('deployed $SD')"
	chk P04-AC-1 "$2: last_failed is of $1" "d['last_failed']['repo'] == '$1' and d['last_failed']['time'] == $(ep 2026-11-09T12:01:00Z) and d['last_failed']['line'].startswith('not deployed: $SF')"
}

# no origin: the logging loop's repository (as before)
if restart; then
	get P04-AC-1 /v1/deploy deploy
	both acme/alpha "a live checkout with no origin"
fi
# an origin that is a local path: no forge backend knows it; forge.repo_of_remote's last two path parts (zeta/widgets) do not count
git -C "$co" remote add origin "$tmp/zeta/widgets"
if restart; then
	get P04-AC-1 /v1/deploy deploy
	both acme/alpha "a live checkout whose origin is a local path"
fi
# a readable origin: the live checkout's repository, though alpha's loop logged the lines
git -C "$co" remote set-url origin https://github.com/acme/beta.git
if restart; then
	get P04-AC-1 /v1/deploy deploy
	both acme/beta "a live checkout whose origin is github.com/acme/beta"
fi
git -C "$co" remote set-url origin git@github.com:acme/beta.git
if restart; then
	get P04-AC-1 /v1/deploy deploy
	both acme/beta "a live checkout whose origin is git@github.com:acme/beta.git"
fi

[ $fails = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
