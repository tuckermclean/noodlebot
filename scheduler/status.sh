#!/bin/bash
# One-screen status of the node scheduler. Keep it open next to htop:
#   watch -n 10 -c ~/gitrepos/noodlebot/scheduler/status.sh [owner/name]
set -u
nb=$(cd "$(dirname "$0")/.." && pwd -P)
repo=${1:-tuckermclean/themonolith}
state=$nb/state/${repo#*/}
wtroot=$nb/worktrees/${repo#*/}

echo "== $(date '+%F %T %Z')"
if ! flock -n "$state/loop.lock" true 2>/dev/null; then echo "loop:    running; stop with: touch ~/STOP"
else echo "loop:    NOT running; start with: tmux new -d -s sched-${repo#*/} $nb/scheduler/loop.sh $repo"; fi
[ -e ~/STOP ] && echo "         ~/STOP exists: the loop exits within seconds"
hb=$(cat "$state/heartbeat" 2>/dev/null || echo 0)
if [ "$hb" = 0 ]; then echo "last GitHub check: never"; else echo "last GitHub check: $(( $(date +%s) - hb ))s ago"; fi
iss=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["issue"])' "$state/report.json" 2>/dev/null)
[ -n "$iss" ] && echo "on GitHub: https://github.com/$repo/issues/$iss (reply there to answer a question)"
[ "$state/report.log" -nt "$state/report.json" ] && echo "status issue: FAILING: $(tail -n 1 "$state/report.log" | cut -c1-140)"
echo "last change: $(tail -n 1 "$state/status.log" 2>/dev/null | cut -c1-150)"

# The sessions: every node or issue whose session.pid names a live session process.
n_live=0
for f in "$state"/node/*/session.pid "$state"/issue/*/session.pid; do
	[ -e "$f" ] || continue
	p=$(cat "$f") id=$(basename "$(dirname "$f")") sdir=$(dirname "$f")
	tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -qE "run-session\.sh .* $id( |\$)|claude -p /node $id( |\$)" || continue
	n_live=$((n_live + 1)) label=$id
	[[ $sdir == */issue/* ]] && label="triage of #$id"
	log=$sdir/session.jsonl
	echo "== $label RUNNING (pid $p, for $(ps -o etime= -p "$p" | tr -d ' ')); log $(du -h "$log" | cut -f1), last written $(date -r "$log" '+%T')"
	# The last actions; a subagent's are marked with ">".
	tail -n 300 "$log" | python3 -I -c '
import json, sys
acts = []
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if not isinstance(d, dict): continue
    msg = d.get("message")
    if d.get("type") == "assistant" and isinstance(msg, dict):
        for c in msg.get("content") or []:
            if isinstance(c, dict) and c.get("type") == "tool_use":
                i = c.get("input") or {}
                what = str(i.get("description") or i.get("command") or i.get("file_path") or i.get("skill") or "")
                first = what.splitlines()[0][:100] if what else ""
                acts.append("   %s%s: %s" % ("> " if d.get("parent_tool_use_id") else "", c.get("name"), first))
    if d.get("type") == "result":
        acts.append("   [turn ended: %s, %s turns]" % (d.get("subtype"), d.get("num_turns")))
print("\n".join(acts[-4:]) or "   (none yet)")'
	[[ $sdir == */issue/* ]] || git -C "$wtroot/$id" log --oneline -3 origin/main..HEAD 2>/dev/null | sed 's/^/   commit /'
done
if [ "$n_live" = 0 ]; then
	echo "sessions: none running (last started: $(sed -n 's/.*started \(.*\) in .*/\1/p' "$state/status.log" 2>/dev/null | tail -n 1))"
fi

echo "-- waiting on you:"
found=0
for d in "$state"/node/*/ "$state"/issue/*/; do
	[ -d "$d" ] || continue
	id=$(basename "$d") d=${d%/}
	[[ $d == */issue/* ]] && id="#$id"
	head1() { grep -m1 -v '^\s*$' "$1" | sed 's/^# *//' | cut -c1-100; }
	if [ -e "$d/FAILED" ]; then
		found=1; echo "   $id FAILED: $(head1 "$d/FAILED")"
		echo "      to retry: rm $d/FAILED"
	elif [ -e "$d/QUESTION.md" ] && [ -e "$d/ANSWER.md" ]; then
		found=1; echo "   $id answered: restarts at the next tick"
	elif [ -e "$d/QUESTION.md" ]; then
		found=1; echo "   $id QUESTION: $(head1 "$d/QUESTION.md")"
		echo "      read it: less $d/QUESTION.md"
		echo "      answer:  write $d/ANSWER.md (it restarts at the next tick)"
	elif [ -e "$d/WAITING-PR" ]; then
		found=1; echo "   $id waits for you to merge spec PR #$(cat "$d/WAITING-PR"); restarts at the tick after"
	fi
done
[ $found = 0 ] && echo "   nothing"

echo "-- open PRs:"
GH_TOKEN=$(~/.config/noodlebot/token "$repo" 2>/dev/null) gh pr list --repo $repo --state open \
	--json number,title,author -q '.[] | select(.author.login | test("dependabot") | not) | "   #\(.number) \(.title[0:90])"' 2>/dev/null ||
	echo "   (gh unavailable)"
