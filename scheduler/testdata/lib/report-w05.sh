# Sourced by scheduler/report-w05.test.sh: one scripted scenario of report.py (W05 site links), run with or without --site.
# Needs $src, $tmp, pyc_setup, rs_script (report-sessions.sh) and the units fixture (report-units.sh: $ubin, $udb, $uclone's
# helpers are reused for the fake gh). w05_scenario <name> [<site>] builds a fresh database, state folder and clone under
# $tmp/<name>, runs report.py five times (day 2026-05-10, then the rollover into 2026-05-11) and leaves in $tmp/<name>/out:
#   all (every issue body and comment in order), logbody, overview, events, asksnote, summary, buildbody, c41, c42, c45,
#   qcopied (1 when the QUESTION.md text is in c42 byte for byte), rc (the exit codes of the five runs).
# Time and the host are pinned (NOODLEBOT_NOW, TZ=UTC, the session's mtime), so the "all" of a run without --site is the same
# text on every machine once w05_norm has run over it.
w05_scenario() {
	wd=$tmp/$1 wsite=${2:-}
	wdb=$wd/gh.json wbin=$wd/bin wstate=$wd/state wclone=$wd/clone wlive=$wd/live
	mkdir -p "$wbin" "$wstate/node/K03" "$wstate/node/K04" "$wstate/node/K05" "$wstate/node/K98" "$wd/out" "$wclone/nodes" "$wlive"
	pyc "
import json
issues = {str(n): {'number': n, 'title': 'Seeded %d' % n, 'body': '', 'labels': [], 'state': 'open', 'node_id': 'I_%d' % n} for n in range(41, 51)}
json.dump({'issues': issues, 'comments': [], 'labels': [], 'pulls': [], 'checks': {}, 'reactions': [], 'next': 200}, open('$wdb', 'w'))"
	sed "s#$udb#$wdb#g; s#$tmp/ufail#$wd/fail#g; s#$tmp/ucalls#$wd/calls#g" "$ubin/gh.py" >"$wbin/gh.py"
	fakegh_install "$wbin"
	for spec in "K06 six-name" "K07 seven-name" "K03 three-name"; do
		set -- $spec
		{
			printf '# %s - %s\n\n| Track | Deps | Unlocks | Size |\n|---|---|---|---|\n| now | none | none | S |\n\n**Owns:** nothing\n' "$1" "$2"
			case $1 in K07) echo '**Resolves:** #41' ;; K03) echo '**Resolves:** #42' ;; esac
			printf '\n## Purpose\nx\n'
		} >"$wclone/nodes/$1-$2.md"
	done
	git -C "$wclone" init -q -b main && git -C "$wclone" add nodes &&
		git -C "$wclone" -c user.name=t -c user.email=t@t commit -q -m specs &&
		git -C "$wclone" update-ref refs/remotes/origin/main HEAD
	git -C "$wlive" init -q -b main && git -C "$wlive" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "live one"
	cat >"$wstate/graph.yaml" <<'GRAPH'
nodes:
  - {id: K01, name: one-name, deps: []}
  - {id: K02, name: two-name, deps: [K01]}
  - {id: K03, name: three-name, deps: []}
  - {id: K04, name: four-name, deps: []}
  - {id: K05, name: five-name, deps: []}
  - {id: K06, name: six-name, deps: []}
  - {id: K07, name: seven-name, deps: []}
