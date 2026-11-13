# Shared by loop-w05*.test.sh (source after loop-prelude.sh): the fixture of the W05 runs (the status site's links).
# One loop per case (own repository name, own HOME with its own ~/.config/noodlebot, own state), all started together
# by w05_start and stopped by w05_stop_all. A fresh scheduler copy: the real loop.sh and session templates, a fake report.py
# that only logs its arguments (one line per call, in $W5/report.<name>), a fake site.py (publish does nothing).
# The fake claude copies the prompt the loop rendered ($state/<kind dir>/unattended.md) of a unit's first start to
# $W5/rec/<name>.<key> (key: A02 node, A05 follow-up, issue-46 triage, pr-101 update) and exits at once.
# What each case offers: node A02 (always), the follow-up A05 (case kinds "all"), triage issue #46 (kinds "all" or "triage"),
# the update of spec PR #101 (kinds "all": the triage session opens it when it ends).
W5=$tmp/w05; export W5
nb5=$W5/nb
mkdir -p "$nb5/scheduler" "$nb5/plugin" "$W5/rec" "$W5/h" "$W5/data/repos"
cp_scheduler "$nb5/scheduler"
[ -f "$src/harness.py" ] && { mkdir -p "$nb5/scheduler/harnesses"; cp "$src/harness.py" "$nb5/scheduler/"; cp "$src"/harnesses/*.py "$nb5/scheduler/harnesses/"; }
[ -f "$src/forge.py" ] && { mkdir -p "$nb5/scheduler/forges"; cp "$src/forge.py" "$nb5/scheduler/"; cp "$src"/forges/*.py "$nb5/scheduler/forges/"; }
cat >"$nb5/scheduler/report.py" <<'PYEOF'
import os, sys
a = sys.argv[1:]
name = a[a.index("--repo") + 1].split("/")[1] if "--repo" in a else "unknown"
open(os.path.join(os.environ["W5"], "report." + name), "a").write(" ".join(a) + "\n")
PYEOF
printf 'import sys\nsys.exit(0)\n' >"$nb5/scheduler/site.py"
# the remote: main of $tmp/remote.git (A01 -> A02..A05) plus the branch spec/u1
git clone -q --bare "$tmp/remote.git" "$W5/remote.git"
git clone -q "$W5/remote.git" "$W5/work"
git -C "$W5/work" checkout -q -b spec/u1 && echo spec >"$W5/work/spec.txt" && git -C "$W5/work" add -A &&
	git -C "$W5/work" -c user.name=t -c user.email=t@t commit -q -m spec && git -C "$W5/work" push -q origin spec/u1
cat >"$W5/claude" <<'EOF2'
#!/bin/sh
key=$(basename "$(pwd -P)")
case $key in issue-*) sd=$W5_STATE/issue/${key#issue-} ;; pr-*) sd=$W5_STATE/pr/${key#pr-} ;; *) sd=$W5_STATE/node/$key ;; esac
r=$W5/rec/$W5_NAME.$key
[ -e "$r" ] || { cp "$sd/unattended.md" "$r.tmp" && mv "$r.tmp" "$r"; }
case $key in
A*) echo "Q1: x" >"$sd/QUESTION.md" ;;
issue-*) [ -e "$W5/upd.$W5_NAME" ] && echo "101 spec/u1 abc123 true CONFLICTING" >"$W5/open.$W5_NAME" ;;
esac
exit 0
EOF2
chmod +x "$W5/claude"
# w05_gh <name>: the fake gh of one case.
w05_gh() {
	mkdir -p "$W5/bin.$1"
	cat >"$W5/bin.$1/gh" <<EOF2
#!/bin/sh
W=$W5
case " \$* " in
*" --state merged "*) cat "\$W/merged.$1" ;;
*" --state open "*) cat "\$W/open.$1" 2>/dev/null ;;
*" --state closed "*) ;;
*"/issues?labels=noodlebot"*) cat "\$W/issues.$1" ;;
*"/events"*) echo '[{"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "o"}}]' ;;
*" DELETE "*"/labels/noodlebot"*) echo '[]' >"\$W/issues.$1"; echo '[]' ;;
*" repos/o/$1 --jq .private "*)
	case \$(cat "\$W/vis.$1") in true) echo true ;; fail) echo 'gh: Bad Gateway (HTTP 502)' >&2; exit 1 ;; *) echo false ;; esac ;;
*" repos/"*"/labels"*) cat >/dev/null; echo '[{"name": "noodlebot"}, {"name": "noodlebot-triaged"}, {"name": "noodlebot-status"}, {"name": "noodlebot-unit"}]' ;;
esac
exit 0
EOF2
	ln -sf "$W5/claude" "$W5/bin.$1/claude"; chmod +x "$W5/bin.$1/gh"
}
W5_ALL=""
# w05_start <name> <kinds: all|triage|node> <site file content or -: none> <gist: yes|no> <visibility: false|true|fail> [<env assignment>...]
# starts the loop of o/<name>; "false" is public (the answer of `gh api --jq .private`).
w05_start() {
	local name=$1 kinds=$2 site=$3 gist=$4 vis=$5 h=$W5/h/$1 st=$W5/data/state/$1
	shift 5
	mkdir -p "$h/.config/noodlebot" "$st/node/A03" "$st/node/A04"
	cp "$HOME/.config/noodlebot/token" "$HOME/.config/noodlebot/oauth-token" "$h/.config/noodlebot/"
	touch "$st/node/A03/FAILED" "$st/node/A04/FAILED"
	[ "$site" = - ] || printf '%s\n' "$site" >"$h/.config/noodlebot/site"
	[ "$gist" = yes ] && { echo w05gist >"$h/.config/noodlebot/gist"; echo w05tok >"$h/.config/noodlebot/gist-token"; }
	echo "$vis" >"$W5/vis.$name"; : >"$W5/open.$name"; echo '[]' >"$W5/issues.$name"
	echo "1 node/A01-first-node" >"$W5/merged.$name"
	case $kinds in
	all) echo '50 node/A05-fifth-node' >>"$W5/merged.$name"; mkdir -p "$st/node/A05"
		echo "Q1: which way?" >"$st/node/A05/QUESTION.md"; echo "Q1: as recommended" >"$st/node/A05/ANSWER.md"
		echo '[{"number": 46}]' >"$W5/issues.$name"; : >"$W5/upd.$name" ;;
	triage) echo '[{"number": 46}]' >"$W5/issues.$name" ;;
	esac
	[ "$kinds" = all ] || { mkdir -p "$st/node/A05"; touch "$st/node/A05/FAILED"; }
	w05_gh "$name"
	git clone -q "$W5/remote.git" "$W5/data/repos/$name"
	env "$@" HOME="$h" W5_NAME="$name" W5_STATE="$st" NOODLEBOT_DATA="$W5/data" PATH="$W5/bin.$name:$PATH" SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		bash "$nb5/scheduler/loop.sh" "o/$name" >"$W5/$name.out" 2>&1 &
	pids+=("$!"); W5_ALL="$W5_ALL $name"
}
# w05_have <name> <key>...: the prompts of those units were recorded.
w05_have() { local n=$1 k; shift; for k in "$@"; do [ -s "$W5/rec/$n.$k" ] || return 1; done; }
w05_keys() { case $1 in all) echo "A02 A05 issue-46 pr-101" ;; triage) echo "A02 issue-46" ;; *) echo "A02" ;; esac; }
w05_ready() { local n=$1 k=$2; w05_have "$n" $(w05_keys "$k") && [ "$(w05_reports "$n")" -ge 4 ]; }   # four report calls: at least three ticks after the start, so a line said every tick is seen more than once
w05_reports() { wc -l <"$W5/report.$1" 2>/dev/null || echo 0; }
w05_stop_all() { local n; for n in $W5_ALL; do touch "$W5/h/$n/STOP-$n"; done; }
w05_log() { cat "$W5/data/state/$1/status.log" 2>/dev/null; }
# w05_norm <name> <key>: the recorded prompt with the case's name replaced by NAME, so that two cases compare.
w05_norm() { sed "s/$1/NAME/g" "$W5/rec/$1.$2"; }
