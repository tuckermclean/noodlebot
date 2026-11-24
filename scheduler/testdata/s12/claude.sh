#!/bin/sh
# S12's fake `claude` (installed as "claude" on a scratch PATH): the agent CLI of scheduler/run-session-s12.test.sh.
# Everything goes to $S12_LOG; knobs (environment): S12_DIR the session's state folder, S12_RC the exit code (default 0),
# S12_LEFT=1 leave a child behind (leftover.sh, which ignores HUP and TERM and holds this stdout open), S12_SETSID=1 start
# it with setsid (out of this process group).
rec=${S12_LOG:?S12_LOG}
echo "$$" >"$rec/claude.pid"
echo "$PPID" >"$rec/claude.ppid"
cat "$S12_DIR/agent.pid" >"$rec/claude.agentpid" 2>/dev/null
cat "/proc/$$/oom_score_adj" >"$rec/claude.oom"
printf '%s\n' "${TMPDIR-UNSET}" >"$rec/claude.tmpdir"
if [ -d "${TMPDIR:-}" ]; then
	ls -A "$TMPDIR" >"$rec/claude.tmpls"
	: >"$TMPDIR/s12file"
else
	echo NODIR >"$rec/claude.tmpls"
fi
printf '%s\n' "${S12_UNIT_MARK-UNSET}" >"$rec/claude.mark"
printf '%s\n' '{"type":"result","subtype":"success","result":"ok"}'
if [ -n "${S12_LEFT:-}" ]; then
	if [ -n "${S12_SETSID:-}" ]; then setsid sh "$S12_LEFTOVER" "$rec/left.pid" &
	else sh "$S12_LEFTOVER" "$rec/left.pid" &
	fi
	# the child has written its pid once it holds the output open and ignores the signals
	i=0
	while [ ! -s "$rec/left.pid" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
fi
date +%s%N >"$rec/claude.end"
exit "${S12_RC:-0}"
