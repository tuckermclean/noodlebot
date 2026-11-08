#!/bin/bash
# One-screen status of the node scheduler. Keep it open next to htop:
#   watch -n 10 -c ~/gitrepos/noodlebot/scheduler/status.sh
set -u
nb=$(cd "$(dirname "$0")/.." && pwd -P)
repo=tuckermclean/themonolith
state=$nb/state/${repo#*/}
wtroot=$nb/worktrees/${repo#*/}

echo "== $(date '+%F %T %Z')"
if ! flock -n "$state/loop.lock" true 2>/dev/null; then echo "loop:    running; stop with: touch ~/STOP"
else echo "loop:    NOT running; start with: tmux new -d -s sched $nb/scheduler/loop.sh"; fi
[ -e ~/STOP ] && echo "         ~/STOP exists: the loop exits within seconds"
hb=$(cat "$state/heartbeat" 2>/dev/null || echo 0)
if [ "$hb" = 0 ]; then echo "last GitHub check: never"; else echo "last GitHub check: $(( $(date +%s) - hb ))s ago"; fi
iss=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["issue"])' "$state/report.json" 2>/dev/null)
[ -n "$iss" ] && echo "on GitHub: https://github.com/$repo/issues/$iss (reply there to answer a question)"
[ -s "$state/report.log" ] && echo "status issue: last error: $(tail -n 1 "$state/report.log" | cut -c1-140)"
echo "last change: $(tail -n 1 "$state/status.log" 2>/dev/null | cut -c1-150)"

# The session: a node whose session.pid names a live session process.
spid='' node=''
for f in "$state"/node/*/session.pid; do
	[ -e "$f" ] || continue
	p=$(cat "$f") id=$(basename "$(dirname "$f")")
	if tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -qE "run-session\.sh .* $id( |\$)|claude -p /node $id( |\$)"; then spid=$p node=$id; fi
done
[ -n "$node" ] || node=$(sed -n 's/.*started \([A-Z][0-9][0-9]\) .*/\1/p' "$state/status.log" 2>/dev/null | tail -n 1)
if [ -n "$spid" ]; then
	echo "session: $node RUNNING (pid $spid, for $(ps -o etime= -p "$spid" | tr -d ' '))"
elif [ -n "$node" ]; then
	echo "session: none running (last: $node)"
fi
if [ -n "$node" ]; then
	log=$state/node/$node/session.jsonl
	echo "         log $(du -h "$log" | cut -f1), last written $(date -r "$log" '+%T')"
	echo "-- last actions:"
	tail -n 300 "$log" | python3 -I -c '
import json, sys
acts = []
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get("type") == "assistant":
        for c in d.get("message", {}).get("content", []):
            if c.get("type") == "tool_use":
                i = c.get("input", {})
                what = str(i.get("description") or i.get("command") or i.get("file_path") or i.get("skill") or "")
                first = what.splitlines()[0][:110] if what else ""
                acts.append("   %s: %s" % (c.get("name"), first))
    if d.get("type") == "result":
        acts.append("   [session ended: %s, %s turns]" % (d.get("subtype"), d.get("num_turns")))
print("\n".join(acts[-6:]) or "   (none yet)")'
	echo "-- commits on node/$node:"
	git -C "$wtroot/$node" log --oneline origin/main..HEAD 2>/dev/null | head -n 8 | sed 's/^/   /'
	[ -z "$(git -C "$wtroot/$node" log --oneline origin/main..HEAD 2>/dev/null)" ] && echo "   (none)"
fi

echo "-- waiting on you:"
found=0
for d in "$state"/node/*/; do
	id=$(basename "$d") d=${d%/}
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
GH_TOKEN=$(~/.config/noodlebot/token 2>/dev/null) gh pr list --repo $repo --state open \
	--json number,title,author -q '.[] | select(.author.login | test("dependabot") | not) | "   #\(.number) \(.title[0:90])"' 2>/dev/null ||
	echo "   (gh unavailable)"
