#!/bin/sh
# Tests container/entrypoint.sh: first start, later start, config refusals, SIGTERM (D06-AC-3, D06-AC-4, D06-AC-5).
#   sh container/entrypoint.test.sh   (make test)
#
# The contract the test relies on (the entrypoint is run as: sh container/entrypoint.sh, so it is POSIX sh):
#   NOODLEBOT_IMAGE_COPY   path of the image's copy of noodlebot; default /opt/noodlebot. The test points it at a
#                          fake copy: a small Git repository with a tag and an https origin URL.
#   id -u                  how the entrypoint finds out it runs as root. A fake `id` first on PATH answers
#                          $FAKE_UID (default 1000); FAKE_UID=0 simulates root.
#   tmux                   a fake on PATH. It records its calls and succeeds, for any subcommand, only while the flag
#                          file $TMUX_FLAG exists ("the tmux server lives"). The fake loops.sh start creates the
#                          flag, stop removes it. The entrypoint stays in the foreground while `tmux has-session`
#                          or `tmux ls` succeeds.
#   loops.sh               the fake lives in the copy's scheduler/ so the clone carries it; it logs "start <dir>" /
#                          "stop <dir>" into $LOOPS_LOG.
#   HOME                   a temporary home per scenario; the config folder is $HOME/.config/noodlebot.
# Offline, no container runtime. Every wait is a condition (wait_until / wait_file / wait_line).
set -u
src=$(cd "$(dirname "$0")/.." && pwd -P)
ep=$src/container/entrypoint.sh
. "$src/scheduler/testdata/lib/common.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
origin_url=https://example.invalid/owner/noodlebot.git

fakebin=$tmp/fakebin img=$tmp/image
mkdir -p "$fakebin" "$img/scheduler"
cat >"$fakebin/id" <<'EOS'
#!/bin/sh
[ "${1:-}" = -u ] && { echo "${FAKE_UID:-1000}"; exit 0; }
exec /usr/bin/id "$@"
EOS
cat >"$fakebin/tmux" <<'EOS'
#!/bin/sh
echo "tmux $*" >>"$TMUX_LOG"
[ -e "$TMUX_FLAG" ]
EOS
cat >"$img/scheduler/loops.sh" <<'EOS'
#!/bin/sh
d=$(cd "$(dirname "$0")" && pwd -P)
case ${1:-} in
start) echo "start $d" >>"$LOOPS_LOG"; : >"$TMUX_FLAG" ;;
stop) echo "stop $d" >>"$LOOPS_LOG"; rm -f "$TMUX_FLAG" ;;
esac
EOS
chmod +x "$fakebin/id" "$fakebin/tmux" "$img/scheduler/loops.sh"
(
	cd "$img" && git init -q . && git add scheduler &&
	git -c user.name=T -c user.email=t@example.invalid commit -q -m image &&
	git tag v0.0.1 && git remote add origin "$origin_url"
) >/dev/null 2>&1
PATH=$fakebin:$PATH
export PATH NOODLEBOT_IMAGE_COPY=$img
unset GIT_DIR GIT_WORK_TREE GIT_CONFIG_GLOBAL XDG_CONFIG_HOME

