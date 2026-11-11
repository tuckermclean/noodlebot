# Shared by loop-g03*.test.sh (source after loop-prelude.sh): the fixture of the G03 (PR feedback) end-to-end runs.
# It builds on the G01 fixture (testdata/lib/loop-g01.sh: loop o/up, remote $tmp/remote6.git, loop6, rl6, runsis ...)
# and replaces its open PRs, `gh` and `claude`:
#   PR 11 node/X01-first        bot    node X01's PR            unit state/up/node/X01/, worktree worktrees/up/X01
#   PR 12 node/X02-followup-1   bot    a follow-up PR of X02    unit state/up/node/X02/, worktree worktrees/up/X02
#   PR 13 spec/c1               bot    a spec PR (MERGEABLE, no clash: no update)   unit state/up/pr/13/, worktrees/up/pr-13
#   PR 14 spec/human            human  a human's spec PR
# (no FAILED anywhere, no ready node: X01 and X02 have open PRs). The fake gh answers `pr list` as G01's does and
# `gh api --paginate repos/o/up/{issues|pulls}/<N>/{comments|reviews}` from $GD/fb/<issues|pulls>-<N>-<comments|reviews>.json
# (the owner is "o"); $GD/fb.fail makes those calls fail. fbadd <N> <conversation|line|review> <id> <body> [k=v...] adds an
# item (login=, assoc=, state=, path=, line=, reply=); IDs must be above 110 so that they are newer than the first run's record.
# The fake claude logs "<kind> <key> run <n> <prompt> | <pwd> | <branch> | <HEAD>" to $GD/claude.log, kind and key being
#   fbnode <PR>    /noodlebot:node --feedback <PR>        fbspec <PR>   /noodlebot:triage --feedback <PR>
#   update <PR>    /noodlebot:triage --update <PR>        triage t      /noodlebot:triage <issue>
# its id is <kind>.<key>. It copies the unit's FEEDBACK.md to $GD/fbseen.<id>.<run> and the system prompt (the rendered
# prompt) to $GD/sys.<id>.<run>, holds while $GD/hold.<id> exists, writes QUESTION.md when $GD/question.<id>.<run> exists,
# makes the run a usage-limit exit when $GD/limit.<id>.<run> exists and exits with the code in $GD/rc.<id>.<run> (default 0).
. "$src/testdata/lib/loop-g01.sh"
wt6=$data6/worktrees/up
g01branch node/X01-first "${g01base}  - {id: X03, name: n1, deps: []}\n"
g01branch node/X02-followup-1 "${g01base}  - {id: X03, name: n2, deps: []}\n"
rm -f "$GD"/hold.* "$GD"/limit.* "$GD"/rc.* "$GD_STATE/node/X01/FAILED" "$GD_STATE/node/X02/FAILED"
cat >"$GD/prs.tsv" <<'EOF'
11 node/X01-first app/noodlebot true MERGEABLE
12 node/X02-followup-1 app/noodlebot true MERGEABLE
13 spec/c1 app/noodlebot true MERGEABLE
14 spec/human tuckermclean false MERGEABLE
EOF
mkdir -p "$GD/fb" "$GD_STATE/pr"
echo "$state/node/X01" >"$GD/udir.11"; echo "$state/node/X02" >"$GD/udir.12"; echo "$state/pr/13" >"$GD/udir.13"
cat >"$GD/fbadd.py" <<'EOF'
import json, os, sys
GD = os.environ["GD"]
n, kind, iid, body = sys.argv[1:5]
o = dict(a.split("=", 1) for a in sys.argv[5:])
iid = int(iid)
login = o.get("login", "o")
rec = {"id": iid, "user": {"login": login, "type": "User"},
       "author_association": o.get("assoc", "OWNER" if login == "o" else "NONE"), "body": body}
base = "https://github.com/o/up/pull/" + n
if kind == "conversation":
    f = "issues-%s-comments" % n
    rec.update(html_url=base + "#issuecomment-%d" % iid, created_at="2026-11-10T10:00:00Z")
elif kind == "line":
    f = "pulls-%s-comments" % n
    ln = int(o.get("line", "7"))
    rec.update(html_url=base + "#discussion_r%d" % iid, created_at="2026-11-10T10:00:00Z", path=o.get("path", "src/a.py"),
               line=ln, original_line=ln, in_reply_to_id=int(o["reply"]) if "reply" in o else None,
               pull_request_review_id=900)
else:
    f = "pulls-%s-reviews" % n
    rec.update(html_url=base + "#pullrequestreview-%d" % iid, submitted_at="2026-11-10T10:00:00Z",
               state=o.get("state", "COMMENTED"))
p = "%s/fb/%s.json" % (GD, f)
try:
    items = json.load(open(p))
except OSError:
    items = []
