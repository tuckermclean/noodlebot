#!/bin/sh
# Tests scheduler/report.py: the first review of the log issue and its rollover (R1 to R5).
#   sh scheduler/report-review.test.sh   (make test)
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
# Slice 2 review (R1-R5), regression cases.
# R1: a unit held by FAILED because its PR was closed unmerged is logged "session X03 ended (rc 143), held by FAILED" (loop.sh).
xinit r1failed
echo "2026-04-10T16:00:00Z open=[X03] merged-prs=[X00 X01]; session X03 ended (rc 143), held by FAILED" >>"$xs/status.log"
xrun 2026-04-11T00:05:00; xrun 2026-04-11T00:10:00
xnew=$(xq "L('2026-04-11')[0]['number']")
xq "'\n----\n'.join(c['body'] for c in C($xold) if '3.75' in c['body'])" >"$tmp/xsum"
xq "C($xnew)[0]['body']" >"$tmp/xfirst"
ok "U02-AC-4: (R1 held by FAILED) the closing summary names X03, whose line says 'held by FAILED', as a FAILED unit" sh -c "grep FAILED '$tmp/xsum' | grep -q X03"
ok "U02-AC-4: (R1 held by FAILED) it still names X02, which wrote FAILED" sh -c "grep FAILED '$tmp/xsum' | grep -q X02"
ok "U02-AC-4: (R1 held by FAILED) the overview's previous-day summary names X03 as a FAILED unit" sh -c "grep FAILED '$tmp/xfirst' | grep -q X03"

