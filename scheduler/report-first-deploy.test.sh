#!/bin/sh
# Tests scheduler/report.py: an owner closing the log issue, the first deploy over an old status issue and the answers the log issue takes (U02-AC-4, U02-AC-5, U02-AC-6).
#   sh scheduler/report-first-deploy.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
fakegh_lib=$src/testdata/lib
. "$fakegh_lib/report-fakegh.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
pyc_setup
. "$fakegh_lib/report-units.sh"
. "$fakegh_lib/report-sessions.sh"
rs_script
vlive=$tmp/vlive
mkdir -p "$vlive"
git -C "$vlive" init -q -b main && git -C "$vlive" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "live one"
. "$fakegh_lib/report-rollover.sh"
# The owner closes today's issue: the next run opens a new one for the same day, linked from the closed one.
xinit ownerclose
pyc "
import json
db = json.load(open('$xdb')); db['issues']['$xold']['state'] = 'closed'; json.dump(db, open('$xdb', 'w'))"
xrun 2026-04-10T10:00:00; xrc=$?
xrun 2026-04-10T10:10:00; xrun 2026-04-10T10:20:00
xnew=$(xq "[i['number'] for i in L('2026-04-10') if i['state'] == 'open'][0]")
ok "U02-AC-4: (owner closes today's issue) the runs succeed" test "$xrc" = 0
ok "U02-AC-4: (owner closes today's issue) a new issue is opened for the same day: two issues for 2026-04-10, one open, one closed" test "$(xq "len(L('2026-04-10'))")$(xq "len([i for i in L('2026-04-10') if i['state'] == 'open'])")" = 21
ok "U02-AC-4: (owner closes today's issue) the new one is not the closed one" test -n "$xnew" -a "$xnew" != "$xold"
ok "U02-AC-4: (owner closes today's issue) the closed issue links the new one (body or a comment)" test "$(xlinks "$xold" "$xnew")" = True
ok "U02-AC-4: (owner closes today's issue) later runs open no third issue" test "$(xq "len(L('2026-04-10'))")" = 2

xdeploy
xrun 2026-04-10T09:00:00; xrc=$?
dc1=$(xq "len(C(70))")
xrun 2026-04-10T09:10:00
echo "2026-04-10T09:15:00Z open=[] merged-prs=[]; session A05 ended (rc 0)" >>"$xs/status.log"
xrun 2026-04-10T09:20:00; xrun 2026-04-10T09:30:00
xlog=$(xq "L('2026-04-10')[0]['number']")
ok "U02-AC-5: (first deploy) the runs succeed" test "$xrc" = 0
ok "U02-AC-5: (first deploy) with the old status issue open, a new 'noodlebot log 2026-04-10' issue is opened, once, open and labelled noodlebot-status" test "$(xq "len(L('2026-04-10'))")$(xq "L('2026-04-10')[0]['state']")$(xq "'noodlebot-status' in L('2026-04-10')[0]['labels']")" = 1openTrue
ok "U02-AC-5: (first deploy) the old status issue (#70) is closed" test "$(xq "db['issues']['70']['state']")" = closed
ok "U02-AC-5: (first deploy) it is closed with exactly one comment linking today's log issue" test "$(xq "len([c for c in C(70) if re.search(r'#%s\b|/issues/%s\b' % ($xlog, $xlog), c['body'])])")" = 1
ok "U02-AC-5: (first deploy) that is the one comment the loop added to it (3 earlier ones, then 4), and the second run added none" test "$dc1 $(xq "len(C(70))")" = "4 4"
ok "U02-AC-5: (first deploy) the old issue's body is not edited" test "$(xq "db['issues']['70']['body']")" = "OLD STICKY BODY" -a "$(grep -c '^PATCH 70 .*keys=.*body' "$tmp/xlog")" = 0
ok "U02-AC-5: (first deploy) the old issue is closed once" test "$(grep -c '^PATCH 70 state=closed' "$tmp/xlog")" = 1
ok "U02-AC-5: (first deploy) an event (A05 ended) is not a comment on the old issue" test "$(xq "len([c for c in C(70) if 'session A05 ended' in c['body']])")" = 0
ok "U02-AC-5: (first deploy) the event is on the log issue instead" test "$(xq "len([c for c in C($xlog) if 'session A05 ended' in c['body']])")" = 1

