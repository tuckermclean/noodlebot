#!/bin/sh
# Tests scheduler/api.py (node D07), part: D07-AC-7, on its own root (its own data, HOME, checkout and server). /v1/deploy's
# last_failed is the latest "not deployed:" line also when that line is a CI rejection ("... fails CI: ...") or a smoke-check
# rejection ("... fails the smoke check: ..."), as it is for "... fails make test". The helpers are in testdata/lib/.
#   sh scheduler/api-d07.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
. "$src/testdata/lib/api-common.sh"
. "$src/testdata/lib/api-setup.sh"
up=0
if start_server; then up=1; else fail "D07-AC-7: the server did not start: $(head -c 200 "$tmp/api.out")"; fi
sl=$data/state/alpha/status.log
S1=3333333333333333333333333333333333333333 S2=4444444444444444444444444444444444444444
S3=5555555555555555555555555555555555555555 S4=6666666666666666666666666666666666666666
ci_line="not deployed: $S1 (version v0.9.2-fixture) fails CI: test.yml run 1234 failure"
smoke_line="not deployed: $S2 (version v0.9.3-fixture) fails the smoke check: scheduler/bad.sh"
mt_line="not deployed: $S3 (version v0.9.4-fixture) fails make test"
ff_line="not deployed: $S4 (version v0.9.5-fixture) cannot fast-forward /live (will retry the fast-forward)"
lastfailed() { # lastfailed <time> <line>: last_failed is that entry of acme/alpha
	chk D07-AC-7 "$3" "d['last_failed'] == {'repo': 'acme/alpha', 'time': $(ep "$1"), 'line': '$2'}"
}
get D07-AC-7 /v1/deploy deploy
printf '2026-11-09T12:00:00Z %s\n' "$ci_line" >>"$sl"
req GET /v1/deploy
lastfailed 2026-11-09T12:00:00Z "$ci_line" "/v1/deploy's last_failed is a CI rejection when it is the latest 'not deployed:' line"
printf '2026-11-09T12:01:00Z %s\n' "$smoke_line" >>"$sl"
req GET /v1/deploy
lastfailed 2026-11-09T12:01:00Z "$smoke_line" "/v1/deploy's last_failed is a smoke-check rejection when it is the latest 'not deployed:' line"
printf '2026-11-09T12:02:00Z %s\n' "$mt_line" >>"$sl"
req GET /v1/deploy
lastfailed 2026-11-09T12:02:00Z "$mt_line" "/v1/deploy's last_failed is still the latest 'fails make test' line (as before)"
printf '2026-11-09T12:03:00Z %s\n' "$ff_line" >>"$sl"
req GET /v1/deploy
lastfailed 2026-11-09T12:02:00Z "$mt_line" "/v1/deploy's last_failed does not take a 'cannot fast-forward' line (unchanged)"
printf '2026-11-09T12:04:00Z %s\n' "$ci_line" >>"$sl"
req GET /v1/deploy
lastfailed 2026-11-09T12:04:00Z "$ci_line" "/v1/deploy's last_failed is the CI rejection again once it is the latest (after a make test line)"
to_line="not deployed: $S4 (version v0.9.6-fixture) smoke check timed out or was killed 3 times"
printf '2026-11-09T12:05:00Z %s\n' "$to_line" >>"$sl"
req GET /v1/deploy
lastfailed 2026-11-09T12:05:00Z "$to_line" "/v1/deploy's last_failed is a smoke-check timeout line when it is the latest 'not deployed:' line"
get D07-AC-7 /v1/deploy deploy

[ $fails = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
