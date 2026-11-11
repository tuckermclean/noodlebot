# Sourced by scheduler/report*.test.sh: the fake session process report.py finds by its command line, and the stream-json
# result line the fake sessions' logs are made of.
# rs_script: $tmp/rs/run-session.sh, a script that only waits (`sh "$tmp/rs/run-session.sh" --node A03 &` is a live session).
rs_script() {
	mkdir -p "$tmp/rs"
	printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$tmp/rs/run-session.sh"
}
# rs_wait <pid>...: until each background `sh run-session.sh` has exec'd, so that its command line (the one report.py reads)
# names the script; at most 10 seconds (it was a fixed second).
rs_wait() {
	for p in "$@"; do
		i=0
		until case $(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null) in *run-session.sh*) true ;; *) false ;; esac || [ $i -ge 500 ]; do
			sleep 0.02
			i=$((i + 1))
		done
	done
}
r() { printf '{"type":"result","subtype":"success","total_cost_usd":%s,"num_turns":%s,"result":"x"}\n' "$1" "$2"; }
