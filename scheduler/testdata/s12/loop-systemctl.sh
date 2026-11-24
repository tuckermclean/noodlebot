#!/bin/sh
# S12's `systemctl` for the loop run (scheduler/loop-s12.test.sh): the s12 fake (systemctl.sh, next to this file) with a
# Result of oom-kill for a unit whose first stage left $S12/oom/<unit> (the fake claude does that before it kills itself);
# every other unit reports success. Everything else is the fake's own.
case " $* " in
*" show "*)
	for a in "$@"; do u=$a; done
	if [ -e "${S12:?S12}/oom/$u" ] || [ -e "$S12/oom/${u%.scope}" ] || [ -e "$S12/oom/$u.scope" ]; then
		S12_RESULT=oom-kill
		export S12_RESULT
	fi
	;;
esac
exec sh "$(dirname "$0")/systemctl.sh" "$@"
