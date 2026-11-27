#!/bin/sh
# S12's fake `systemd-run`: logs its arguments (one line per call) to $S12_LOG/sd.log; with S12_SD_FAIL set it fails before
# running anything, as with no user bus; else, as the real one with --scope, it marks the processes of its command for the
# unit (the variable S12_UNIT_MARK, inherited) and execs the command. The unit and each property of a call go to
# $S12_LOG/sd.unit and sd.props.
rec=${S12_LOG:?S12_LOG}
echo "systemd-run $*" >>"$rec/sd.log"
if [ -n "${S12_SD_FAIL:-}" ]; then
	echo "Failed to connect to bus: No medium found" >&2
	exit 1
fi
unit=
while [ $# -gt 0 ]; do
	case $1 in
	--unit=*) unit=${1#--unit=} ;;
	--unit | -u) unit=$2; shift ;;
	--property=*) echo "${1#--property=}" >>"$rec/sd.props" ;;
	--property | -p) echo "$2" >>"$rec/sd.props"; shift ;;
	-p?*) echo "${1#-p}" >>"$rec/sd.props" ;;
	--slice | --description | -E | --setenv | --working-directory | -d) shift ;;
	--) shift; break ;;
	-*) ;;
	*) break ;;
	esac
	shift
done
[ -n "$unit" ] || unit=run-$$
echo "$unit" >"$rec/sd.unit"
S12_UNIT_MARK=$unit
export S12_UNIT_MARK
exec "$@"
