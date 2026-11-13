# Shared by loop-s07*.test.sh (source after loop-prelude.sh): the fixture and helpers of the start-queue (S07) runs.
# Own fixture per phase (fresh $NOODLEBOT_DATA $q/data): two repositories o/qa and o/qb, each with its own
# bare remote, clone and loop. Fakes: claude (every session logs "<epoch.ns> <repo> <id>" to $q/starts.log, id =
# node ID, or t<N> for a triage, and runs until $q/end or $q/end.<id> exists), gh (issues per repository from
# $q/issues.<repo>.json, no PRs), usage.py copied into the run's scheduler/ (prints the line in $q/usage:
# "open: ..." or "hold: ..."), and turn.py copied from the repository (a failing fake in the turn.py case).
# Conventions the loop must honour:
#   waiting record: a file `waiting` in the unit's state folder (state/<name>/node/<ID>/, issue/<N>/, pr/<N>/):
#   one line, the epoch second its loop first found the unit waiting; written then, kept across a restart,
#   removed when the unit starts or stops waiting (QUESTION.md, FAILED, label removed, repository at SCHED_MAX).
#   A loop lists its waiting units (turn.py list) every tick, also while the throttle holds, so that the
#   machine's order is known before the throttle opens; it asks for a turn (turn.py ask) only when the throttle is open.
#   Phases whose order matters start both loops with the throttle holding, wait until each loop lists every unit that is
#   to compete (qcompete), then open it.
# Ticks (D05): turn.py counts a loop as live only while its heartbeat (whole epoch seconds, written when a tick begins) is
# less than three of its ticks old. A loop asks at the end of its tick (after the tick's work, w: git, gh, usage, ready.py,
# turn.py), and another loop's heartbeat is up to a whole cycle (w + SCHED_TICK) and a second (rounding) old when it is
# read. So a phase where the order across the two loops matters needs w < 2 x tick - 1 s (tick 3: w < 5 s; tick 2: w < 3
# s), and a loop asking alone w < 3 x tick - 1 s (tick 2: w < 5 s); w is several seconds on a loaded machine. A phase uses
# tick 1 only where its loop takes no turn (throttle held, SCHED_RAMP=0, killed, or its tick ends before the queue), or
# where a check names that tick. Waits count the loops' ticks (qticks) or wait for what the next check reads; the
# negative checks wait as many ticks as before.
declare -A qp=()
qsetup() { # <tag> "<ID:Size> ..." (o/qa) "<ID:Size> ..." (o/qb)
	local k ids spec id w
	qtag=$1 q=$tmp/q-$1; qd=$q/data qnb=$q/nb
	mkdir -p "$q/bin" "$qnb/scheduler" "$qnb/plugin" "$qd/repos"
	for k in qa qb; do
		if [ $k = qa ]; then ids=$2; else ids=$3; fi
		w=$q/work-$k
		git init -q -b main "$w"; mkdir -p "$w/docs" "$w/nodes"
		{ echo "nodes:"; for spec in $ids; do echo "  - {id: ${spec%%:*}, name: u-${spec%%:*}, deps: []}"; done; } >"$w/docs/graph.yaml"
		for spec in $ids; do
			id=${spec%%:*}
			printf '# %s\n\n| Track | Deps | Unlocks | Size |\n|---|---|---|---|\n| now | none | none | %s |\n' "$id" "${spec#*:}" >"$w/nodes/$id-u-$id.md"
		done
		git -C "$w" add -A && git -C "$w" -c user.name=t -c user.email=t@t commit -q -m init
		git clone -q --bare "$w" "$q/$k.git"
		git clone -q "$q/$k.git" "$qd/repos/$k"
		echo '[]' >"$q/issues.$k.json"
	done
	cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/issues.py "$src"/unattended*.md "$qnb/scheduler/"
	[ -f "$src/turn.py" ] && cp "$src/turn.py" "$qnb/scheduler/"
	[ -f "$src/harness.py" ] && { mkdir -p "$qnb/scheduler/harnesses"; cp "$src/harness.py" "$qnb/scheduler/"; cp "$src"/harnesses/*.py "$qnb/scheduler/harnesses/"; }
	: >"$q/starts.log"; echo "open: test opens" >"$q/usage"
	printf '#!/usr/bin/env python3\nprint(open("%s/usage").read().strip())\n' "$q" >"$qnb/scheduler/usage.py"
	sed "s|@Q@|$q|g" >"$q/bin/claude" <<'EOF'
#!/bin/sh
q=@Q@
case "$2" in "/noodlebot:triage "*) id=t${2##* } ;; *) id=${2##* } ;; esac
r=$(pwd -P | sed 's#.*/worktrees/\([^/]*\)/.*#\1#')
cat "$q/data/state/$r/heartbeat" >"$q/hb.$id" 2>/dev/null   # the heartbeat of the tick that started it (qhb)
echo "$(date +%s.%N) $r $id" >>"$q/starts.log"
while [ ! -e "$q/end" ] && [ ! -e "$q/end.$id" ]; do sleep 0.2; done
case $id in t*) ;; *) echo "Q1: x" >"$q/data/state/$r/node/$id/QUESTION.md" ;; esac
exit 0
EOF
	sed "s|@Q@|$q|g" >"$q/bin/gh" <<'EOF'
