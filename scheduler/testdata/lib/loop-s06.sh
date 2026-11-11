# Shared by loop-s06*.test.sh (source after loop-prelude.sh): the helpers of the S06 runs. They read $S06 (the fake claude's record
# folder), $st06 (the loop's state folder) and $nb06 (its scheduler checkout): a file points those at its own run.
S06_LIB=$src/testdata/lib; export S06_LIB   # the fake claude of an S06 run sources loop-s06-rej.sh from here
x6ok() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
x6wait() { local t=$(($1 * 3)); shift; wait_until "$t" "$@"; }   # a positive wait: three times the time asked, for a loaded machine (no S06 label states a bound)
x6nm() { case $1 in issue-*) echo "#${1#issue-}" ;; pr-*) echo "PR #${1#pr-}" ;; *) echo "$1" ;; esac; }
x6sd() { case $1 in issue-*) echo "$st06/issue/${1#issue-}" ;; pr-*) echo "$st06/pr/${1#pr-}" ;; *) echo "$st06/node/$1" ;; esac; }
x6f() { cat "$S06/$1" 2>/dev/null; }
x6runs() { cat "$S06/runs.$1" 2>/dev/null || echo 0; }
x6have() { local f; for f in "$@"; do [ -e "$S06/$f" ] || return 1; done; }
x6grp_gone() { [ -n "$1" ] && ! ps -eo pgid=,stat= | awk -v g="$1" '$1 == g && $2 !~ /^Z/ { f = 1 } END { exit !f }'; }
x6dead() { [ -n "$1" ] && { [ ! -d "/proc/$1" ] || grep -q ') Z' "/proc/$1/stat"; }; }
x6log() { cat "$st06/status.log" 2>/dev/null; }
x6evn() { grep -F "$(x6nm "$1")" "$st06/status.log" 2>/dev/null | grep -cE "$2"; }
x6rst() { local e; e=$(x6f "reset.$1"); [ -n "$e" ] && echo "$e|$(date -u -d "@$e" +%H:%M:%S)"; }
x6noresume_re='could not.{0,20}resum|cannot.{0,20}resum|unable to.{0,20}resum|resum.{0,30}not possible|not possible.{0,20}resum'
x6res_n() { local r; r=$(x6rst "$1") || { echo 0; return; }; grep -F "$(x6nm "$1")" "$st06/status.log" 2>/dev/null | grep -iE 'resum' | grep -E "$r" | grep -ivE "$x6noresume_re" | wc -l; }
x6nores_n() { grep -F "$(x6nm "$1")" "$st06/status.log" 2>/dev/null | grep -icE "$x6noresume_re"; }
x6untouched() { # <key>: the session is as it was: its group is up, it is the recorded session, no rc, no resumed run
	local k=$1 sd; sd=$(x6sd "$k")
	! x6grp_gone "$(x6f "pg.$k")" && [ "$(cat "$sd/session.pid" 2>/dev/null)" = "$(x6f "pg.$k")" ] && [ ! -e "$sd/session.rc" ] &&
		[ "$(x6runs "$k")" = 1 ] && [ "$(x6res_n "$k")" = 0 ] && [ "$(x6nores_n "$k")" = 0 ]
}
x6args_ok() { # <key>: the options of the original session, --resume <sid>
	local k=$1 f="$S06/args.$1.2" e
	e=sid-$k
	[ -s "$f" ] && grep -qx -- '--resume' "$f" && [ "$(x6f "sid.$k.2")" = "$e" ] && grep -qx -- '-p' "$f" &&
		grep -qx -- '--plugin-dir' "$f" && grep -qx -- "$nb06/plugin" "$f" && grep -qx -- '--permission-mode' "$f" && grep -qx -- 'auto' "$f" &&
		grep -qx -- '--permission-prompts' "$f" && grep -qx -- 'none' "$f" && grep -qx -- '--output-format' "$f" && grep -qx -- 'stream-json' "$f" &&
		grep -qx -- '--verbose' "$f" && grep -qx -- '--append-system-prompt' "$f" &&
		[ -s "$S06/append.$k.2" ] && [ "$(x6f "append.$k.2")" = "$(cat "$(x6sd "$k")/unattended.md")" ] && [ "$(x6f "append.$k.2")" = "$(x6f "append.$k.1")" ]
}
x6prompt_says() { # <file>: the usage limit stopped the run and has reset; background work was killed; check, re-dispatch, carry on
	local p=$1
	[ -s "$p" ] && grep -qi 'usage limit' "$p" && grep -qi 'reset' "$p" && grep -qi 'background agents' "$p" && grep -qi 'background commands' "$p" &&
		grep -qi 'killed' "$p" && grep -qi 'check what' "$p" && grep -qiE 're-?dispatch' "$p" && grep -qi 'carry on' "$p" && ! grep -qE '@[A-Z]+@' "$p"
}
x6log_ok() { # <key>: the old lines are still the head of session.jsonl; the resumed run's lines follow
	local k=$1 j; j=$(x6sd "$k")/session.jsonl
	[ -s "$S06/log0.$k" ] && [ "$(head -n "$(wc -l <"$S06/log0.$k")" "$j" 2>/dev/null)" = "$(cat "$S06/log0.$k")" ] &&
		[ "$(grep -c '"resumed_run":true' "$j")" -ge 2 ] && [ "$(grep -n 'resumed_run' "$j" | head -1 | cut -d: -f1)" -gt "$(wc -l <"$S06/log0.$k")" ]
}
x6wt_ok() { # <key>: the same worktree, the same changes, HEAD, no leftover patch
	local k=$1 sd; sd=$(x6sd "$k")
	[ -s "$S06/pwd.$k.1" ] && [ "$(x6f "pwd.$k.2")" = "$(x6f "pwd.$k.1")" ] &&
		[ -s "$S06/status.$k.1" ] && [ "$(x6f "status.$k.2")" = "$(x6f "status.$k.1")" ] && grep -q 'base.txt' "$S06/status.$k.2" && grep -q "u.$k.txt" "$S06/status.$k.2" &&
		[ -s "$S06/head.$k.1" ] && [ "$(x6f "head.$k.2")" = "$(x6f "head.$k.1")" ] && grep -qx dirty "$S06/base.$k.2" &&
		[ -z "$(ls "$sd/leftover" 2>/dev/null)" ]
}
x6run_ok() { # <key>: the old group is gone, the new process is the session
	local k=$1 sd; sd=$(x6sd "$k")
	x6grp_gone "$(x6f "pg.$k")" && x6dead "$(x6f "child.$k")" && [ -n "$(x6f "pg2.$k")" ] && [ "$(x6f "pg2.$k")" != "$(x6f "pg.$k")" ] &&
		[ "$(cat "$sd/session.pid" 2>/dev/null)" = "$(x6f "pg2.$k")" ] && ! x6grp_gone "$(x6f "pg2.$k")" &&
		tr '\0' ' ' <"/proc/$(x6f "pg2.$k")/cmdline" 2>/dev/null | grep -q 'run-session\.sh'
}
x6starts_ok() { # <key>: starts is 1 (the original), and one "started" event
	local k=$1 sd; sd=$(x6sd "$k")
	[ "$(cat "$sd/starts" 2>/dev/null)" = 1 ] && [ "$(x6evn "$k" 'started ')" = 1 ] && [ "$(x6runs "$k")" = 2 ]
}
# The two rate-limit events the S06 runs write into a session log: x6rejected <resetsAt> and x6allowed <five_hour resetsAt> <seven_day resetsAt>.
x6rejected() { printf '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":%s,"status":"rejected"}}}}\n' "$1"; }
x6allowed() { printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.01,"resetsAt":%s,"status":"allowed"},"seven_day":{"utilization":0.0,"resetsAt":%s,"status":"allowed"}}}}\n' "$1" "$2"; }
