#!/bin/sh
# Tests scheduler/report.py: the second review of the rollover (S1, S2) and the answers on the log issue after it (G4).
#   sh scheduler/report-regress.test.sh   (make test)
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
# Slice 2 re-review (S1, S2), regression cases. The closing summary is the comment on #200 holding the day's cost $3.75
# (not its heading); the next day's own summary is the comment on #201 holding its merged PR #503.
# S1: a single failed call of one rollover step (the first only; all others work) must not lose that step.
xcase_once() { # <name> <regex of the one call that fails once> <what fails>
	xinit "$1"
	printf '%s' "$2" >"$tmp/xfail"
	printf '%s' "'INJECTED' not in open('$tmp/xlog').read()" >"$tmp/xcond"
	xrun 2026-04-11T00:05:00; xrcs=$?
	ok "U02-AC-4: (S1 $3 fails once) (precondition) the first run on the new date fails, with exactly one injected failure" test "$xrcs" != 0 -a "$(grep -c '^INJECTED' "$tmp/xlog")" = 1
	xrun 2026-04-11T00:10:00; xrun 2026-04-11T00:15:00; xrun 2026-04-11T09:00:00; xrun 2026-04-11T09:10:00
	xnew=$(xq "L('2026-04-11')[0]['number']")
	ok "U02-AC-4: (S1 $3 fails once) the old issue has exactly one closing summary" test "$(xq "len([c for c in C($xold) if '3.75' in c['body']])")" = 1
	ok "U02-AC-4: (S1 $3 fails once) the old issue is closed, by one close" test "$(xq "db['issues']['$xold']['state']")$(grep -c "^PATCH $xold state=closed" "$tmp/xlog")" = closed1
	ok "U02-AC-4: (S1 $3 fails once) the old issue links the new one exactly once" test "$(xq "len([s for s in [db['issues']['$xold']['body']] + [c['body'] for c in C($xold)] if re.search(r'#%s\b|/issues/%s\b' % ($xnew, $xnew), s)])")" = 1
	ok "U02-AC-4: (S1 $3 fails once) the new day's issue exists once and links the old one" test "$(xq "len(L('2026-04-11'))")$(xlinks "$xnew" "$xold")" = 1True
}
xcase_once s1summary '^POST \S*/issues/200/comments' 'the closing summary post'
xcase_once s1close '^PATCH \S*/issues/200$' 'the close'

# S2/B: every write to the old issue (#200) fails until after the next local midnight (2026-04-12 00:05), then works.
xinit s2pending
printf '%s' '^(POST|PATCH) \S*/issues/200(/comments)?( |$)' >"$tmp/xfail"
xrun 2026-04-11T00:05:00; xrcb=$?
xrun 2026-04-11T08:00:00
xs2a=$(xq "L('2026-04-11')[0]['number']")
printf '503 node/X05-five 2026-04-11T12:00:00Z true\n' >>"$xs/closed-prs.tsv"
xrun 2026-04-12T00:05:00
rm -f "$tmp/xfail" "$tmp/xcond"
xrun 2026-04-12T00:10:00; xrun 2026-04-12T00:15:00; xrun 2026-04-12T09:00:00; xrun 2026-04-12T09:10:00; xrun 2026-04-12T09:20:00
xs2b=$(xq "L('2026-04-12')[0]['number']")
ok "U02-AC-4: (S2 pending past midnight) (precondition) the first run failed, and no write to #200 happened before the failures stopped" test "$xrcb" != 0 -a "$(grep -c '^PATCH 200 ' "$tmp/xlog")" -le 1
ok "U02-AC-4: (S2 pending past midnight) #200 ends with exactly one closing summary" test "$(xq "len([c for c in C(200) if '3.75' in c['body']])")" = 1
ok "U02-AC-4: (S2 pending past midnight) #200 is closed, by exactly one close" test "$(xq "db['issues']['200']['state']")$(grep -c '^PATCH 200 state=closed' "$tmp/xlog")" = closed1
ok "U02-AC-4: (S2 pending past midnight) #200 links its next issue (#$xs2a) exactly once" test "$(xq "len([s for s in [db['issues']['200']['body']] + [c['body'] for c in C(200)] if re.search(r'#%s\b|/issues/%s\b' % ($xs2a, $xs2a), s)])")" = 1
ok "U02-AC-4: (S2 pending past midnight) the next issue (#$xs2a) has exactly one closing summary (its merged PR #503) and is closed, by one close" test "$(xq "len([c for c in C($xs2a) if '503' in c['body']])")$(xq "db['issues']['$xs2a']['state']")$(grep -c "^PATCH $xs2a state=closed" "$tmp/xlog")" = 1closed1
ok "U02-AC-4: (S2 pending past midnight) no issue is opened twice for a date: one for each of 04-10, 04-11, 04-12" test "$(xq "len(L('2026-04-10'))")$(xq "len(L('2026-04-11'))")$(xq "len(L('2026-04-12'))")" = 111
ok "U02-AC-4: (S2 pending past midnight) the newest issue (2026-04-12) is open and links #$xs2a" test "$(xq "L('2026-04-12')[0]['state']")$(xlinks "$xs2b" "$xs2a")" = openTrue

