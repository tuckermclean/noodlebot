#!/bin/bash
# One-screen status of the node scheduler. Keep it open next to htop:
#   watch -n 30 -c ~/gitrepos/noodlebot/scheduler/status.sh
set -u
nb=$(cd "$(dirname "$0")/.." && pwd -P)
repo=tuckermclean/themonolith
state=$nb/state/${repo#*/}
wtroot=$nb/worktrees/${repo#*/}

echo "== $(date '+%F %T %Z')"
if pid=$(pgrep -f 'scheduler/loop.sh' | head -n 1); [ -n "$pid" ]; then echo "loop:    running (pid $pid); stop with: touch ~/STOP"
else echo "loop:    NOT running"; fi
[ -e ~/STOP ] && echo "         ~/STOP exists: the loop exits at its next tick"
echo "last tick: $(tail -n 1 "$state/status.log" 2>/dev/null | cut -c1-150)"

spid=$(pgrep -f 'claude -p /node' | head -n 1)
node=$(sed -n 's/.*started \([A-Z][0-9][0-9]\) .*/\1/p' "$state/status.log" 2>/dev/null | tail -n 1)
if [ -n "$spid" ]; then
	echo "session: $node RUNNING (pid $spid, for $(ps -o etime= -p "$spid" | tr -d ' '))"
elif [ -n "$node" ]; then
	echo "session: $node not running"
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
for f in "$state"/node/*/QUESTION.md "$state"/node/*/FAILED; do
	[ -e "$f" ] || continue
	found=1
	id=$(basename "$(dirname "$f")")
	echo "   $id $(basename "$f"): $(grep -m1 -v '^\s*$' "$f" | sed 's/^# *//' | cut -c1-100)"
	echo "      read it: less $f"
done
[ $found = 0 ] && echo "   nothing"

echo "-- open PRs:"
GH_TOKEN=$(~/.config/noodlebot/token 2>/dev/null) gh pr list --repo $repo --state open \
	--json number,title,author -q '.[] | select(.author.login | test("dependabot") | not) | "   #\(.number) \(.title[0:90])"' 2>/dev/null ||
	echo "   (gh unavailable)"