GRAPH
	: >"$wstate/merged-prs.txt"
	printf 'Q1: merge K01 before K02?\nSee [K02](https://example.com/q) and `K01`; K03 agrees.\nRecommendation: yes.\n' >"$wstate/node/K03/QUESTION.md"
	printf '2026-05-09T20:00:00Z 2 starts with no PR\n' >"$wstate/node/K05/FAILED"
	printf '2026-05-09T20:30:00Z unknown node, held\n' >"$wstate/node/K98/FAILED"
	r 0.5 1 >"$wstate/node/K04/session.jsonl"
	printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Working on K01 and K02 now."}]}}' >>"$wstate/node/K04/session.jsonl"
	sh "$tmp/rs/run-session.sh" --node K04 &
	wpid=$!
	trap 'kill $wpid 2>/dev/null; rm -rf "$tmp"' EXIT
	echo "$wpid" >"$wstate/node/K04/session.pid"
	rs_wait "$wpid"
	touch -d 2026-05-10T08:00:00Z "$wstate/node/K04/session.pid"
	printf '{"windows": {"five_hour": {"utilization": 0.62, "resetsAt": 1800000000, "status": "allowed"}, "seven_day": {"utilization": 0.4, "resetsAt": 1800500000, "status": "allowed"}}, "projected5h": 0.5, "weekElapsed": 0.5, "hold": false}' >"$wd/usage.json"
	{
		echo "2026-05-09T20:00:00Z open=[] merged-prs=[]; session K05 ended (rc 1), no PR, no QUESTION.md, 2 starts used: wrote FAILED"
		echo "2026-05-09T21:00:00Z open=[] merged-prs=[]; session K99 ended (rc 1), no PR, no QUESTION.md, 2 starts used: wrote FAILED"
	} >"$wstate/status.log"
	wrun 2026-05-10T09:00:00 1
	mkdir -p "$wstate/node/K06" "$wstate/node/K07" "$wstate/issue/45"
	{
		echo "2026-05-10T09:05:00Z open=[] merged-prs=[]; started K06 (six-name) in /wt, pid 5, start 1 of 2"
		echo "2026-05-10T09:05:01Z open=[] merged-prs=[]; started K07 (seven-name) in /wt, pid 6, start 1 of 2"
		echo "2026-05-10T09:05:02Z open=[] merged-prs=[]; started triage of #45 in /wt, pid 7, start 1 of 2"
		echo "2026-05-10T09:05:03Z open=[] merged-prs=[]; released K01 (answered) see \`K02\` and [K03](https://example.com/x) and https://example.com/K01 and K99"
	} >>"$wstate/status.log"
	wrun 2026-05-10T09:10:00 2
	printf '2026-05-10T09:19:00Z 2 starts with no PR\n' >"$wstate/node/K07/FAILED"
	{
		echo "2026-05-10T09:19:00Z open=[] merged-prs=[]; session K07 ended (rc 0), no PR, no QUESTION.md, 2 starts used: wrote FAILED"
		echo "2026-05-10T09:19:30Z open=[] merged-prs=[]; session K99 ended (rc 1), no PR, no QUESTION.md, 2 starts used: wrote FAILED"
	} >>"$wstate/status.log"
	wrun 2026-05-10T09:20:00 3
	wrun 2026-05-11T00:05:00 4
	wrun 2026-05-11T00:10:00 5
	kill "$wpid" 2>/dev/null
	W="$wd" Q="$wstate/node/K03/QUESTION.md" pyc "
import json, os
d = os.environ['W']; db = json.load(open(d + '/gh.json'))
out = lambda name, text: open(d + '/out/' + name, 'w').write(text)
cs = lambda n: [c['body'] for c in db['comments'] if c['issue'] == str(n)]
logs = [i for i in db['issues'].values() if i['title'] == 'noodlebot log 2026-05-10']
builds = [i for i in db['issues'].values() if i['title'].startswith('Build K06')]
n = logs[0]['number'] if logs else 0
out('logbody', logs[0]['body'] if logs else '')
out('overview', (cs(n) or [''])[0])
out('events', '\n'.join(c for c in cs(n) if c.startswith('- \`')))
out('asksnote', '\n'.join(c for c in cs(n) if 'The question is on #42' in c))
out('summary', '\n'.join(c for c in cs(n) if 'End-of-day summary' in c))
out('buildbody', builds[0]['body'] if builds else '')
for i in (41, 42, 45):
    out('c%d' % i, (cs(i) or [''])[0])
q = open(os.environ['Q']).read().strip()
out('qcopied', '1' if cs(42) and q in cs(42)[0] else '0')
out('all', ''.join('=== issue %s %s\n%s\n' % (i['number'], i['title'], i['body']) + ''.join('--- comment %s\n%s\n' % (c['id'], c['body']) for c in db['comments'] if c['issue'] == str(i['number']))
                   for i in sorted(db['issues'].values(), key=lambda i: i['number'])))"
}
# wrun <now> <n>: one run of report.py (with --site when $wsite is set); its exit code is appended to out/rc.
wrun() {
	env PATH="$wbin:$PATH" TZ=UTC NOODLEBOT_NOW="$1" NOODLEBOT_LIVE="$wlive" python3 -I "$src/report.py" --repo owner/repo \
		--state "$wstate" --worktrees "$tmp/worktrees/repo" --clone "$wclone" --owner owner ${wsite:+--site "$wsite"} 2>>"$wd/err"
	echo "$?" >>"$wd/out/rc"
}
# w05_norm <dir>: out/all with the temporary folder, the pids and the live checkout's commit made the same on every machine.
w05_norm() {
	sed "s#$1#TMP#g; s#pid [0-9][0-9]*)#pid N)#g; s#^\*\*Deployed:\*\* .*#**Deployed:** X#" "$1/out/all"
}
