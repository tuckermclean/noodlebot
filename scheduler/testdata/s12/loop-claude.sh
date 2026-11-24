#!/bin/sh
# S12's `claude` for the loop run (scheduler/loop-s12.test.sh), installed first on the PATH in front of the G03 fixture's.
# The sessions that end out of memory kill themselves with SIGKILL after leaving $S12/oom/<unit> (the fake systemctl then
# reports oom-kill for that unit); every other session is the G03 fake's ($S12_BASE_CLAUDE). Per session (id, run n):
#   node.X03   run n: out/node/X03/brief.md (so that the next start is a resume), holds while $S12/hold.node.X03.<n> exists, killed
#   node.X04   QUESTION.md, exit 0
#   triage.t   run 1 killed; later runs QUESTION.md (the issue's), exit 0
#   fbnode.11  run 1 killed; later runs exit 0
# Records in $S12: sys.<id>.<n> (the rendered prompt), runs.<id> (written last), oom/<unit>.
S=${S12:?S12}
p=$2
case $p in
"/noodlebot:node --feedback 11") id=fbnode.11 ;;
"/noodlebot:node X03") id=node.X03 ;;
"/noodlebot:node X04") id=node.X04 ;;
"/noodlebot:triage "[0-9]*) id=triage.t ;;
*) exec "$S12_BASE_CLAUDE" "$@" ;;
esac
n=$(($(cat "$S/runs.$id" 2>/dev/null || echo 0) + 1))
while [ $# -gt 0 ]; do
	[ "$1" = --append-system-prompt ] && { printf '%s\n' "$2" >"$S/sys.$id.$n"; break; }
	shift
done
echo "$n" >"$S/runs.$id"
oom() { mkdir -p "$S/oom" && : >"$S/oom/${S12_UNIT_MARK:-none}"; kill -KILL $$; sleep 5; }
case $id.$n in
node.X03.*)
	mkdir -p out/node/X03 && echo "brief of X03" >out/node/X03/brief.md
	while [ -e "$S/hold.node.X03.$n" ]; do sleep 0.2; done
	oom ;;
node.X04.*) echo "Q1: x" >"$S12_STATE/node/X04/QUESTION.md" ;;
triage.t.1) oom ;;
triage.t.*) echo "Q1: x" >"$S12_STATE/issue/46/QUESTION.md" ;;
fbnode.11.1) oom ;;
esac
exit 0