#!/bin/sh
q=@Q@
r=$(echo "$*" | sed -n 's#.*repos/o/\([a-z]*\)[/ ?].*#\1#p')
case " $* " in
*" --state merged "*) date +%s.%N >>"$q/ticks.$(echo "$*" | sed -n 's#.*--repo o/\([a-z]*\).*#\1#p')"; exit 0 ;;   # once a tick (qtickt)
*" --state "*) exit 0 ;;
*"/issues?labels=noodlebot"*) cat "$q/issues.$r.json" ;;
*"/events"*) echo '[{"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "o"}}]' ;;
*" DELETE "*"/labels/noodlebot"*)
	n=$(echo "$*" | sed -n 's#.*issues/\([0-9]*\)/labels.*#\1#p')
	python3 -I -c 'import json,sys; f=sys.argv[1]; n=int(sys.argv[2]); json.dump([i for i in json.load(open(f)) if i["number"] != n], open(f, "w"))' "$q/issues.$r.json" "$n"; echo '[]' ;;
*"/labels"*) cat >/dev/null; echo '{}' ;;
esac
exit 0
EOF
	chmod +x "$q/bin/claude" "$q/bin/gh"
}
qlog() { echo "$qd/state/$1/status.log"; }
qn() { wc -l <"$q/starts.log"; }
qhave() { grep -q " $1\$" "$q/starts.log"; }
qt() { awk -v i="$1" '$3 == i { print $1 }' "$q/starts.log" | head -n1; }
qseq() { sort -n "$q/starts.log" | awk '{ printf "%s ", $3 }' | sed 's/ $//'; }
qpairs() { awk '{ print $2 ":" $3 }' "$q/starts.log" | sort | tr '\n' ' ' | sed 's/ $//'; }
# qgap_ok <min seconds>: consecutive starts (all repositories, by the sessions' own clocks) are at least that far apart.
qgap_ok() { sort -n "$q/starts.log" | awk -v g="$1" 'NR > 1 && $1 - p < g { bad = 1 } { p = $1 } END { exit bad }'; }
# the start events of both status logs: their times (epoch seconds, sorted), and the events of one unit
qlogtimes() { cat "$(qlog qa)" "$(qlog qb)" 2>/dev/null | grep -E '; started (triage|update|[A-Z][0-9][0-9])' | awk '{ print $1 }' | while read -r t; do date -d "$t" +%s; done | sort -n; }
qlog_gap_ok() { qlogtimes | awk -v g="$1" 'NR > 1 && $1 - p < g { bad = 1 } { p = $1 } END { exit bad }'; }
qev() { cat "$(qlog qa)" "$(qlog qb)" 2>/dev/null | grep -E "; started $1"; }
qev_has() { qev "$1" | grep -qE "$2"; }
qev_hasnt() { qev "$1" | grep -qE '; turn: ' && ! qev "$1" | grep -qiE "$2"; }
qgap_n() { [ "$(qn)" = "$1" ] && qgap_ok "$2"; }
# qwait <seconds> <command...>: a positive wait (the check that follows fails if it ran out). Three times the time asked: a
# loop on a loaded machine needs more, and a wait that succeeds costs nothing; no check states its bound through qwait.
qwait() { local to=$(( $1 * 3 )) end; shift; end=$(( $(date +%s) + to )); until "$@"; do [ "$(date +%s)" -ge "$end" ] && return 1; sleep 0.1; done; }
qn_ge() { [ "$(qn)" -ge "$1" ]; }
qwait_n() { qwait "$1" qn_ge "$2"; }
qrec() { cat "$qd/state/$1/$2/waiting" 2>/dev/null; }
qseed() { mkdir -p "$qd/state/$1/$2"; echo $(( $(date +%s) - $3 )) >"$qd/state/$1/$2/waiting"; }
qfirst() { grep -q 'open=\[' "$(qlog "$1")" 2>/dev/null; }
qopen() { echo "open: test opens" >"$q/usage"; }
qhold() { echo "hold: test holds" >"$q/usage"; }
# qev_ge <n>: the status logs of both loops have n start events (the old fixed sleeps after the last start let them be written).
qev_ge() { [ "$(qev '' | wc -l)" -ge "$1" ]; }
# qticks <n> [qa|qb...]: each of those loops (default qa) has started n more ticks (its heartbeat changed n times), counted
# at the same time. Where a check says something did NOT happen, this is the wait (D03's rule). Gives up after 3 ticks and
# 10 s a tick (the loop's tick, qtk, on a loaded machine).
declare -A qtk=()
qticks() {
	local n=$1 l k end t=1; shift; [ $# -gt 0 ] || set -- qa
	local -A last=() left=()
	for l in "$@"; do last[$l]=$(cat "$qd/state/$l/heartbeat" 2>/dev/null); left[$l]=$n; [ "${qtk[$l]:-1}" -gt $t ] && t=${qtk[$l]}; done
	end=$(( $(date +%s) + n * (3 * t + 10) ))
	while :; do
		k=0
		for l in "$@"; do
			if [ "${left[$l]}" -gt 0 ] && _hbchg "${last[$l]}" "$qd/state/$l"; then
				last[$l]=$(cat "$qd/state/$l/heartbeat" 2>/dev/null); left[$l]=$((left[$l] - 1))
			fi
			k=$((k + left[$l]))
		done
		[ $k = 0 ] && return 0
		[ "$(date +%s)" -lt "$end" ] || return 1
		sleep 0.1
	done
}
# qlisted <qa|qb> <key>[:<kind>]...: that loop's waiting.json lists those units (of that kind).
qlisted() {
	local f=$qd/state/$1/waiting.json k; shift
	for k in "$@"; do
		case $k in
		*:*) grep -qF "\"key\": \"${k%%:*}\", \"kind\": \"${k#*:}\"" "$f" 2>/dev/null || return 1 ;;
		*) grep -qF "\"key\": \"$k\"" "$f" 2>/dev/null || return 1 ;;
		esac
	done
}
# qcompete "<qa units>" "<qb units>": wait until each loop lists every unit that is to compete (before the throttle opens).
qcompete() { qwait 8 qlisted qa $1; qwait 8 qlisted qb $2; }
# qhb <id>: the heartbeat (epoch second) of the tick of its loop that started the session.
qhb() { cat "$q/hb.$1" 2>/dev/null; }
# qtickt <qa|qb> <from> <to>: how many ticks of that loop asked for the merged PRs (early in a tick, before the throttle
# is read) after <from> and before <to> (epoch seconds, with fractions). Not with qghx when merged.<repo>.tsv exists.
qtickt() { awk -v a="$2" -v b="$3" '$1 > a && $1 < b' "$q/ticks.$1" 2>/dev/null | wc -l; }
qalive() { local p; p=$(cat "$qd/state/$1/session.pid" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
qloop() { # <qa|qb> <tick> [VAR=value...]
	local n=$1 t=$2; shift 2
	qtk[$n]=$t
	( exec env NOODLEBOT_DATA="$qd" PATH="$q/bin:$PATH" SCHED_RAMP=1 SCHED_REPORT=0 SCHED_TICK="$t" SCHED_POLL=0.2 "$@" \
		bash "$qnb/scheduler/loop.sh" "o/$n" >>"$q/loop-$n.out" 2>&1 ) &
	qp[$n]=$!; pids+=("$!")
}
# qboth <qa tick> <qb tick> [VAR=value...]: both loops start with the throttle holding; each does its first tick.
qboth() { local ta=$1 tb=$2; shift 2; qhold; qloop qa "$ta" "$@"; qloop qb "$tb" "$@"; qwait 8 qfirst qa; qwait 8 qfirst qb; }
qstop() {
	local n
	for n in qa qb; do [ -n "${qp[$n]:-}" ] && { kill -KILL "${qp[$n]}"; wait "${qp[$n]}"; } 2>/dev/null; done
	touch "$q/end"; sleep 0.3  # nothing to observe: the sessions end on their own; then
	pkill -f "$q/" 2>/dev/null; rm -f "$HOME/STOP-qa" "$HOME/STOP-qb"; qp=()
}
qok() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; echo "      starts: $(qseq 2>/dev/null)"; fi; }
qjson_n=0 qjson_bad=0
qsample() { # every machine-wide file that exists is well-formed JSON
	local f
	for f in "$qd/state/starts.json" "$qd/state/qa/waiting.json" "$qd/state/qb/waiting.json"; do
		[ -e "$f" ] || continue
		qjson_n=$((qjson_n + 1))
		python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null || qjson_bad=$((qjson_bad + 1))
	done
}
# qrun_until <seconds> <starts>: sample the JSON files until that many sessions have started (or time is up), then a little longer.
qrun_until() {
	local end=$(( $(date +%s) + $1 * 3 )) settle
	while [ "$(qn)" -lt "$2" ] && [ "$(date +%s)" -lt "$end" ]; do qsample; sleep 0.05; done
	wait_until 30 qev_ge "$2"   # every start has its event in the status log (written by the loop after the session began)
	# a sampling window, not a wait: the loops rewrite the files every tick and nothing marks the last write; 2 s more
	# samples (after the last start) for the well-formed-JSON check
	settle=$(( $(date +%s) + 2 )); while [ "$(date +%s)" -lt "$settle" ]; do qsample; sleep 0.05; done
}

# -- Review phases (GREEN 5dc78a6 review): liveness of a loop whose tick ends early, the triage/update slot, a failed
# issues.py next, and the units of kind update, follow-up, resumed and a fresh node with no Size.
# qghx: the fake gh with more answers (the base fake is kept as gh.base). Files in $q:
#   ghfail.<repo>   every `gh pr list` of that repository fails      issfail   the issue list fails
#   open.<repo>.tsv / merged.<repo>.tsv   the open / merged PR lines ("<number> <branch> <oid> <is_bot> <mergeable>" / "<number> <branch>")
qghx() {
	mv "$q/bin/gh" "$q/bin/gh.base"
	sed "s|@Q@|$q|g" >"$q/bin/gh" <<'EOF'
#!/bin/sh
q=@Q@
r=$(echo "$*" | sed -n 's#.*--repo o/\([a-z]*\).*#\1#p')
case " $* " in
*" --state "*) [ -e "$q/ghfail.$r" ] && exit 1 ;;
esac
case " $* " in
*" --state merged "*) [ -e "$q/merged.$r.tsv" ] && { cat "$q/merged.$r.tsv"; exit 0; } ;;
*" --state open "*) [ -e "$q/open.$r.tsv" ] && { cat "$q/open.$r.tsv"; exit 0; } ;;
*"/issues?labels=noodlebot"*) [ -e "$q/issfail" ] && exit 1 ;;
esac
exec "$q/bin/gh.base" "$@"
EOF
	chmod +x "$q/bin/gh"
}

