# Sourced by scheduler/report*.test.sh that run the daily-rollover cases: the fake gh patched to log and to fail on demand
# ($xbin), the helpers over its database ($xdb) and xinit. Needs the units fixture (report-units.sh), report-sessions.sh and $vlive.
# U02-AC-4, U02-AC-5: the daily rollover, the old status issue's closing and the answers it still takes. Own database and
# fake gh (the U01 fake, patched: it logs each PATCH as "PATCH <n> state=<s> keys=<k,...>" and each GraphQL body, can fail a
# GraphQL call whose body matches $tmp/xgqlfail, and fails the calls matching $tmp/xfail only while the python expression
# in $tmp/xcond (over `db`) is true; each injected failure is logged as "INJECTED ..." in $tmp/xlog).
xroot=$tmp/x xbin=$tmp/xbin xdb=$tmp/xgh.json
mkdir -p "$xbin" "$xroot"
cat >"$tmp/xpatch.py" <<'PY'
import sys
src, dst, udb, ucalls, ufail, xdb, xcalls, xfail, xcond, xlog, xgql, xgqlfail = sys.argv[1:]
t = open(src).read().replace(udb, xdb).replace(ucalls, xcalls).replace(ufail, xfail)
def sub(old, new):
    global t
    if old not in t:
        sys.exit("xpatch: not found: " + old)
    t = t.replace(old, new)
sub('if mode and re.search(mode, desc):',
    'if mode and re.search(mode, desc) and eval(open(%r).read() if os.path.exists(%r) else "True"):' % (xcond, xcond))
sub('print("HTTP 502: injected failure for " + desc, file=sys.stderr)',
    'open(%r, "a").write("INJECTED " + desc + "\\n"); print("HTTP 502: injected failure for " + desc, file=sys.stderr)' % xlog)
sub('    if method == "PATCH": db["issues"][n].update(body)',
    '    if method == "PATCH":\n        open(%r, "a").write("PATCH %%s state=%%s keys=%%s\\n" %% (n, body.get("state"), ",".join(sorted(body))))\n        db["issues"][n].update(body)' % xlog)
sub('elif p == "graphql":',
    'elif p == "graphql":\n    open(%r, "a").write(json.dumps(body) + "\\n")\n    if os.path.exists(%r) and re.search(open(%r).read().strip(), json.dumps(body)):\n        print("HTTP 403: injected graphql failure", file=sys.stderr); sys.exit(1)' % (xgql, xgqlfail, xgqlfail))
open(dst, "w").write(t)
PY
python3 -I "$tmp/xpatch.py" "$ubin/gh.py" "$xbin/gh.py" "$udb" "$tmp/ucalls" "$tmp/ufail" "$xdb" "$tmp/xcalls" "$tmp/xfail" "$tmp/xcond" "$tmp/xlog" "$tmp/xgql" "$tmp/xgqlfail" 2>"$tmp/xpatch.err"
fakegh_install "$xbin"
xrun() { env PATH="$xbin:$PATH" TZ=UTC NOODLEBOT_NOW="$1" NOODLEBOT_LIVE="$vlive" python3 -I "$src/report.py" --repo owner/repo --state "$xs" --worktrees "$tmp/worktrees/repo" --clone "$uclone" --owner owner 2>"$tmp/xerr"; }
# xq <python expr>: evaluated with db, L(<date>) (the issues titled 'noodlebot log <date>') and C(<issue>) (its comments).
xq() {
	pyc "
import json, re, sys
db = json.load(open('$xdb'))
def L(d): return [i for i in db['issues'].values() if i['title'] == 'noodlebot log ' + d]
def C(n): return [c for c in db['comments'] if c['issue'] == str(n)]
print(eval(sys.argv[1]))" "$1" 2>/dev/null
}
# xlinks <from> <to>: True when issue <from> (its body or one of its comments) links issue <to>.
xlinks() { xq "any(re.search(r'#%s\b|/issues/%s\b' % ($2, $2), s) for s in [db['issues']['$1']['body']] + [c['body'] for c in C($1)])"; }
xowner() {
	pyc "
import json, sys
db = json.load(open('$xdb'))
db['comments'].append({'id': len(db['comments']) + 1, 'issue': sys.argv[1], 'body': sys.argv[2], 'user': {'login': 'owner', 'type': 'User'},
    'author_association': 'OWNER', 'created_at': '2026-04-10T10:00:00Z', 'html_url': 'https://x/x%s' % (len(db['comments']) + 1)})
json.dump(db, open('$xdb', 'w'))" "$1" "$2"
}
xpins() { grep -cE '(^|[^n])pinIssue' "$tmp/xgql"; }
xunpins() { grep -c unpinIssue "$tmp/xgql"; }
# xcore: the old issue's comment count, the number of issues for 2026-04-11, the closes of the old issue, the new issue's comment count.
xcore() { printf '%s %s %s %s' "$(xq "len(C($xold))")" "$(xq "len(L('2026-04-11'))")" "$(grep -c "^PATCH $xold state=closed" "$tmp/xlog")" "$(xq "len(C($xnew))")"; }
xclean() { rm -f "$tmp/xfail" "$tmp/xcond" "$tmp/xgqlfail"; : >"$tmp/xlog"; : >"$tmp/xgql"; }

