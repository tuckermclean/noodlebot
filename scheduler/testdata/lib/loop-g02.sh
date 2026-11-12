# Shared by loop-g02*.test.sh (source after loop-prelude.sh): the fixture of the G02 end-to-end runs (state/<name>/pr/<N>/ for node PRs).
# The only sleeps left here are polls inside loops (the fake claude's hold, the stop wait: each ends when the file or process it watches is gone) and the stand-in session's `sleep 300`, which is a process that must be running until the test kills it: no condition to wait for instead.
# ---- G02: update sessions for the bot's node PRs (state/<name>/pr/<N>/, worktrees/<name>/pr-<N>) ----
# All scratch paths are under $tmp/G02/ and every helper is prefixed g02_ (the scratch-folder rule), so
# this block shares nothing with the G01 block above. A fresh loop (o/g02, 1 s tick) over its own remote
# whose graph has N01..N11 (each with an open PR on node/<ID>-<name>, so no node session starts of its own).
# The fake gh answers the open-PR list from $G02_GD/prs.tsv ("<number> <branch> <author login> <is_bot>
# <mergeable>"; -q's "\(.field)" parts are filled in); $G02_GD/open.fail makes that list fail.
#   201 N01 bot CONFLICTING: update          202 N02 human CONFLICTING: none
#   203 N03 bot MERGEABLE: none              204 N04 bot UNKNOWN: none
#   205 N05 bot CONFLICTING, but N05's session runs (a fake session.pid): none until it ends
#   206 limit/FAILED   207 QUESTION.md/ANSWER.md   208..211 SCHED_MAX and the failing list   212 a follow-up branch
# The fake claude logs "<kind> <key> run <n> <prompt> | <pwd> | <branch>" to $G02_GD/claude.log (kind nupd:
# /noodlebot:node --update N; supd: /noodlebot:triage --update N; triage; node: /noodlebot:node ID), holds
# while $G02_GD/hold.<key> exists, exits 1 with a usage-limit event when $G02_GD/limit.<key>.<run> exists,
# with rc.<key>.<run> as its code, and writes a QUESTION.md in its pr/<N>/ when question.<key>.<run> exists.
G02=$tmp/G02; G02_GD=$G02/gd; export G02_GD
mkdir -p "$G02_GD" "$G02/bin" "$G02/nb/scheduler" "$G02/nb/plugin" "$G02/data" "$G02/fake"
g02_data=$(cd "$G02/data" && pwd -P)
G02_STATE=$g02_data/state/g02; export G02_STATE
g02_wt=$g02_data/worktrees/g02
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$G02/nb/scheduler/" ;; esac; done
[ -d "$src/harnesses" ] && { mkdir -p "$G02/nb/scheduler/harnesses"; cp "$src"/harnesses/*.py "$G02/nb/scheduler/harnesses/"; }
cp -R "$src/../plugin/." "$G02/nb/plugin/" 2>/dev/null
# the loop renders its prompt from scheduler/unattended-node-update.md: its copy here is a template of our own
printf 'G02-TEMPLATE for PR #@N@ in @WT@ state @DIR@\n' >"$G02/nb/scheduler/unattended-node-update.md"
g02g() { git -C "$G02/work" -c user.name=t -c user.email=t@t "$@"; }
git init -q -b main "$G02/work"; mkdir -p "$G02/work/docs"
printf 'nodes:\n' >"$G02/work/docs/graph.yaml"
for g02_i in 01:alpha 02:beta 03:gamma 04:delta 05:epsilon 06:zeta 07:eta 08:theta 09:kappa 10:iota 11:lambda; do
	printf '  - {id: N%s, name: %s, deps: []}\n' "${g02_i%%:*}" "${g02_i#*:}" >>"$G02/work/docs/graph.yaml"
done
g02g add -A && g02g commit -q -m init
git clone -q --bare "$G02/work" "$G02/remote.git"
for g02_i in 01:alpha 02:beta 03:gamma 04:delta 05:epsilon 06:zeta 07:eta 08:theta 09:kappa 10:iota 11:lambda 12:nu-followup-1; do
	g02g checkout -q -b "node/N${g02_i%%:*}-${g02_i#*:}" main && g02g commit -q --allow-empty -m "node ${g02_i%%:*}" &&
		g02g push -q "$G02/remote.git" "node/N${g02_i%%:*}-${g02_i#*:}"; g02g checkout -q main
done
g02g checkout -q -b spec/s1 main && g02g commit -q --allow-empty -m spec && g02g push -q "$G02/remote.git" spec/s1; g02g checkout -q main
# g02_mvref <branch>: a new commit on that branch of the remote, same tree (main or the PR's head moves).
g02_mvref() {
	local t c
	t=$(git -C "$G02/remote.git" rev-parse "$1^{tree}") &&
		c=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
			git -C "$G02/remote.git" commit-tree "$t" -p "$1" -m "move $1 $RANDOM") &&
		git -C "$G02/remote.git" update-ref "refs/heads/$1" "$c"
}
mkdir -p "$g02_data/repos" "$G02_STATE/node/N99"
git clone -q "$G02/remote.git" "$g02_data/repos/g02"
cat >"$G02_GD/prs.tsv" <<'EOT'
201 node/N01-alpha app/noodlebot true CONFLICTING
202 node/N02-beta tuckermclean false CONFLICTING
203 node/N03-gamma app/noodlebot true MERGEABLE
204 node/N04-delta app/noodlebot true UNKNOWN
205 node/N05-epsilon app/noodlebot true CONFLICTING
206 node/N06-zeta app/noodlebot true MERGEABLE
207 node/N07-eta app/noodlebot true MERGEABLE
208 node/N08-theta app/noodlebot true MERGEABLE
209 node/N09-kappa app/noodlebot true MERGEABLE
210 node/N10-iota app/noodlebot true MERGEABLE
211 node/N11-lambda app/noodlebot true MERGEABLE
EOT
echo '[]' >"$G02_GD/issues.json"
touch "$G02_GD/hold.201" "$G02_GD/hold.205" "$G02_GD/hold.t" "$G02_GD/hold.220" "$G02_GD/limit.206.1" "$G02_GD/question.207.1"
echo 1 >"$G02_GD/rc.206.2"; echo 1 >"$G02_GD/rc.206.3"
cat >"$G02_GD/gh.py" <<'EOT'
import json, os, re, subprocess, sys
GD = os.environ["G02_GD"]
a = sys.argv[1:]
j = " ".join(a)


def prs():
    out = []
    for line in open(GD + "/prs.tsv"):
        f = line.split()
        if len(f) < 5: continue
        oid = subprocess.run(["git", "--git-dir", GD + "/../remote.git", "rev-parse", f[1]],
                             capture_output=True, text=True).stdout.strip()
        out.append({"number": f[0], "headRefName": f[1], "headRefOid": oid, "mergeable": f[4],
                    "author": {"login": f[2], "is_bot": "true" if f[3] == "true" else "false"}})
    return out


def field(p, path):
    v = p
    for k in path.strip(".").split("."): v = v[k]
    return v


if a[:2] == ["pr", "list"]:
    if "--state" in a and a[a.index("--state") + 1] == "open":
        if os.path.exists(GD + "/open.fail"):
            print("fake-open-failure", file=sys.stderr); sys.exit(1)
        q = next((a[i + 1] for i, x in enumerate(a) if x in ("-q", "--jq") and i + 1 < len(a)), None)
        for p in prs():
            if q is None: print(json.dumps(p))
            else:
                m = re.search(r'"(.*)"', q)
                print(re.sub(r"\\\((\.[A-Za-z_.]+)\)", lambda x: str(field(p, x[1])), m[1]))
    sys.exit(0)
if "/issues?labels=noodlebot" in j: sys.stdout.write(open(GD + "/issues.json").read())
elif "/events" in j: print('[{"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "o"}}]')
elif " DELETE " in " " + j + " " and "/labels/noodlebot" in j: print("[]")
elif "/labels" in j: sys.stdin.read(); print("{}")
sys.exit(0)
EOT
printf '#!/bin/sh\nexec python3 -I "$G02_GD/gh.py" "$@"\n' >"$G02/bin/gh"
cat >"$G02/bin/claude" <<'EOT'
#!/bin/sh
case "$2" in
"/noodlebot:node --update "*) k=${2##* }; kind=nupd ;;
"/noodlebot:triage --update "*) k=${2##* }; kind=supd ;;
"/noodlebot:triage "*) k=t; kind=triage ;;
"/noodlebot:node "*) k=${2##* }; kind=node ;;
*) k=other; kind=other ;;
esac
n=$(( $(cat "$G02_GD/runs.$k" 2>/dev/null || echo 0) + 1 )); echo $n >"$G02_GD/runs.$k"
echo "$kind $k run $n $2 | $(pwd -P) | $(git branch --show-current 2>/dev/null)" >>"$G02_GD/claude.log"
while [ -e "$G02_GD/hold.$k" ]; do sleep 0.2; done
while [ -e "$G02_GD/hold.$k.$n" ]; do sleep 0.2; done
[ $kind = triage ] && echo "Q1: x" >"$G02_STATE/issue/46/QUESTION.md"
[ $kind = nupd ] && [ -e "$G02_GD/question.$k.$n" ] && echo "Q: which side wins?" >"$G02_STATE/pr/$k/QUESTION.md"
if [ -e "$G02_GD/limit.$k.$n" ]; then
	echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1,"status":"rejected"}}}}'
	echo '{"type":"result","subtype":"error_during_execution","result":"You have hit your usage limit"}'
	exit 1
fi
exit "$(cat "$G02_GD/rc.$k.$n" 2>/dev/null || echo 0)"
EOT
chmod +x "$G02/bin/gh" "$G02/bin/claude"
# a stand-in for a node's running session: the loop finds a session through session.pid and /proc/<pid>/cmdline
printf '#!/bin/sh\nsleep 300\n' >"$G02/fake/run-session.sh"
state=$G02_STATE
g02_runs() { cat "$G02_GD/runs.$1" 2>/dev/null || echo 0; }
g02_runsis() { [ "$(g02_runs "$1")" = "$2" ]; }
g02_ev() { grep -E "PR #$1([^0-9]|\$)" "$state/status.log" 2>/dev/null | grep -cE "$2"; }
g02_evis() { [ "$(g02_ev "$1" "$2")" = "$3" ]; }
g02_prs() { sed -i "s/^$1 \\(.*\\) [A-Z]*\$/$1 \\1 $2/" "$G02_GD/prs.tsv"; }
g02_rl() { printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":%s,"resetsAt":%s,"status":"allowed"},"seven_day":{"utilization":0.0,"resetsAt":%s,"status":"allowed"}}}}\n' "$1" "$2" $(($(date +%s) + 3 * 86400)) >>"$state/node/N99/session.jsonl"; }
g02_loop() {   # g02_loop <SCHED_MAX>
	rm -f "$HOME/STOP-g02"
	NOODLEBOT_DATA=$g02_data PATH=$G02/bin:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 SCHED_MAX=$1 \
		bash "$G02/nb/scheduler/loop.sh" o/g02 >>"$G02/loop.out" 2>&1 &
	pids+=("$!"); g02_lp=$!
}
g02_stop() {
	touch "$HOME/STOP-g02"
	timeout 5 sh -c "while kill -0 $g02_lp 2>/dev/null; do sleep 0.1; done"
	for f in "$state"/pr/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done
}
