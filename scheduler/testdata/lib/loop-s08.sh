# Shared by loop-s08*.test.sh (source after loop-prelude.sh): the fixture of the S08 runs (SCHED_HARNESS, capabilities).
# One remote with the node N01. A run is a loop (1 s tick) over its own runtime root $tmp/d-<name> (repo o/<name>), on a
# copy of the scheduler in $nb08 whose fake harness is testdata/lib/fake-harness-hold.py (see its header). Calls of the
# fake harness are logged to $S08/<name>.log; the scenario's own files are in $S08/<name>/ (starts, pid.<n>).
# $tmp/bin08 has a gh that knows nothing and a `claude` that writes $S08/claude-called and exits 99: a run on the fake
# harness never calls it. $tmp/bin08cc has a `claude` that records its run in $S08/cc-<name> and exits 0.
S08=$tmp/s08; export S08
nb08=$tmp/nb08
mkdir -p "$S08" "$tmp/bin08" "$tmp/bin08cc" "$nb08/scheduler/harnesses" "$nb08/scheduler/testdata/harness" "$nb08/plugin"
cp_scheduler "$nb08/scheduler"
cp "$src/harness.py" "$nb08/scheduler/"
cp "$src"/harnesses/*.py "$nb08/scheduler/harnesses/"
cp "$src/testdata/harness/fake.py" "$nb08/scheduler/testdata/harness/fake_real.py"
cp "$src/testdata/lib/fake-harness-hold.py" "$nb08/scheduler/testdata/harness/fake.py"
git init -q -b main "$tmp/work08"; mkdir -p "$tmp/work08/docs"
printf 'nodes:\n  - {id: N01, name: first, deps: []}\n' >"$tmp/work08/docs/graph.yaml"
git -C "$tmp/work08" add -A && git -C "$tmp/work08" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work08" "$tmp/remote08.git"
cat >"$tmp/bin08/gh" <<'EOT'
#!/bin/sh
case " $* " in
*" --state open "* | *" --state merged "* | *" --state closed "*) ;;
*"/issues?labels=noodlebot"*) echo '[]' ;;
*"/events"*) echo '[]' ;;
*"/labels"*) cat >/dev/null; echo '{}' ;;
esac
exit 0
EOT
cp "$tmp/bin08/gh" "$tmp/bin08cc/gh"
printf '#!/bin/sh\necho "$*" >>"$S08/claude-called"\nexit 99\n' >"$tmp/bin08/claude"
printf '#!/bin/sh\necho "$*" >>"$S08/cc-$(basename "$(dirname "$(pwd -P)")")"\nexit 0\n' >"$tmp/bin08cc/claude"
chmod +x "$tmp/bin08/gh" "$tmp/bin08/claude" "$tmp/bin08cc/gh" "$tmp/bin08cc/claude"

# s08root <name>: the runtime root of a run: its repository clone and node folder.
s08root() {
	local d=$tmp/d-$1
	mkdir -p "$d/state/$1/node" "$S08/$1"
	[ -d "$d/repos/$1" ] || { mkdir -p "$d/repos"; git clone -q "$tmp/remote08.git" "$d/repos/$1"; }
}
# s08loop <name> <bin dir> [VAR=value...]: start the loop of o/<name> in the background (pid in $s08pid).
s08loop() {
	local n=$1 b=$2; shift 2
	s08root "$n"
	env NOODLEBOT_DATA="$tmp/d-$n" PATH="$b:$PATH" SCHED_REPORT=0 SCHED_SITE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		S08_DIR="$S08/$n" FAKE_HARNESS_LOG="$S08/$n.log" "$@" bash "$nb08/scheduler/loop.sh" "o/$n" >>"$tmp/$n.out" 2>&1 &
	s08pid=$!; pids+=("$s08pid")
}
# s08st <name>: its status log. s08n <name> <regex>: how many lines of it match. s08calls <name> <word>: calls logged.
s08st() { echo "$tmp/d-$1/state/$1/status.log"; }
s08n() { local c; c=$(grep -cE -- "$2" "$(s08st "$1")" 2>/dev/null); echo "${c:-0}"; }
s08calls() { local c; c=$(grep -c "^$2 " "$S08/$1.log" 2>/dev/null); echo "${c:-0}"; }
s08calls_ge() { [ "$(s08calls "$1" "$2")" -ge "$3" ]; }
s08line() { grep -qE -- "$2" "$(s08st "$1")" 2>/dev/null; }
# s08ticks <name> <n>: n more ticks of that loop.
s08ticks() { wait_ticks "$2" "$tmp/d-$1/state/$1"; }
# s08limit <file> <sid>: a script whose session starts, works, and ends on a rejected five-hour window that reset 5 minutes ago.
s08limit() {
	local r=$(($(date +%s) - 300))
	{
		printf '{"type":"start","t":null,"session":"%s"}\n' "$2"
		printf '{"type":"tool","t":null,"id":"t1","name":"Bash","text":"ls","label":"ls","subagent":false,"background":false,"delay":null,"desc":null}\n'
		printf '{"type":"usage","t":null,"status":"rejected","has_status":true,"info_bad":false,"reset":%s,"window":"five_hour","utilization":1.0,"windows":{"five_hour":{"status":"rejected","has_status":true,"utilization":1.0,"reset":%s}}}\n' "$r" "$r"
	} >"$1"
}
# s08resumed <file> <sid>: the resumed session's script: init, a text, a result.
s08resumed() {
	{
		printf '{"type":"start","t":null,"session":"%s"}\n' "$2"
		printf '{"type":"text","t":null,"text":"resumed","subagent":false}\n'
		printf '{"type":"result","t":null,"subtype":"success","text":"done","cost":null,"turns":1,"limit":false}\n'
	} >"$1"
}
# s08plain <file>: a session that starts and ends without a limit.
s08plain() {
	{
		printf '{"type":"start","t":null,"session":"sid-plain"}\n'
		printf '{"type":"result","t":null,"subtype":"success","text":"done","cost":null,"turns":1,"limit":false}\n'
	} >"$1"
}
