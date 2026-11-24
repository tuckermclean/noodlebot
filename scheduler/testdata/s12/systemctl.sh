#!/bin/sh
# S12's fake `systemctl --user`: logs its arguments (one line per call) to $S12_LOG/ctl.log.
#   stop <unit>          SIGTERM, then (after at most 1 s) SIGKILL to the processes marked for the unit (S12_UNIT_MARK in
#                        their environment) that are still running, as the stop of a scope's cgroup does; with S12_STOP_FAIL
#                        set it kills nothing and exits 1
#   show -p Result ...   prints $S12_RESULT (default success), as "Result=<value>" or, with --value, the value alone
#   reset-failed <unit>  nothing
rec=${S12_LOG:?S12_LOG}
echo "systemctl $*" >>"$rec/ctl.log"
op= unit= val=
for a in "$@"; do
	case $a in
	--user | -p | Result) ;;
	--value) val=1 ;;
	-*) ;;
	*) if [ -z "$op" ]; then op=$a; else unit=$a; fi ;;
	esac
done
marked() {
	grep -l -a -z -x -F -s "S12_UNIT_MARK=$unit" /proc/[0-9]*/environ 2>/dev/null | sed 's|^/proc/\([0-9]*\)/environ$|\1|' | grep -vx "$$"
}
alive() {
	for _p in $1; do
		_st=$(sed 's/.*) //' "/proc/$_p/stat" 2>/dev/null | cut -c1)
		[ -n "$_st" ] && [ "$_st" != Z ] && echo "$_p"
	done
}
case $op in
stop)
	if [ -n "${S12_STOP_FAIL:-}" ]; then echo "Failed to stop $unit: Access denied" >&2; exit 1; fi
	p=$(alive "$(marked)")
	[ -z "$p" ] || kill -s TERM $p 2>/dev/null
	i=0
	while [ "$i" -lt 10 ]; do
		p=$(alive "$(marked)")
		[ -n "$p" ] || exit 0
		sleep 0.1
		i=$((i + 1))
	done
	[ -z "$p" ] || kill -s KILL $p 2>/dev/null
	exit 0
	;;
show)
	r=${S12_RESULT:-success}
	if [ -n "$val" ]; then echo "$r"; else echo "Result=$r"; fi
	;;
esac
exit 0
