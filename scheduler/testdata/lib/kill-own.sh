# Sourced (POSIX sh or bash): the guarded kill of a test's cleanup or fake (D14).
#   kill_own <folder> <pidfile>...   KILL to the process group and to the pid each file holds, when kill_own_ok says so
#   kill_own_ok <folder> <pid>       status 0 when the pid may be signalled
# A pid is signalled only when it is a number above 1 (a parent that has ended makes $PPID 1, and `kill -- -1`
# signals every process of the user) and /proc/<pid>/cmdline names <folder>/, as given or in its canonical form.
# Nothing is signalled when <folder> is empty, /, canonically /, not absolute or not an existing directory.
# It only reads /proc and signals: no wait, sleep or retry.
kill_own_ok() {
	_ko_dir=$1 _ko_pid=$2
	case $_ko_dir in /*) ;; *) return 1 ;; esac
	[ -d "$_ko_dir" ] || return 1
	_ko_canon=$(cd "$_ko_dir" 2>/dev/null && pwd -P) || return 1
	case $_ko_canon in /*) ;; *) return 1 ;; esac
	case $_ko_dir in *[!/]*) ;; *) return 1 ;; esac
	case $_ko_canon in *[!/]*) ;; *) return 1 ;; esac
	case $_ko_pid in '' | *[!0-9]*) return 1 ;; esac
	[ "$_ko_pid" -gt 1 ] 2>/dev/null || return 1
	[ -r "/proc/$_ko_pid/cmdline" ] || return 1
	# one argument per line, so that a match lies inside one argument
	_ko_cmd=$(tr '\0' '\n' <"/proc/$_ko_pid/cmdline" 2>/dev/null) || return 1
	case $_ko_cmd in
	*"$_ko_dir/"* | *"$_ko_canon/"*) return 0 ;;
	esac
	return 1
}
kill_own() {
	_ko_folder=$1
	shift
	for _ko_f in "$@"; do
		[ -f "$_ko_f" ] || continue
		_ko_p=$(cat "$_ko_f" 2>/dev/null)
		kill_own_ok "$_ko_folder" "$_ko_p" || continue
		kill -s KILL -- "-$_ko_p" 2>/dev/null
		kill -s KILL "$_ko_p" 2>/dev/null
	done
	return 0
}