# scn <name> [files...]: a fresh scenario home with a config folder holding the listed files ("-" = no folder).
scn() {
	sdir=$tmp/$1; shift
	rm -rf "$sdir"; mkdir -p "$sdir/home"
	HOME=$sdir/home LOOPS_LOG=$sdir/loops.log TMUX_LOG=$sdir/tmux.log TMUX_FLAG=$sdir/tmux.flag
	export HOME LOOPS_LOG TMUX_LOG TMUX_FLAG
	: >"$LOOPS_LOG"; : >"$TMUX_LOG"; unset FAKE_UID
	cfg=$HOME/.config/noodlebot
	[ "${1:-}" = - ] && return 0
	mkdir -p "$cfg"
	for f in "$@"; do
		case $f in
		gitconfig) printf '[user]\n\tname = Fixture Owner\n' >"$cfg/$f" ;;
		*) echo x >"$cfg/$f" ;;
		esac
	done
}
FULL="repos token oauth-token"
run_bg() {
	rm -f "$sdir/pid" "$sdir/rc"
	( sh -c 'echo $$ >"$1"; exec sh "$2"' x "$sdir/pid" "$ep" >"$sdir/out" 2>&1; echo $? >"$sdir/rc" ) &
	wait_file 5 "$sdir/pid"; pid=$(cat "$sdir/pid" 2>/dev/null)
}
started() { grep -q '^[a-z-]*start ' "$LOOPS_LOG" 2>/dev/null || [ -e "$sdir/rc" ]; }
# stop_bg: SIGTERM the entrypoint (if it still runs), wait for its exit status into $rc ("none" if it never ends).
stop_bg() {
	[ -e "$sdir/rc" ] || kill -TERM "$pid" 2>/dev/null
	if wait_file 10 "$sdir/rc"; then rc=$(cat "$sdir/rc"); else rc=none; kill -KILL "$pid" 2>/dev/null; fi
}
count() { grep -c "^$1 " "$LOOPS_LOG" 2>/dev/null; }
checkout_dir() { echo "$HOME/gitrepos/noodlebot"; }

# --- D06-AC-3: first start, clone with the image's origin, the checkout's loops.sh start
scn first $FULL
run_bg; wait_until 15 started; co=$(checkout_dir)
if [ -d "$co/.git" ] && git -C "$co" rev-parse HEAD >/dev/null 2>&1; then
	pass "D06-AC-3 first start: ~/gitrepos/noodlebot is a Git checkout"
else fail "D06-AC-3 first start: ~/gitrepos/noodlebot is a Git checkout"; fi
[ "$(git -C "$co" rev-parse HEAD 2>/dev/null)" = "$(git -C "$img" rev-parse HEAD)" ] &&
	[ "$(git -C "$co" describe --tags 2>/dev/null)" = v0.0.1 ] &&
	pass "D06-AC-3 first start: the clone holds the image copy's commit and tag" ||
	fail "D06-AC-3 first start: the clone holds the image copy's commit and tag"
[ "$(git -C "$co" remote get-url origin 2>/dev/null)" = "$origin_url" ] &&
	pass "D06-AC-3 first start: origin is the image copy's origin URL" ||
	fail "D06-AC-3 first start: origin is the image copy's origin URL"
[ "$(cat "$LOOPS_LOG")" = "start $co/scheduler" ] &&
	pass "D06-AC-3 first start: the checkout's loops.sh start ran once" ||
	fail "D06-AC-3 first start: the checkout's loops.sh start ran once"
stop_bg

# --- D06-AC-3: later start after the checkout moved to another commit
# (a missing checkout, e.g. no entrypoint yet, gives an empty $moved and fails the checks below)
moved=
if [ -d "$co/scheduler" ]; then
	printf '%s\n' '#!/bin/sh' 'echo "moved-start $(cd "$(dirname "$0")" && pwd -P)" >>"$LOOPS_LOG"; : >"$TMUX_FLAG"' >"$co/scheduler/loops.sh"
	git -C "$co" -c user.name=T -c user.email=t@example.invalid commit -q -am moved >/dev/null 2>&1
	moved=$(git -C "$co" rev-parse HEAD)
fi
: >"$LOOPS_LOG"; rm -f "$TMUX_FLAG"
run_bg; wait_until 15 started
[ -n "$moved" ] && [ "$(git -C "$co" rev-parse HEAD 2>/dev/null)" = "$moved" ] &&
	pass "D06-AC-3 later start: the checkout stays at the commit it moved to" ||
	fail "D06-AC-3 later start: the checkout stays at the commit it moved to"