# Fresh review finding 4 (G4), U02-AC-5 for log issues: a prefixed owner answer on a CLOSED log issue is recorded while the
# question it names was posted on that issue and is still open; not when posted elsewhere, answered, or gone; once.
xinit g4
for u in X01 X03 X04; do printf 'Q1: unique-%s-question\n' "$u" >"$xs/node/$u/QUESTION.md"; done
xrun 2026-04-10T10:00:00
ok "U02-AC-5: (G4) (precondition) the question pointers for X01, X03 and X04 are posted on day 1's log issue #$xold" test "$(xq "len([c for c in C($xold) if re.search(r'## X0[134] asks', c['body'])])")" = 3
printf 'X01 first answer\n' >"$xs/node/X01/ANSWER.md"
rm -f "$xs/node/X04/QUESTION.md"
xrun 2026-04-11T00:05:00; xrun 2026-04-11T00:10:00
xnew=$(xq "L('2026-04-11')[0]['number']")
printf 'Q1: unique-x02-question\n' >"$xs/node/X02/QUESTION.md"
xrun 2026-04-11T00:15:00
ok "U02-AC-5: (G4) (precondition) day 1's issue is closed, X02's question is posted on the new issue (#$xnew), not on #$xold" test "$(xq "db['issues']['$xold']['state']")$(xq "len([c for c in C($xnew) if '## X02 asks' in c['body']])")$(xq "len([c for c in C($xold) if '## X02 asks' in c['body']])")" = closed10
xowner "$xold" "X02: asked on another issue"
xowner "$xold" "X01: answered already"
xowner "$xold" "X04: question gone"
xrun 2026-04-11T09:00:00; xrc=$?
ok "U02-AC-5: (G4) answers on the closed log issue naming a question posted elsewhere (X02), answered (X01) or gone (X04) are not recorded (exit not 3)" test "$xrc" != 3
ok "U02-AC-5: (G4) no ANSWER.md for X02 and X04, and X01's is unchanged" sh -c "[ ! -e '$xs/node/X02/ANSWER.md' ] && [ ! -e '$xs/node/X04/ANSWER.md' ] && [ \"\$(cat '$xs/node/X01/ANSWER.md')\" = 'X01 first answer' ]"
ok "U02-AC-5: (G4) X03 is not answered yet" test ! -e "$xs/node/X03/ANSWER.md"
xowner "$xold" "X03: go up"
xrun 2026-04-11T09:10:00; xrc=$?
ok "U02-AC-5: (G4) an answer on the closed log issue naming X03, whose question was posted there and is open, is recorded: exit 3" test "$xrc" = 3
ok "U02-AC-5: (G4) X03's ANSWER.md holds the answer" grep -q '^X03: go up$' "$xs/node/X03/ANSWER.md" 2>/dev/null
ok "U02-AC-5: (G4) the bot replies that it recorded X03's answer" test "$(xq "len([c for c in db['comments'] if 'Recorded as X03' in c['body']])")" -ge 1
xg4r=$(xq "len([c for c in db['comments'] if 'Recorded as X03' in c['body']])")
xg4a=$(cat "$xs/node/X03/ANSWER.md" 2>/dev/null)
xrun 2026-04-11T09:20:00; xrun 2026-04-11T09:30:00
ok "U02-AC-5: (G4) the answer is recorded once: later runs add no reply and leave ANSWER.md as it was" test "$(xq "len([c for c in db['comments'] if 'Recorded as X03' in c['body']])")" = "$xg4r" -a "$(cat "$xs/node/X03/ANSWER.md" 2>/dev/null)" = "$xg4a"
ok "U02-AC-5: (G4) the refused answers are still not recorded" sh -c "[ ! -e '$xs/node/X02/ANSWER.md' ] && [ ! -e '$xs/node/X04/ANSWER.md' ] && [ \"\$(cat '$xs/node/X01/ANSWER.md')\" = 'X01 first answer' ]"

# G4, last tick: an answer posted on day 1's log issue after the last tick's read, before the rollover, is still recorded.
xinit g4last
printf 'Q1: unique-x03-question\n' >"$xs/node/X03/QUESTION.md"
xrun 2026-04-10T10:00:00
xrun 2026-04-10T23:55:00
xowner "$xold" "X03: said in the last tick"
xrun 2026-04-11T00:05:00; xrun 2026-04-11T00:10:00
ok "U02-AC-5: (G4 last tick) an answer posted on the log issue after the last tick's read is recorded after the rollover" grep -q '^X03: said in the last tick$' "$xs/node/X03/ANSWER.md" 2>/dev/null
ok "U02-AC-5: (G4 last tick) the old log issue was closed by the rollover" test "$(xq "db['issues']['$xold']['state']")" = closed

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