# R2: the old log issue is deleted; every call on it is a 404. The rest of the run still happens.
xinit r2gone
xgbin=$tmp/xgbin; mkdir -p "$xgbin"
cat >"$xgbin/gh" <<EOT
#!/bin/sh
case "\$4" in
*/issues/$xold|*/issues/$xold/*|*/issues/$xold\?*) echo "HTTP 404: Not Found (https://api.github.com/x)" >&2; exit 1 ;;
esac
exec "$xbin/gh" "\$@"
EOT
chmod +x "$xgbin/gh"
xrung() { env PATH="$xgbin:$xbin:$PATH" TZ=UTC NOODLEBOT_NOW="$1" NOODLEBOT_LIVE="$vlive" python3 -I "$src/report.py" --repo owner/repo --state "$xs" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/xerr"; }
pyc "
import json
db = json.load(open('$xdb')); del db['issues']['$xold']; db['comments'] = [c for c in db['comments'] if c['issue'] != '$xold']; json.dump(db, open('$xdb', 'w'))"
printf 'Q1: unique-x03-question\n' >"$xs/node/X03/QUESTION.md"
xrung 2026-04-11T00:05:00
xrung 2026-04-11T00:10:00; xrcg=$?
xrung 2026-04-11T09:00:00; xrcg3=$?
xnew=$(xq "L('2026-04-11')[0]['number']")
ok "U02-AC-4: (R2 old issue deleted) the new day's issue is opened, once" test "$(xq "len(L('2026-04-11'))")" = 1
ok "U02-AC-4: (R2 old issue deleted) the second run, and the third, exit 0" test "$xrcg$xrcg3" = 00
ok "U02-AC-4: (R2 old issue deleted) one overview on the new issue over the runs (the day's cost \$3.75 once)" test "$(xq "len([c for c in C($xnew) if '3.75' in c['body']])")" = 1
xowner "$xnew" "X03: go right"
xrung 2026-04-11T09:10:00; xrcg=$?
ok "U02-AC-4: (R2 old issue deleted) a prefixed owner answer on the new log issue is still recorded: exit 3" test "$xrcg" = 3
ok "U02-AC-4: (R2 old issue deleted) X03's ANSWER.md holds the answer" grep -q '^X03: go right$' "$xs/node/X03/ANSWER.md" 2>/dev/null
xrung 2026-04-11T09:20:00; xrung 2026-04-11T09:30:00
ok "U02-AC-4: (R2 old issue deleted) over all the runs: one new issue, one overview, no other issue for the day" test "$(xq "len(L('2026-04-11'))")$(xq "len([c for c in C($xnew) if '3.75' in c['body']])")" = 11

# R3: the link on the old issue (#200) keeps failing past the next midnight. #201 is the pending day's issue.
xinit r3pending
printf '%s' '^(POST|PATCH) \S*/issues/200(/comments)?( |$)' >"$tmp/xfail"
printf '%s' "db['issues']['200']['state'] == 'closed' and any(i['title'] == 'noodlebot log 2026-04-11' for i in db['issues'].values())" >"$tmp/xcond"
xrun 2026-04-11T00:05:00; xrc1=$?
xrun 2026-04-11T08:00:00
xr3a=$(xq "L('2026-04-11')[0]['number']")
printf '503 node/X05-five 2026-04-11T12:00:00Z true\n' >>"$xs/closed-prs.tsv"
xrun 2026-04-12T00:05:00
xr3b=$(xq "L('2026-04-12')[0]['number']")
ok "U02-AC-4: (R3 link pending) (precondition) the link on the old issue failed on the first run and has not been made" test "$xrc1" != 0 -a "$(xlinks 200 "$xr3a")" = False
ok "U02-AC-4: (R3 link pending) on the day after, the pending day's issue gets its closing summary (its merged PR #503) once, and is closed" test "$(xq "len([c for c in C($xr3a) if '503' in c['body']])")$(xq "db['issues']['$xr3a']['state']")" = 1closed
ok "U02-AC-4: (R3 link pending) the newest issue (2026-04-12) is opened once" test "$(xq "len(L('2026-04-12'))")" = 1
ok "U02-AC-4: (R3 link pending) the newest issue links the pending day's issue" test -n "$xr3b" -a "$(xlinks "$xr3b" "$xr3a")" = True
ok "U02-AC-4: (R3 link pending) the newest issue does not link the older one (#200)" test "$(xlinks "$xr3b" 200)" = False
rm -f "$tmp/xfail" "$tmp/xcond"
xrun 2026-04-12T00:10:00; xrun 2026-04-12T09:00:00; xrun 2026-04-12T09:10:00
ok "U02-AC-4: (R3 link pending) once the link step works, the old issue (#200) links the pending day's issue exactly once" test "$(xq "len([s for s in [db['issues']['200']['body']] + [c['body'] for c in C(200)] if re.search(r'#%s\b|/issues/%s\b' % ($xr3a, $xr3a), s)])")" = 1
ok "U02-AC-4: (R3 link pending) the pending day's issue has one closing summary and one close over the runs, and no third day's issue exists" test "$(xq "len([c for c in C($xr3a) if '503' in c['body']])")$(grep -c "^PATCH $xr3a state=closed" "$tmp/xlog")$(xq "len([i for i in db['issues'].values() if i['title'].startswith('noodlebot log ')])")" = 113

# R4: the old sticky (non-log) status issue is unpinned when it is closed.
xdeploy
xrun 2026-04-10T09:00:00
ok "U02-AC-5: (R4 sticky issue) the old sticky issue (#70) is closed" test "$(xq "db['issues']['70']['state']")" = closed
ok "U02-AC-5: (R4 sticky issue) unpinIssue is tried on its node id" sh -c "grep unpinIssue '$tmp/xgql' | grep -q 'I_70[^0-9]'"

# R5: at the rollover, unpinIssue on the old issue is tried before pinIssue on the new one (GitHub allows 3 pins).
xinit r5order
xrun 2026-04-11T00:05:00; xrun 2026-04-11T00:10:00
xnew=$(xq "L('2026-04-11')[0]['number']")
r5un=$(grep -n unpinIssue "$tmp/xgql" | grep "I_$xold[^0-9]" | head -n 1 | cut -d: -f1)
r5pin=$(grep -nE '(^|[^n])pinIssue' "$tmp/xgql" | grep "I_$xnew[^0-9]" | head -n 1 | cut -d: -f1)
ok "U02-AC-4: (R5 order) both calls were tried" test -n "$r5un" -a -n "$r5pin"
ok "U02-AC-4: (R5 order) unpinIssue on the old issue comes before pinIssue on the new one" sh -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]' _ "$r5un" "$r5pin"


if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