# A prefixed owner answer on the closed old issue: recorded only while the question it names was posted there and is open.
xowner 70 "A02: not asked here"
xowner 70 "A03: answered already"
xowner 70 "A04: question closed"
xowner 70 "A05: no question"
xrun 2026-04-10T10:05:00; xrc=$?
ok "U02-AC-5: (old issue) answers naming a question not posted there (A02), answered (A03), closed (A04) or absent (A05) are not recorded (exit not 3)" test "$xrc" != 3
ok "U02-AC-5: (old issue) no ANSWER.md for A02, A04, A05, and A03's is unchanged" sh -c "[ ! -e '$xs/node/A02/ANSWER.md' ] && [ ! -e '$xs/node/A04/ANSWER.md' ] && [ ! -e '$xs/node/A05/ANSWER.md' ] && [ \"\$(cat '$xs/node/A03/ANSWER.md')\" = 'A03 first answer' ]"
ok "U02-AC-5: (old issue) A01 is not answered yet" test ! -e "$xs/node/A01/ANSWER.md"
xowner 70 "A01: go left"
xrun 2026-04-10T10:10:00; xrc=$?
ok "U02-AC-5: (old issue) an answer naming A01, whose question was posted there and is open, is recorded: exit 3" test "$xrc" = 3
ok "U02-AC-5: (old issue) A01's ANSWER.md holds the answer" grep -q '^A01: go left$' "$xs/node/A01/ANSWER.md" 2>/dev/null
ok "U02-AC-5: (old issue) the bot replies that it recorded A01's answer" test "$(xq "len([c for c in db['comments'] if \"Recorded as A01\" in c['body']])")" -ge 1
ok "U02-AC-5: (old issue) the earlier refused answers are still not recorded" sh -c "[ ! -e '$xs/node/A02/ANSWER.md' ] && [ ! -e '$xs/node/A04/ANSWER.md' ] && [ ! -e '$xs/node/A05/ANSWER.md' ] && [ \"\$(cat '$xs/node/A03/ANSWER.md')\" = 'A03 first answer' ]"

# A prefixed owner answer on the log issue is recorded as on the status issue before.
xowner "$xlog" "A06: from the log issue"
xrun 2026-04-10T10:15:00; xrc=$?
ok "U02-AC-5: (log issue) a prefixed answer on today's log issue is recorded: exit 3" test "$xrc" = 3
ok "U02-AC-5: (log issue) A06's ANSWER.md holds the answer, with where it came from" sh -c "grep -q '^A06: from the log issue\$' '$xs/node/A06/ANSWER.md' && grep -q 'posted by owner on GitHub at 2026-04-10T10:00:00Z' '$xs/node/A06/ANSWER.md'"
ok "U02-AC-5: (log issue) the bot replies that it recorded A06's answer" test "$(xq "len([c for c in db['comments'] if \"Recorded as A06\" in c['body']])")" -ge 1

# U02-AC-6, the README part: "Watching it" links the repository's open noodlebot-status issues, as a stable search URL.
readme=$(cd "$src/.." && pwd -P)/README.md
watching() { awk '/^## Watching it/ { f = 1; next } f && /^## / { f = 0 } f' "$readme"; }
ok "U02-AC-6: README.md has a 'Watching it' section" test -n "$(watching)"
ok "U02-AC-6: it links the open noodlebot-status issues (an issues search URL with label:noodlebot-status and is:open)" sh -c "$(printf '%s' "watching() { awk '/^## Watching it/ { f = 1; next } f && /^## / { f = 0 } f' '$readme'; }; watching | grep -oE 'https://github\\.com/[^ )>]*/issues\\?[^ )>]*' | grep -E 'label(:|%3A)noodlebot-status' | grep -Eq 'is(:|%3A)open'")"


if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