items.append(rec)
json.dump(items, open(p + ".tmp", "w"))
os.replace(p + ".tmp", p)
EOF
cat >"$tmp/bin6/gh" <<'EOF'
#!/bin/sh
case "$1 $2 $3" in
"api --paginate repos/o/up/"*)
	echo "$3" >>"$GD/fbcalls"
	[ -e "$GD/fb.fail" ] && { echo "gh: HTTP 502" >&2; exit 1; }
	f=$GD/fb/$(echo "${3#repos/o/up/}" | tr / -).json
	if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
	exit 0 ;;
esac
exec python3 -I "$GD/gh.py" "$@"
EOF
cat >"$tmp/bin6/claude" <<'EOF'
#!/bin/sh
p=$2
case "$p" in
"/noodlebot:node --feedback "*) kind=fbnode k=${p##* } ;;
"/noodlebot:triage --feedback "*) kind=fbspec k=${p##* } ;;
"/noodlebot:triage --update "*) kind=update k=${p##* } ;;
"/noodlebot:triage "*) kind=triage k=t ;;
*) kind=other k=${p##* } ;;
esac
id=$kind.$k
n=$(( $(cat "$GD/runs.$id" 2>/dev/null || echo 0) + 1 )); echo $n >"$GD/runs.$id"
while [ $# -gt 0 ]; do
	[ "$1" = --append-system-prompt ] && { printf '%s\n' "$2" >"$GD/sys.$id.$n"; break; }
	shift
done
u=$(cat "$GD/udir.$k" 2>/dev/null)
[ -n "$u" ] && [ -f "$u/FEEDBACK.md" ] && cp "$u/FEEDBACK.md" "$GD/fbseen.$id.$n"
echo "$kind $k run $n $p | $(pwd -P) | $(git branch --show-current 2>/dev/null) | $(git rev-parse HEAD 2>/dev/null)" >>"$GD/claude.log"
while [ -e "$GD/hold.$id" ]; do sleep 0.2; done
[ -e "$GD/question.$id.$n" ] && [ -n "$u" ] && echo "Q1: x" >"$u/QUESTION.md"
[ $kind = triage ] && echo "Q1: x" >"$GD_STATE/issue/46/QUESTION.md"
if [ -e "$GD/limit.$id.$n" ]; then
	echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1,"status":"rejected"}}}}'
	echo '{"type":"result","subtype":"error_during_execution","result":"You have hit your usage limit"}'
	exit 1
fi
exit "$(cat "$GD/rc.$id.$n" 2>/dev/null || echo 0)"
EOF
chmod +x "$tmp/bin6/gh" "$tmp/bin6/claude"

fbadd() { python3 -I "$GD/fbadd.py" "$@"; }
# fburl <PR> <conversation|line|review> <id>: the URL fbadd gives the item.
fburl() {
	case $2 in
	conversation) echo "https://github.com/o/up/pull/$1#issuecomment-$3" ;;
	line) echo "https://github.com/o/up/pull/$1#discussion_r$3" ;;
	review) echo "https://github.com/o/up/pull/$1#pullrequestreview-$3" ;;
	esac
}
g03_hold() { touch "$GD/hold.$1"; }
g03_release() { rm -f "$GD/hold.$1"; }
# g03_first: the loop's first feedback run is over (its record exists); items added after it are new feedback.
g03_first() { waitf 12 test -d "$state/feedback"; }
# g03_idle <unit dir>: no session of the unit (its pid file is gone).
g03_idle() { [ ! -e "$1/session.pid" ]; }
# g03_started <PR> <k>: status-log events of a feedback start of PR #<PR>, "start <k> of 2".
g03_started() { grep -E 'eedback' "$state/status.log" 2>/dev/null | grep -E "#$1([^0-9]|\$)" | grep -cE "start $2 of 2"; }
g03_startedis() { [ "$(g03_started "$1" "$2")" = "$3" ]; }
# g03_ends <unit regex>: status-log events of an end (ended, or stopped by the usage limit) that name the unit
# after the "open=[..] merged-prs=[..]; " prefix: "X01" for a node, "PR #13([^0-9]|$)" for a spec PR.
g03_ends() { grep -E '\]; .*('"$1"')' "$state/status.log" 2>/dev/null | grep -cE 'ended|stopped by'; }
g03_endsis() { [ "$(g03_ends "$1")" = "$2" ]; }
# g03_seen <id.run> <PR> <kind> <item id>: the FEEDBACK.md that run saw holds that item (by URL).
g03_seen() { grep -qF "$(fburl "$2" "$3" "$4")" "$GD/fbseen.$1" 2>/dev/null; }
g03_notseen() { [ -f "$GD/fbseen.$1" ] && ! g03_seen "$@"; }
g03_nitems() { grep -c '^kind: ' "$GD/fbseen.$1" 2>/dev/null; }
g03_tip() { git -C "$tmp/remote6.git" rev-parse "$1"; }
g03_stop() {
	touch "$HOME/STOP-up"
	wait_until 5 g01_gone "$lp6"
	rm -f "$GD"/hold.*
	for f in "$state"/node/*/session.pid "$state"/pr/*/session.pid "$state"/issue/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done
}
