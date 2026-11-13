#!/bin/bash
# One-screen status of the node scheduler. Keep it open next to htop:
#   watch -n 10 -c ~/gitrepos/noodlebot/scheduler/status.sh [owner/name]
set -u
nb=$(cd "$(dirname "$0")/.." && pwd -P)
here=$nb/scheduler
repo=${1:-tuckermclean/themonolith}
root=${NOODLEBOT_DATA:-$HOME/.local/share/noodlebot}
case $root in /*) ;; *) root=$PWD/$root ;; esac
state=$root/state/${repo#*/}
wtroot=$root/worktrees/${repo#*/}

echo "== $(date '+%F %T %Z')"
if ! flock -n "$state/loop.lock" true 2>/dev/null; then echo "loop:    running; stop with: touch ~/STOP"
else echo "loop:    NOT running; start with: tmux new -d -s sched-${repo#*/} $nb/scheduler/loop.sh $repo"; fi
if ! flock -n "$state/loop.lock" true 2>/dev/null; then
	v=$(cat "$state/version" 2>/dev/null); [ -n "$v" ] && echo "version: $v"
fi
[ -e ~/STOP ] && echo "         ~/STOP exists: the loop exits within seconds"
hb=$(cat "$state/heartbeat" 2>/dev/null || echo 0)
if [ "$hb" = 0 ]; then echo "last GitHub check: never"; else echo "last GitHub check: $(( $(date +%s) - hb ))s ago"; fi
iss=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["issue"])' "$state/report.json" 2>/dev/null)
[ -n "$iss" ] && echo "on GitHub: $(python3 -I "$here/forge.py" --repo "$repo" repo url --kind issue --ref "$iss" 2>/dev/null | tr -d '"') (reply there to answer a question)"
[ "$state/report.log" -nt "$state/report.json" ] && echo "status issue: FAILING: $(tail -n 1 "$state/report.log" | cut -c1-140)"
python3 -I -c '
import json, sys, time
try: u = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
w = u.get("windows") or {}
f = lambda k: "%.0f%% (resets %s)" % (w[k]["utilization"] * 100, time.strftime("%a %H:%M", time.localtime(w[k]["resetsAt"]))) if k in w else "?"
p = u.get("projected5h")
print("usage:   5-hour %s%s, 7-day %s; throttle %s" % (f("five_hour"), ", projected %.0f%%" % (p * 100) if p is not None else "", f("seven_day"),
      "HOLDING: " + u["reason"] if u.get("hold") else "open"))' "$(dirname "$state")/usage.json"
echo "last change: $(tail -n 1 "$state/status.log" 2>/dev/null | cut -c1-150)"

# The sessions: every node or issue whose session.pid names a live session process.
n_live=0
for f in "$state"/node/*/session.pid "$state"/issue/*/session.pid; do
	[ -e "$f" ] || continue
	p=$(cat "$f") id=$(basename "$(dirname "$f")") sdir=$(dirname "$f")
	python3 -I -B "$nb/scheduler/harness.py" matches "$id" "$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null)" || continue
	n_live=$((n_live + 1)) label=$id
	[[ $sdir == */issue/* ]] && label="triage of #$id"
	# the log's size and last write (harness.py log-stat), then the last actions; a subagent's are marked with ">"
	sess=$(python3 -I -B -c '
import sys, time
sys.path.insert(0, sys.argv[1] + "/scheduler")
import harness
st = harness.log_stat(sys.argv[2])
if st.get("size") is None: print("LOG - -")
else:
    size = st["size"]
    h = "%d" % size if size < 1024 else ("%.1fK" % (size / 1024.0) if size < 1048576 else "%.1fM" % (size / 1048576.0))
    print("LOG %s %s" % (h, time.strftime("%T", time.localtime(st["mtime"]))))
acts = []
for e in harness.events(sys.argv[2], write=False):
    if e.get("type") == "tool":
        acts.append("   %s%s: %s" % ("> " if e.get("subagent") else "", e.get("name"), e.get("label") or ""))
    elif e.get("type") == "result":
        acts.append("   [turn ended: %s, %s turns]" % (e.get("subtype"), e.get("turns")))
print("\n".join(acts[-4:]) or "   (none yet)")' "$nb" "$sdir" 2>/dev/null)
	logline=$(printf '%s\n' "$sess" | sed -n 's/^LOG //p')
	echo "== $label RUNNING (pid $p, for $(ps -o etime= -p "$p" | tr -d ' ')); log ${logline% *}, last written ${logline##* }"
	printf '%s\n' "$sess" | grep -v '^LOG '
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
		found=1
		clause=$(python3 -I "$nb/scheduler/report.py" --repo "$repo" --state "$state" --clause "$id" 2>/dev/null | head -n 1)
		echo "   $id answered: ${clause:-restarts at the next tick}"
	elif [ -e "$d/QUESTION.md" ]; then
		found=1; echo "   $id QUESTION: $(head1 "$d/QUESTION.md")"
		echo "      read it: less $d/QUESTION.md"
		echo "      answer:  write $d/ANSWER.md (it restarts at the next tick)"
	elif [ -e "$d/WAITING-PR" ]; then
		pr=$(cat "$d/WAITING-PR")
		if grep -qxF -- "$pr" "$state/merged-prs.txt" 2>/dev/null; then found=1; echo "   $id spec PR #$pr merged; waits for its turn"
		else found=1; echo "   $id waits for you to merge spec PR #$pr; restarts at the tick after"; fi
	fi
done
[ $found = 0 ] && echo "   nothing"

echo "-- open PRs:"
# the forge's open-PR display form (a row's `line` is "   #N title"; dependabot's PRs left out); a failure, token script included, is "(gh unavailable)"
prs=$(env -u GH_TOKEN NOODLEBOT_FORGE_TOKEN_SCRIPT=$HOME/.config/noodlebot/token python3 -I "$here/forge.py" --repo "$repo" pr list --state open \
	--fields number --fields title 2>/dev/null) &&
	python3 -I -c 'import json, sys
for r in json.loads(sys.argv[1]): print(r["line"])' "$prs" 2>/dev/null ||
	echo "   (gh unavailable)"
