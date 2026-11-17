# Shared by loop-a07-resume.test.sh and loop-a07-release.test.sh (source after loop-a07.sh): the A07 review's findings.
#   a07r_claude      replace the fake claude: a first run writes a system/init line (session id sid-<key>) and a rejected
#                    five_hour rate_limit_event whose reset is 300 s past, then sleeps (the session is idle by the usage
#                    limit); a run with --resume logs "<key> resume <sid> | <prompt>" to $A07/resume.log, opens the unit's
#                    PR (as loop-a07.sh's claude) and writes WAITING-PR, exit 0. The key is the area of "--area <name>".
#   a07r_wait_idle   the unit's log ends with the rejection
#   a07r_graph_bad   a broken YAML document on origin/main with a top-level `adoption:` line (docs/graph.yaml)
#   a07r_answered <key> <suffix>   the unit's answered/ holds a file <ts>-<suffix> (exactly that suffix)
a07r_claude() {
	mv "$G04/bin/claude" "$G04/bin/claude-a07"
	cat >"$G04/bin/claude" <<'EOF2'
#!/bin/sh
sid= prompt= prev=
for a in "$@"; do
	case $prev in -p) prompt=$a ;; --resume) sid=$a ;; esac
	prev=$a
done
case "$prompt" in "/noodlebot:adopt --area "*) k=${prompt#/noodlebot:adopt --area }; k=${k%% *} ;; *) k=other ;; esac
if [ -n "$sid" ]; then
	echo "$k resume $sid | $prompt" >>"$A07_DIR/resume.log"
	d=$A07_STATE/adopt/$k
	python3 "$A07_DIR/forge.py" pr "$A07_FK" 23 "spec/adopt-$k"
	echo 23 >"$d/WAITING-PR"
	exit 0
fi
echo "$k run 1 $prompt" >>"$A07_DIR/claude.log"
t=$(( $(date +%s) - 300 ))
printf '{"type":"system","subtype":"init","session_id":"sid-%s"}\n' "$k"
printf '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":%s,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":%s,"status":"rejected"}}},"session_id":"sid-%s"}\n' "$t" "$t" "$k"
while :; do sleep 0.2; done
EOF2
	chmod +x "$G04/bin/claude"
}
a07r_wait_idle() { grep -q '"status":"rejected"' "$(a07_ud "$1")/session.jsonl" 2>/dev/null; }
a07r_graph_bad() {
	local fk=$G04/fk/$1 w=$A07/w.$1
	rm -rf "$w"; git clone -q "$fk/repo.git" "$w" 2>/dev/null
	mkdir -p "$w/docs"
	printf 'apiVersion: themonolith/v1\nkind: DependencyGraph\nadoption:\n  areas: [{name: one\nnodes: [\n' >"$w/docs/graph.yaml"
	git -C "$w" add -A
	git -C "$w" -c user.name=t -c user.email=t@t commit -q -m "graph bad"
	git -C "$w" push -q origin HEAD:main
	rm -rf "$w"
}
a07r_answered() { ls "$(a07_ud "$1")"/answered/ 2>/dev/null | grep -qE -- "^[0-9T]+Z-$2\$"; }
