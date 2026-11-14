# Shared by loop-g04*.test.sh (source after loop-prelude.sh): the fixture of the G04 runs (the forge the loop is given:
# owner/name, github:owner/name, fake:<path>). All scratch lives under $G04 (= $tmp/G04); the loop's runtime root is
# $G04/data, its home is the prelude's scratch $HOME (never the real one).
#   $G04/nb/scheduler   a copy of the scheduler's files (loop.sh and what it runs), with forge.py, forges/ and the fake forge
#                       (testdata/forge/*.py) beside it; site.py is a recorder: it appends "publish" to $G04/order.log
#   $G04/bin/claude     the fake harness: records its start in $G04/runs.<ID>, then runs until it is stopped
#   $G04/bin/gh         g04_gh_fail: a gh that fails on any call and records that it was called ($G04/gh.called)
#                       g04_gh_emul: gh over the GitHub emulator (testdata/forge/fakegh.py), state $G04/ghstate
#   g04_fake <name> [caps]  a fake forge state folder $G04/fk/<name> (owner acme, repo.git a bare clone of $tmp/remote.git;
#                       caps: comma list of capabilities, absent = all four)
#   g04_run <spec> <name> [env...]   starts loop.sh with <spec> as its only argument; <name> is the runtime name
#                       (state/<name>, repos/<name>, STOP-<name>); leaves the pid in $g04_pid
G04=$tmp/G04
g04data=$G04/data
mkdir -p "$G04/nb/scheduler/harnesses" "$G04/nb/scheduler/forges" "$G04/nb/scheduler/testdata/forge" "$G04/nb/plugin" "$G04/bin" "$G04/fk"
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/unattended.md "$src"/issues.py \
	"$src"/unattended-triage.md "$src"/status.sh "$src"/usage.py "$src"/labels.py "$src"/report.py "$src"/harness.py \
	"$src"/forge.py "$src"/forge-cli.sh "$G04/nb/scheduler/" 2>/dev/null
cp "$src"/harnesses/*.py "$G04/nb/scheduler/harnesses/"
cp "$src"/forges/*.py "$G04/nb/scheduler/forges/" 2>/dev/null
cp "$src"/testdata/forge/*.py "$G04/nb/scheduler/testdata/forge/"
cat >"$G04/nb/scheduler/site.py" <<'EOF2'
import os
w = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
open(os.path.join(w, "order.log"), "a").write("publish\n")
EOF2
cat >"$G04/bin/claude" <<'EOF2'
#!/bin/sh
id=${2##* }
echo "$id" >>"$G04_DIR/runs.$id"
mkdir -p "out/node/$id" && echo brief >"out/node/$id/brief.md"
while :; do sleep 0.2; done
EOF2
chmod +x "$G04/bin/claude"
g04_gh_fail() {
	cat >"$G04/bin/gh" <<'EOF2'
#!/bin/sh
echo "$*" >>"$G04_DIR/gh.called"
echo "gh: called, but this forge has no gh" >&2
exit 1
EOF2
	chmod +x "$G04/bin/gh"
}
g04_gh_emul() {
	mkdir -p "$G04/ghstate"
	printf '{"owner": "acme", "name": "widgets", "private": false, "default_branch": "main"}\n' >"$G04/ghstate/forge.json"
	printf '#!/bin/sh\nFAKE_GH_DIR=%s exec python3 "%s/fakegh.py" "$@"\n' "$G04/ghstate" "$src/testdata/forge" >"$G04/bin/gh"
	chmod +x "$G04/bin/gh"
}
g04_fake() {
	local d=$G04/fk/$1 caps=${2:-}
	mkdir -p "$d"
	if [ -n "$caps" ]; then
		printf '{"owner": "acme", "name": "%s", "private": false, "default_branch": "main", "capabilities": ["%s"]}\n' "$1" "$(echo "$caps" | sed 's/,/", "/g')" >"$d/forge.json"
	else
		printf '{"owner": "acme", "name": "%s", "private": false, "default_branch": "main"}\n' "$1" >"$d/forge.json"
	fi
	git clone -q --bare "$tmp/remote.git" "$d/repo.git"
}
g04_run() {
	local spec=$1 name=$2; shift 2
	g04_name=$name
	env "$@" G04_DIR="$G04" NOODLEBOT_DATA=$g04data PATH=$G04/bin:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		bash "$G04/nb/scheduler/loop.sh" "$spec" >>"$G04/$name.out" 2>&1 &
	g04_pid=$!; pids+=("$g04_pid")
}
g04_gone() { ! kill -0 "$1" 2>/dev/null; }
g04_stop() { touch "$HOME/STOP-$g04_name"; wait_until 8 g04_gone "$g04_pid"; kill "$g04_pid" 2>/dev/null; wait "$g04_pid" 2>/dev/null; rm -f "$HOME/STOP-$g04_name"; true; }
g04_cleanup() {
	local f
	for f in "$g04data"/state/*/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done
	return 0
}
extra_cleanup() { g04_cleanup; }
# g04_ticking <state dir>: the loop has made a heartbeat there.
g04_ticking() { [ -s "$1/heartbeat" ]; }
# g04_names <folder>: the entries of a folder, space separated ("-" when empty or missing).
g04_names() { local o; o=$(ls "$1" 2>/dev/null | paste -sd, -); echo "${o:--}"; }