# -- Phase R: S06's resume takes a turn (S07-AC-6). A02 (qa) starts first and goes idle by the usage limit (its fake claude writes
# an init line and a rejected rate_limit_event that reset 300 s ago, and waits); B01 (qb) is a fresh S node. Gap 4 s.
# A resume (claude --resume, found by its argument) is logged as "<ID>.r" in $q/starts.log.
qresetup() { # <tag> : as qsetup A02:S / B01:S, with a claude that can go idle and resume
	qsetup "$1" "A02:S" "B01:S"
	cp "$src"/limit-resume.md "$qnb/scheduler/"
	sed "s|@Q@|$q|g" >"$q/bin/claude" <<'EOF'
#!/bin/sh
q=@Q@
r=$(pwd -P | sed 's#.*/worktrees/\([^/]*\)/.*#\1#')
case " $* " in
*" --resume "*) id=$(basename "$(pwd -P)").r; res=1 ;;
*) id=${2##* }; res=0 ;;
esac
echo "$(date +%s.%N) $r $id" >>"$q/starts.log"
if [ $res = 1 ]; then
	echo '{"type":"system","subtype":"init","session_id":"sid-resumed","resumed_run":true}'
elif [ "$id" = A02 ]; then
	echo '{"type":"system","subtype":"init","session_id":"sid-A02"}'
	t=$(( $(date +%s) - 300 ))
	echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":'$t',"rateLimitType":"five_hour"}}'
fi
while [ ! -e "$q/end" ] && [ ! -e "$q/end.$id" ]; do sleep 0.2; done
exit 0
EOF
	chmod +x "$q/bin/claude"
}
qpid() { cat "$qd/state/qa/node/A02/session.pid" 2>/dev/null; }
qresev() { grep -E 'resuming session A02' "$(qlog qa)"; }
qres_logged() { [ -n "$(qresev)" ]; }
qres_has() { qresev | grep -qE "$1"; }