# xinit <name>: a fresh database and state folder for the day 2026-04-10, and two runs that day (so today's log issue is
# $xold, number 200). The day's events: X01 ended (cost $2.50) and its PR #501 merged; X02 ended (cost $1.25) and wrote
# FAILED; X03's PR #502 was opened; X04 ended the day before (cost $9.99) and PR #499 was merged the day before.
xinit() {
	xs=$xroot/$1 xnew=''
	rm -rf "$xs"; mkdir -p "$xs/node/X01" "$xs/node/X02" "$xs/node/X03" "$xs/node/X04"
	xclean
	pyc "
import json
mk = lambda n, t: {'number': n, 'title': t, 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_%d' % n}
issues = {str(n): mk(n, 'Unit X0%d' % (n - 60)) for n in range(61, 65)}
pr = {'number': 502, 'head': {'ref': 'node/X03-three', 'sha': 'x3sha'}, 'created_at': '2026-04-10T10:00:00Z', 'html_url': 'https://github.com/owner/repo/pull/502'}
json.dump({'issues': issues, 'comments': [], 'labels': ['noodlebot-status'], 'pulls': [pr], 'checks': {}, 'reactions': [], 'next': 200}, open('$xdb', 'w'))"
	r 2.5 3 >"$xs/node/X01/session.jsonl"
	r 1.25 2 >"$xs/node/X02/session.jsonl"
	r 9.99 9 >"$xs/node/X04/session.jsonl"
	printf '2026-04-10T15:00:00Z second exit (rc 1) with no PR and no QUESTION.md\n' >"$xs/node/X02/FAILED"
	for n in 1 2 3 4; do echo "6$n" >"$xs/node/X0$n/issue"; done
	printf '499 node/X00-old\n501 node/X01-one\n' >"$xs/merged-prs.tsv"
	printf '499\n501\n' >"$xs/merged-prs.txt"
	printf '499 node/X00-old 2026-04-09T12:00:00Z true\n501 node/X01-one 2026-04-10T12:00:00Z true\n' >"$xs/closed-prs.tsv"
	printf '502 node/X03-three x3sha false MERGEABLE\n' >"$xs/open-prs.tsv"
	{
		echo "2026-04-09T22:00:00Z open=[] merged-prs=[X00]; session X04 ended (rc 0)"
		echo "2026-04-10T10:00:00Z open=[X03] merged-prs=[X00]; started X03 (three) in /wt, pid 3, start 1 of 2"
		echo "2026-04-10T12:00:00Z open=[X03] merged-prs=[X00 X01]; session X01 ended (rc 0)"
		echo "2026-04-10T15:00:00Z open=[X03] merged-prs=[X00 X01]; session X02 ended (rc 1), no PR, no QUESTION.md, 2 starts used: wrote FAILED"
	} >"$xs/status.log"
	xrun 2026-04-10T09:00:00; xrun 2026-04-10T09:30:00
	xold=$(xq "L('2026-04-10')[0]['number']")
	xclean
}
# U02-AC-5, first deploy (review F2): an open noodlebot-status issue titled like the old sticky one, no log issue. It had
# questions asked on it before the switch (A01 open, A03 answered, A04 closed); A02 and A06 ask on their unit issues.
xdeploy() {
	xs=$xroot/deploy xnew=''
	rm -rf "$xs"; mkdir -p "$xs/node/A01" "$xs/node/A02" "$xs/node/A03" "$xs/node/A04" "$xs/node/A05" "$xs/node/A06"
	xclean
	printf 'Q1: unique-a01-question\n' >"$xs/node/A01/QUESTION.md"
	printf 'Q1: unique-a02-question\n' >"$xs/node/A02/QUESTION.md"
	printf 'Q1: unique-a03-question\n' >"$xs/node/A03/QUESTION.md"
	printf 'A03 first answer\n' >"$xs/node/A03/ANSWER.md"
	printf 'Q1: unique-a06-question\n' >"$xs/node/A06/QUESTION.md"
	for n in 1 2 3 4 5 6; do echo "8$n" >"$xs/node/A0$n/issue"; done
	echo "2026-04-09T20:00:00Z open=[] merged-prs=[]; session A04 ended (rc 0)" >"$xs/status.log"
	pyc "
import json
mk = lambda n, t, lab: {'number': n, 'title': t, 'body': '', 'labels': lab, 'state': 'open', 'node_id': 'I_%d' % n}
issues = {str(n): mk(n, 'Unit A0%d' % (n - 80), []) for n in range(81, 87)}
issues['70'] = dict(mk(70, 'noodlebot status', ['noodlebot-status']), body='OLD STICKY BODY')
bot = lambda i, n: {'id': i, 'issue': '70', 'body': '## %s asks\n\nQ1: x\n\n---\nTo answer, reply to this issue in plain words. Only owner\'s replies count.\n' % n,
    'user': {'login': 'bot', 'type': 'Bot'}, 'author_association': 'NONE', 'created_at': '2026-04-09T08:00:00Z', 'html_url': 'https://x/old%d' % i}
json.dump({'issues': issues, 'comments': [bot(1, 'A01'), bot(2, 'A03'), bot(3, 'A04')], 'labels': ['noodlebot-status'], 'pulls': [], 'checks': {},
           'reactions': [], 'next': 200}, open('$xdb', 'w'))"
	printf '{"issue": 70, "comment_id": 3, "log_offset": %s, "questions": {"A01": "%s", "A03": "%s", "A04": "1"}, "body_hash": "x", "body_time": 0}\n' \
		"$(wc -c <"$xs/status.log")" "$(stat -c %Y "$xs/node/A01/QUESTION.md")" "$(stat -c %Y "$xs/node/A03/QUESTION.md")" >"$xs/report.json"
}
