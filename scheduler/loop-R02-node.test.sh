#!/bin/bash
# R02-AC-1 (the prompts the loop writes for a node session): the node prompt (a fresh start; a restart with its resume
# section and the reason of the stop), the follow-up prompt (a restart, with its resume section) and the limit-resume
# prompt, from loops on the fake forge (G04: fake:<path>, a forge that is not GitHub; its remote is a local repo.git, and
# a gh that fails on any call is first on PATH). Each rendered prompt tells the session to reach the forge through
# NOODLEBOT_FORGE, holds no gh command and no github.com URL, and keeps the rules its template carries.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g04.sh"
. "$src/testdata/lib/loop-R02.sh"
r02_nb=$G04/nb
cp "$src"/unattended*.md "$src"/limit-resume.md "$src"/version.sh "$G04/nb/scheduler/"
g04_gh_fail
cat >"$G04/bin/claude" <<'EOF2'
#!/bin/sh
# the fake session: it holds until it is stopped; mode limit: it writes a rejection that reset 5 minutes ago and goes idle,
# and a resumed run (--resume) writes QUESTION.md and ends.
sid= prev=
for a in "$@"; do [ "$prev" = --resume ] && sid=$a; prev=$a; done
echo "$R02_MODE $*" >>"$G04_DIR/runs.$R02_MODE"
if [ "$R02_MODE" = limit ]; then
	if [ -n "$sid" ]; then echo "Q1: x" >"$R02_STATE/node/A01/QUESTION.md"; exit 0; fi
	printf '{"type":"system","subtype":"init","session_id":"sid-A01"}\n'
	r=$(($(date +%s) - 300))
	printf '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":%s,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":%s,"status":"rejected"}}}}\n' "$r" "$r"
	sleep 300 & wait
	exit 0
fi
while :; do sleep 0.2; done
EOF2
chmod +x "$G04/bin/claude"

mk() { # <name>: fake forge $1 and its clone, as the loop leaves them
	g04_fake "$1"
	mkdir -p "$g04data/repos" "$g04data/state/$1/node/A01"
	git clone -q "$G04/fk/$1/repo.git" "$g04data/repos/$1"
}
# a branch with a commit that origin/main lacks: the node has work, so its start is a restart (the resume section)
work() { # <name> <branch>
	git -C "$g04data/repos/$1" -c user.name=t -c user.email=t@t checkout -q -b "$2" origin/main &&
		git -C "$g04data/repos/$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "work" &&
		git -C "$g04data/repos/$1" checkout -q --detach origin/main
}
mk fk1                                                    # node: a fresh start
mk fk2; work fk2 node/A01-first-node                      # node: a restart after a stop
echo "2026-11-15T10:00:00Z the session ended (rc 1) with no question, no PR and no spec PR" >"$g04data/state/fk2/node/A01/stopped"
mk fk3; work fk3 node/A01-followup-1                      # follow-up: merged node, its spec PR closed unmerged, a restart
echo node/A01-followup-1 >"$g04data/state/fk3/node/A01/FOLLOWUP"; echo 105 >"$g04data/state/fk3/node/A01/WAITING-PR"
python3 - "$G04/fk/fk3" <<'PY'
import json, sys
def pr(n, head, state, merged):
    return {"number": n, "title": "t", "body": "", "state": state, "head": head, "head_sha": "a" * 40, "base": "main",
            "author": {"login": "noodlebot[bot]", "is_bot": True, "is_owner": False}, "mergeable": "UNKNOWN",
            "created_at": "2026-06-01T12:00:00Z", "merged_at": "2026-06-02T12:00:00Z" if merged else None,
            "closed_at": "2026-06-02T12:00:00Z"}
json.dump([pr(20, "node/A01-first-node", "merged", True), pr(105, "spec/a01", "closed", False)], open(sys.argv[1] + "/prs.json", "w"))
PY
mk fk4                                                    # limit resume: a node session idle by the usage limit

names="fk1 fk2 fk3 fk4" loops=()
for n in $names; do
	mode=node; [ $n = fk4 ] && mode=limit
	g04_run "fake:$G04/fk/$n" $n R02_MODE=$mode R02_STATE="$g04data/state/$n"
	loops+=("$g04_pid")
done
st() { echo "$g04data/state/$1"; }
# the loop writes a prompt in place: it is whole when its last line is there (the signature; the resume prompt's reset time)
there() { grep -qE 'n00dl3b0t|limit window reset at' "$1" 2>/dev/null; }
for pair in fk1:node/A01/unattended.md fk2:node/A01/unattended.md fk3:node/A01/unattended.md fk4:node/A01/resume-prompt.md; do
	wait_until 30 there "$(st "${pair%%:*}")/${pair#*:}"
done
for n in $names; do touch "$HOME/STOP-$n"; done
cp "$(st fk1)/node/A01/unattended.md" "$tmp/R02-node.md" 2>/dev/null
cp "$(st fk2)/node/A01/unattended.md" "$tmp/R02-restart.md" 2>/dev/null
cp "$(st fk3)/node/A01/unattended.md" "$tmp/R02-followup.md" 2>/dev/null
cp "$(st fk4)/node/A01/resume-prompt.md" "$tmp/R02-resume.md" 2>/dev/null
# the node and the follow-up are restarts in their runs (resume section): the one text with the most in it
is_restart() { grep -q 'RESUMING AFTER A STOP' "$1"; }
r02_check "R02 setup: the restarted node's prompt has its resume section" "$tmp/R02-restart.md" is_restart "$tmp/R02-restart.md"
r02_check "R02 setup: the follow-up's prompt is the follow-up template, with its resume section" "$tmp/R02-followup.md" sh -c "grep -q FOLLOW-UP '$tmp/R02-followup.md' && grep -q 'RESUMING AFTER A STOP' '$tmp/R02-followup.md'"
r02_prompt node "$tmp/R02-node.md" questions,closing,merge,sig
r02_prompt "node, restarted" "$tmp/R02-restart.md" questions,closing,merge,sig
r02_prompt follow-up "$tmp/R02-followup.md" questions,closing,merge,sig
r02_prompt "limit resume" "$tmp/R02-resume.md" -
r02_check "R02-AC-1 (limit resume): it is limit-resume.md and the reset time the loop adds" "$tmp/R02-resume.md" sh -c "grep -q 'usage limit' '$tmp/R02-resume.md' && grep -q 'The limit window reset at ' '$tmp/R02-resume.md'"
all_gone() { local p; for p in "${loops[@]}"; do kill -0 "$p" 2>/dev/null && return 1; done; return 0; }
wait_until 10 all_gone
r02_check "R02-AC-1: the failing gh was never called (the loops used the fake forge)" "$tmp/R02-node.md" test ! -e "$G04/gh.called"
loop_end