[ "$(cat "$LOOPS_LOG")" = "moved-start $co/scheduler" ] &&
	pass "D06-AC-3 later start: the moved checkout's loops.sh start ran" ||
	fail "D06-AC-3 later start: the moved checkout's loops.sh start ran"
stop_bg

# --- D06-AC-3: gitconfig include
scn gitcfg $FULL gitconfig
run_bg; wait_until 15 started
[ "$(cd "$tmp" && git config user.name 2>/dev/null)" = "Fixture Owner" ] &&
	pass "D06-AC-3 gitconfig: git config user.name in the home answers from the config folder's gitconfig" ||
	fail "D06-AC-3 gitconfig: git config user.name in the home answers from the config folder's gitconfig"
stop_bg

# --- D06-AC-4: refusals: non-zero, nothing started, one line naming the reason
# refuse <label> <reason-regex> <not-regex>
refuse() {
	label=$1 re=$2 nre=$3
	run_bg
	wait_file 10 "$sdir/rc"; got=$?
	[ $got -eq 0 ] || { kill -KILL "$pid" 2>/dev/null; echo none >"$sdir/rc"; }
	rc=$(cat "$sdir/rc")
	have=0; [ -f "$ep" ] && have=1   # a missing entrypoint is no refusal
	if [ "$have" = 1 ] && [ "$rc" != 0 ] && [ "$rc" != none ]; then pass "D06-AC-4 $label: exits non-zero"; else fail "D06-AC-4 $label: exits non-zero (got $rc)"; fi
	if [ "$have" = 1 ] && [ ! -s "$LOOPS_LOG" ] && [ ! -e "$HOME/gitrepos/noodlebot" ] && ! grep -q 'new-session\|new ' "$TMUX_LOG"; then
		pass "D06-AC-4 $label: nothing started"; else fail "D06-AC-4 $label: nothing started"; fi
	if [ "$(wc -l <"$sdir/out")" -eq 1 ] && grep -Eqi -- "$re" "$sdir/out" &&
		{ [ -z "$nre" ] || ! grep -Eqi -- "$nre" "$sdir/out"; }; then
		pass "D06-AC-4 $label: one line naming the reason"
	else fail "D06-AC-4 $label: one line naming the reason (got: $(tr '\n' '|' <"$sdir/out"))"; fi
}
scn root $FULL; FAKE_UID=0 refuse "root" 'root' ''
scn nodir -; refuse "missing config folder" 'config|\.config/noodlebot' ''
scn norepos token oauth-token; refuse "missing repos" 'repos' ''
scn notoken repos oauth-token; refuse "missing token script" 'token' 'oauth'
scn nooauth repos token; refuse "missing harness credential" 'oauth-token' ''

