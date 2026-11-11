#!/bin/sh
# Tests scheduler/report.py: the daily rollover of the log issue (U02-AC-4).
#   sh scheduler/report-rollover.test.sh   (make test)
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
ok "U02-AC-4: (harness) the patched fake gh was written" test -s "$xbin/gh" -a ! -s "$tmp/xpatch.err"
# The rollover, clean: the first run on 2026-04-11 and two more.
xinit rollover
ok "U02-AC-4: (before the new date) today's log issue is open and holds no closing summary" test "$(xq "db['issues']['$xold']['state']")$(xq "len([c for c in C($xold) if '3.75' in c['body']])")" = open0
xrun 2026-04-11T00:05:00; xrc=$?
xnew=$(xq "L('2026-04-11')[0]['number']")
xrun 2026-04-11T00:10:00; xrun 2026-04-11T09:00:00; xrc3=$?
xq "'\n----\n'.join(c['body'] for c in C($xold) if '3.75' in c['body'])" >"$tmp/xsum"
xq "C($xnew)[0]['body']" >"$tmp/xfirst"
ok "U02-AC-4: (rollover) the runs on the new date succeed" test "$xrc$xrc3" = 00
ok "U02-AC-4: (rollover) exactly one closing summary is posted on the old log issue (one comment holds the day's cost \$3.75)" test "$(xq "len([c for c in C($xold) if '3.75' in c['body']])")" = 1
ok "U02-AC-4: (rollover) the summary has the day's summed cost of ended sessions (X01 2.50 + X02 1.25)" grep -qF '$3.75' "$tmp/xsum"
ok "U02-AC-4: (rollover) the summary does not count a session that ended the day before (X04 \$9.99)" sh -c "! grep -qF '9.99' '$tmp/xsum'"
ok "U02-AC-4: (rollover) the summary has the PR merged that day (#501) and not the one merged the day before (#499)" sh -c "grep -q '501' '$tmp/xsum' && ! grep -q '499' '$tmp/xsum'"
ok "U02-AC-4: (rollover) the summary has the PR opened that day (#502)" grep -q '502' "$tmp/xsum"
ok "U02-AC-4: (rollover) the summary names the unit that wrote FAILED (X02) on a FAILED line" sh -c "grep FAILED '$tmp/xsum' | grep -q X02"
ok "U02-AC-4: (rollover) the old log issue is closed, once" test "$(xq "db['issues']['$xold']['state']")$(grep -c "^PATCH $xold state=closed" "$tmp/xlog")" = closed1
ok "U02-AC-4: (rollover) the new day's issue is opened once, titled 'noodlebot log 2026-04-11', open and labelled noodlebot-status" test "$(xq "len(L('2026-04-11'))")$(xq "L('2026-04-11')[0]['state']")$(xq "'noodlebot-status' in L('2026-04-11')[0]['labels']")" = 1openTrue
ok "U02-AC-4: (rollover) the new issue links the old one (body or a comment)" test "$(xlinks "$xnew" "$xold")" = True
ok "U02-AC-4: (rollover) a link to the new issue is put on the old one (body or a comment)" test "$(xlinks "$xold" "$xnew")" = True
ok "U02-AC-4: (rollover) pinIssue is tried on the new issue (a GraphQL mutation naming its node id)" sh -c "grep -E '(^|[^n])pinIssue' '$tmp/xgql' | grep -q 'I_$xnew[^0-9]'"
ok "U02-AC-4: (rollover) unpinIssue is tried on the old issue (a GraphQL mutation naming its node id)" sh -c "grep unpinIssue '$tmp/xgql' | grep -q 'I_$xold[^0-9]'"
ok "U02-AC-4: (rollover) over the three runs: one new issue, one close, one pin, one unpin" test "$(xcore | cut -d' ' -f2-3) $(xpins) $(xunpins)" = "1 1 1 1"
ok "U02-AC-4: (rollover) the runs leave nothing on stderr" test ! -s "$tmp/xerr"
ok "U02-AC-4: (F3) the new day's overview (its first comment) is the same summary: the cost \$3.75" grep -qF '$3.75' "$tmp/xfirst"
ok "U02-AC-4: (F3) the overview has the previous day's merged PR (#501) and opened PR (#502)" sh -c "grep -q '501' '$tmp/xfirst' && grep -q '502' '$tmp/xfirst'"
ok "U02-AC-4: (F3) the overview names the unit that wrote FAILED (X02) on a FAILED line" sh -c "grep FAILED '$tmp/xfirst' | grep -q X02"
ok "U02-AC-4: (F3) the overview does not have the merge of the day before (#499) or the cost \$9.99" sh -c "! grep -q '499' '$tmp/xfirst' && ! grep -qF '9.99' '$tmp/xfirst'"
xref=$(xcore)
ok "U02-AC-4: (rollover) (precondition) the reference counts are real (old issue comments, one new issue, one close, new issue comments)" test "$(echo "$xref" | cut -d' ' -f2-3)" = "1 1"

