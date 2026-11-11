# Sourced by scheduler/report*.test.sh. Python that a test needs many times is served by a python that is already running,
# so a call costs a few milliseconds and not an interpreter's start-up plus the import of json; the source that answers
# (the fake gh's script, the check's query) is the same, and so are the answers.
#   fakegh_install <dir>: <dir>/gh.py holds a fake `gh` written in python; this puts a `gh` in <dir> that sends each call
#     to the server (report-fakegh-server.py) running that script.
#   pyc_install <dir>: <dir>/pyc <code> <args>... runs `python3 -I -c <code> <args>...` on a server.
# The server of a folder ends with the test (it watches the test's pid and the folder).
fakegh_install() {
	[ -s "$1/gh.py" ] || return 1
	fakegh_serve "$1" gh
	{
		fakegh_client_head "$1" 'exec python3 -I "$d/gh.py" "$@"'
		cat <<'CLIENT'
for a in "$@"; do
	if [ "$a" = --input ]; then
		while IFS= read -r l || [ -n "$l" ]; do printf '%s\n' "$l"; l=; done >"$d/in.$id"
	fi
done
printf '%s\0' "$@" >"$d/args.$id"
CLIENT
		fakegh_client_tail
	} >"$1/gh"
	chmod +x "$1/gh"
}
pyc_install() {
	fakegh_serve "$1" pyc
	{
		fakegh_client_head "$1" 'exec python3 -I -c "$@"'
		cat <<'CLIENT'
printf '%s\0' "$@" >"$d/args.$id"
case $1 in *environ*) export -p >"$d/env.$id" ;; esac
CLIENT
		fakegh_client_tail
	} >"$1/pyc"
	chmod +x "$1/pyc"
}
# fakegh_serve <dir> <gh|pyc>: starts the server for <dir>; its pid is in <dir>/pid.
fakegh_serve() {
	mkfifo "$1/req"
	python3 -I "$fakegh_lib/report-fakegh-server.py" "$1" $$ "$2" </dev/null >/dev/null 2>&1 &
	echo "$!" >"$1/pid"
}
# fakegh_client_head <dir> <command when the server is gone>
fakegh_client_head() {
	printf '#!/bin/sh\nd=%s\nread pid <"$d/pid" 2>/dev/null\nif ! kill -0 "$pid" 2>/dev/null; then %s; fi\nid=$$\n' "'$1'" "$2"
}
# the end of a client: sends the request and plays back the server's answer (o<line> stdout, e<line> stderr, r<code>).
fakegh_client_tail() {
	cat <<'CLIENT'
mkfifo "$d/resp.$id" 2>/dev/null
exec 3<>"$d/resp.$id"
echo $id >"$d/req"
while IFS= read -r l <&3; do
	case $l in
	o*) printf '%s\n' "${l#o}" ;;
	e*) printf '%s\n' "${l#e}" >&2 ;;
	r*) exit "${l#r}" ;;
	esac
done
CLIENT
}
# pyc_setup: `pyc <code> <args>...` in the test's PATH, for the checks' queries (`python3 -I -c` of the old tests).
pyc_setup() {
	mkdir -p "$tmp/pybin"
	pyc_install "$tmp/pybin"
	PATH=$tmp/pybin:$PATH
	export PATH
}