# --- D06-AC-4 (stricter): the reason must be the right one, as a whole token, after $HOME is replaced by ~
# (scenario folders are neutral, so a bare path in the message cannot satisfy a reason word)
# refuse2 <label> <reason-regex> <wrong-regex>
gone='(missing|not found|no such|absent|does not exist|not exist|cannot find|unreadable)'
refuse2() {
	label=$1 re=$2 wre=$3
	run_bg
	wait_file 10 "$sdir/rc" || { kill -KILL "$pid" 2>/dev/null; echo none >"$sdir/rc"; }
	rc=$(cat "$sdir/rc")
	sed "s|$HOME|~|g" "$sdir/out" >"$sdir/out.s"
	if [ -f "$ep" ] && [ "$rc" != 0 ] && [ "$rc" != none ] && [ "$(wc -l <"$sdir/out")" -eq 1 ]; then
		pass "D06-AC-4 strict $label: refuses with exactly one line"
	else fail "D06-AC-4 strict $label: refuses with exactly one line (rc $rc, got: $(tr '\n' '|' <"$sdir/out.s"))"; fi
	if grep -Eq -- "$re" "$sdir/out.s"; then
		pass "D06-AC-4 strict $label: the line names the reason as a whole token"
	else fail "D06-AC-4 strict $label: the line names the reason as a whole token (got: $(tr '\n' '|' <"$sdir/out.s"))"; fi
	if [ -n "$wre" ] && grep -Eq -- "$wre" "$sdir/out.s"; then
		fail "D06-AC-4 strict $label: the line does not name a wrong reason (got: $(tr '\n' '|' <"$sdir/out.s"))"
	else pass "D06-AC-4 strict $label: the line does not name a wrong reason"; fi
}
scn r1 $FULL; FAKE_UID=0 refuse2 "root" '(^|[^A-Za-z])root([^A-Za-z]|$)' '(^|[ /])(repos|token|oauth-token)( |$|:)'
scn r2 -; refuse2 "missing config folder" "config folder|~/\\.config/noodlebot( |\$|:)" '(^|[ /])(repos|token|oauth-token)( |$|:)|root'
grep -Eqi -- "$gone" "$sdir/out.s" && pass "D06-AC-4 strict missing config folder: says it is missing" || fail "D06-AC-4 strict missing config folder: says it is missing"
scn r3 token oauth-token; refuse2 "missing repos" '(^|[ /])repos( |$|:)' '(^|[ /])(oauth-)?token( |$|:)|root'
grep -Eqi -- "$gone" "$sdir/out.s" && pass "D06-AC-4 strict missing repos: says it is missing" || fail "D06-AC-4 strict missing repos: says it is missing"
scn r4 repos oauth-token; refuse2 "missing token script" '(^|[ /])token( |$|:)' 'oauth|(^|[ /])repos( |$|:)|root'
grep -Eqi -- "$gone" "$sdir/out.s" && pass "D06-AC-4 strict missing token script: says it is missing" || fail "D06-AC-4 strict missing token script: says it is missing"
scn r5 repos token; refuse2 "missing harness credential" '(^|[ /])oauth-token( |$|:)' '(^|[ /])repos( |$|:)|(^|[ /])token( |$|:)|root'
grep -Eqi -- "$gone" "$sdir/out.s" && pass "D06-AC-4 strict missing harness credential: says it is missing" || fail "D06-AC-4 strict missing harness credential: says it is missing"

# --- D06-AC-5: SIGTERM runs loops.sh stop once and exits 0
scn term $FULL gitconfig
run_bg; wait_until 15 started
[ -e "$sdir/rc" ] && fail "D06-AC-5 the entrypoint stays in the foreground while tmux lives" ||
	pass "D06-AC-5 the entrypoint stays in the foreground while tmux lives"
stop_bg
[ "$rc" = 0 ] && pass "D06-AC-5 SIGTERM: exits 0" || fail "D06-AC-5 SIGTERM: exits 0 (got $rc)"
[ "$(count stop)" = 1 ] && pass "D06-AC-5 SIGTERM: loops.sh stop ran exactly once" ||
	fail "D06-AC-5 SIGTERM: loops.sh stop ran exactly once (got $(count stop))"

# --- D06-AC-3: an existing ~/gitrepos/noodlebot is left as it is, even without a .git
scn present $FULL
co=$(checkout_dir); mkdir -p "$co"; printf 'owner data\n' >"$co/keep.txt"
run_bg; wait_until 15 started; stop_bg
[ "$(cat "$co/keep.txt" 2>/dev/null)" = "owner data" ] &&
	pass "D06-AC-3 existing folder: keep.txt still holds its content" ||
	fail "D06-AC-3 existing folder: keep.txt still holds its content"
[ ! -e "$co/.git" ] && pass "D06-AC-3 existing folder: no .git, the image copy was not cloned in its place" ||
	fail "D06-AC-3 existing folder: no .git, the image copy was not cloned in its place"
grep -q "start $co/scheduler" "$LOOPS_LOG" 2>/dev/null &&
	fail "D06-AC-3 existing folder: no loops.sh start from a fresh clone" ||
	pass "D06-AC-3 existing folder: no loops.sh start from a fresh clone"

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