# A failing pin or unpin changes nothing else: everything else is as in the clean rollover.
xcase_gql() { # <name> <regex on the GraphQL body that fails> <what fails>
	xinit "$1"
	printf '%s' "$2" >"$tmp/xgqlfail"
	xrun 2026-04-11T00:05:00
	xnew=$(xq "L('2026-04-11')[0]['number']")
	xrun 2026-04-11T00:10:00; xrun 2026-04-11T09:00:00
	ok "U02-AC-4: ($3 fails) the rest happens as usual: the old issue's comments, the new issue, the close and the new issue's comments are as in the clean rollover" test "$(xcore)" = "$xref"
	ok "U02-AC-4: ($3 fails) the summary is posted once, the old issue is closed, the links are both there" sh -c "[ \"\$1\" = 1 ] && [ \"\$2\" = closed ] && [ \"\$3\" = True ] && [ \"\$4\" = True ]" _ "$(xq "len([c for c in C($xold) if '3.75' in c['body']])")" "$(xq "db['issues']['$xold']['state']")" "$(xlinks "$xnew" "$xold")" "$(xlinks "$xold" "$xnew")"
}
xcase_gql pinfails '(^|[^n])pinIssue' 'pin'
ok "U02-AC-4: (pin fails) pinIssue was tried on the new issue" sh -c "grep -E '(^|[^n])pinIssue' '$tmp/xgql' | grep -q 'I_$xnew[^0-9]'"
ok "U02-AC-4: (pin fails) unpinIssue was still tried on the old issue, once" test "$(xunpins)" = 1
xcase_gql unpinfails 'unpinIssue' 'unpin'
ok "U02-AC-4: (unpin fails) unpinIssue was tried on the old issue" sh -c "grep unpinIssue '$tmp/xgql' | grep -q 'I_$xold[^0-9]'"
ok "U02-AC-4: (unpin fails) pinIssue was still tried on the new issue, once" test "$(xpins)" = 1
xcase_gql bothfail 'pinIssue' 'pin and unpin'
ok "U02-AC-4: (pin and unpin fail) both were tried" test "$(xpins)" -ge 1 -a "$(xunpins)" -ge 1

# A run that fails after a step finishes the rest on the next run, no step repeated: one summary, one close, one new issue,
# one link each way (the pin and the unpin are tried once, and so not again). The run is cut by failing every call from the
# step on; the failure is then removed and three runs follow.
xcase_cut() { # <name> <python condition for the failure to start> <what was done>
	xinit "$1"
	printf '%s' '.' >"$tmp/xfail"
	printf '%s' "$2" >"$tmp/xcond"
	xrun 2026-04-11T00:05:00; xrcc=$?
	ok "U02-AC-4: (cut after $3) (precondition) the first run on the new date fails" test "$xrcc" != 0 -a "$(grep -c '^INJECTED' "$tmp/xlog")" -ge 1
	rm -f "$tmp/xfail" "$tmp/xcond"
	xrun 2026-04-11T00:10:00; xrun 2026-04-11T00:15:00; xrun 2026-04-11T09:00:00
	xnew=$(xq "L('2026-04-11')[0]['number']")
	ok "U02-AC-4: (cut after $3) the next runs finish it: the counts are those of the uninterrupted rollover" test "$(xcore)" = "$xref"
	ok "U02-AC-4: (cut after $3) one closing summary, one close, the old issue closed" test "$(xq "len([c for c in C($xold) if '3.75' in c['body']])")$(grep -c "^PATCH $xold state=closed" "$tmp/xlog")$(xq "db['issues']['$xold']['state']")" = 11closed
	ok "U02-AC-4: (cut after $3) the links both ways are there" sh -c "[ \"\$1\" = True ] && [ \"\$2\" = True ]" _ "$(xlinks "$xnew" "$xold")" "$(xlinks "$xold" "$xnew")"
	ok "U02-AC-4: (cut after $3) pin and unpin were each done once over the runs" test "$(xpins) $(xunpins)" = "1 1"
}
xcase_cut cutsummary "any('3.75' in c['body'] for c in db['comments'] if c['issue'] == '200')" "the summary post"
xcase_cut cutclose "db['issues']['200']['state'] == 'closed'" "the close"
xcase_cut cutnew "any(i['title'] == 'noodlebot log 2026-04-11' for i in db['issues'].values())" "the new issue opens"
xcase_cut cutlink "any(re.search(r'#201\b|/issues/201\b', s) for s in [db['issues']['200']['body']] + [c['body'] for c in db['comments'] if c['issue'] == '200'])" "the link on the old issue"


if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
