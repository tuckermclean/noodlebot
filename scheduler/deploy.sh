#!/bin/sh
# deploy.sh <live checkout>        deploy origin/main into the live checkout if it passes make test
# deploy.sh --rollback <live>      return the live checkout to the recorded previous commit
#
# Fetches origin, and when origin/main is a new commit that has not been rejected, runs `make test`
# in a scratch worktree of that commit; on success it fast-forwards the live checkout and prints
# "deployed <old>..<new>"; on failure it prints "not deployed: <sha> fails make test" once and records
# the sha so it is not tried again. A sha whose make test passed but that cannot be fast-forwarded is
# recorded too, with one line "not deployed: <sha> cannot fast-forward <live>". A make test that times
# out or is killed by a signal is retried on later runs (stderr only), and after $max_tries such
# attempts for the same sha it is recorded with one line "not deployed: <sha> make test timed out or
# was killed <n> times". Nothing to do prints nothing; every stdout line is one status event.
# --rollback resets to deploy/previous and records the commit it left as rejected, so the rollback sticks.
# State: $NOODLEBOT_DATA/deploy/{previous,rejected,tries} (default ~/.local/share/noodlebot; relative made absolute against $PWD); lock $NOODLEBOT_DATA/deploy/lock (waited for up to 5 minutes, so a
# concurrent run finds nothing left to do). Nothing is written inside the live checkout. Exit:
# 0 nothing to do, deployed, or rolled back;
# 1 not deployed and recorded (fails make test, cannot fast-forward, or timed out / killed $max_tries times);
# 2 nothing recorded, retried next run: usage, not a git checkout, fetch or git failure, a live checkout
#   that cannot fast-forward or has uncommitted changes, make test timed out or killed (fewer than
#   $max_tries times), or make could not run (status 125-127: timeout or make missing) (message on stderr).
# The body is a function called last, so the file is fully read before the checkout changes under it.

die() { echo "deploy.sh: $*" >&2; exit 2; }

max_tries=3

rejected() { grep -qx "$1" "$sd/rejected" 2>/dev/null; }

# reject <sha> <reason>: record the sha so it is not tried again, and print the one status line.
reject() {
	echo "$1" >>"$sd/rejected"
	rm -f "$sd/tries"
	echo "not deployed: $1 $2"
}

cleanup() {
	[ -n "${scratch:-}" ] || return 0
	git -C "$live" worktree remove --force "$scratch/wt" >/dev/null 2>&1
	rm -rf "$scratch"
	git -C "$live" worktree prune >/dev/null 2>&1
	scratch=
}

do_deploy() {
	timeout 60 git -C "$live" fetch -q origin main >/dev/null 2>&1 9>&- || die "git fetch failed in $live"
	new=$(git -C "$live" rev-parse --verify -q origin/main^{commit}) || die "no origin/main in $live"
	old=$(git -C "$live" rev-parse --verify -q HEAD) || die "no HEAD in $live"
	[ "$new" = "$old" ] && return 0
	rejected "$new" && return 0
	git -C "$live" merge-base --is-ancestor "$new" "$old" 2>/dev/null && return 0
	if ! git -C "$live" merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
		echo "deploy.sh: $live cannot fast-forward to $new (HEAD is not an ancestor of origin/main)" >&2
		return 2
	fi
	if [ -n "$(git -C "$live" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
		echo "deploy.sh: $live has uncommitted tracked changes; not deploying $new" >&2
		return 2
	fi
	trap cleanup EXIT
	trap 'kill "${mpid:-0}" 2>/dev/null; cleanup; exit 2' INT TERM
	scratch=$(mktemp -d) || die "mktemp failed"
	if ! git -C "$live" worktree add -q --detach "$scratch/wt" "$new" >/dev/null 2>&1; then
		rm -rf "$scratch"
		die "cannot create a scratch worktree for $new"
	fi
	# make test runs in a clean environment: the loop's SCHED_* and NOODLEBOT_DATA are not passed on.
	(
		for v in $(env | sed -n 's/^\(SCHED_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
		unset NOODLEBOT_DATA
		exec timeout 600 make -C "$scratch/wt" test >"$scratch/test.log" 2>&1 9>&-
	) &
	mpid=$!
	wait "$mpid"; rc=$?
	mpid=
	cleanup
	if [ "$rc" = 124 ] || [ "$rc" -gt 128 ]; then
		# Count attempts per sha ("<sha> <n>" in $sd/tries) so a hanging make test is not rerun forever.
		n=0
		[ -f "$sd/tries" ] && read -r tsha tn <"$sd/tries" && [ "$tsha" = "$new" ] && n=$tn
		case $n in ''|*[!0-9]*) n=0 ;; esac
		n=$((n + 1))
		if [ "$n" -ge "$max_tries" ]; then
			reject "$new" "make test timed out or was killed $n times"
			return 1
		fi
		echo "$new $n" >"$sd/tries"
		echo "deploy.sh: make test for $new timed out or was killed (status $rc, attempt $n of $max_tries); will retry" >&2
		return 2
	fi
	if [ "$rc" -ge 125 ] && [ "$rc" -le 127 ]; then
		echo "deploy.sh: make test for $new could not run (status $rc: timeout or make missing); will retry" >&2
		return 2
	fi
	if [ "$rc" != 0 ]; then
		reject "$new" "fails make test"
		return 1
	fi
	if ! git -C "$live" merge -q --ff-only "$new" >/dev/null 2>&1; then
		echo "deploy.sh: cannot fast-forward $live to $new (recorded; not tried again)" >&2
		reject "$new" "cannot fast-forward $live"
		return 1
	fi
	rm -f "$sd/tries"
	echo "$old" >"$sd/previous"
	echo "deployed $old..$new"
}

do_rollback() {
	prev=$(cat "$sd/previous" 2>/dev/null) || die "no recorded previous commit"
	prev=$(git -C "$live" rev-parse --verify -q "$prev^{commit}") || die "recorded previous commit is not in $live"
	cur=$(git -C "$live" rev-parse --verify -q HEAD) || die "no HEAD in $live"
	[ "$cur" = "$prev" ] && return 0
	echo "$cur" >>"$sd/rejected"
	git -C "$live" reset -q --hard "$prev" >/dev/null 2>&1 || die "cannot reset $live to $prev"
	echo "rolled back $cur..$prev"
}

main() {
	mode=deploy
	if [ "${1:-}" = --rollback ]; then mode=rollback; shift; fi
	[ $# -eq 1 ] || die "usage: deploy.sh [--rollback] <live checkout>"
	live=$(cd "$1" 2>/dev/null && pwd -P) || die "no such directory: $1"
	git -C "$live" rev-parse --git-dir >/dev/null 2>&1 || die "not a git checkout: $live"
	root=${NOODLEBOT_DATA:-$HOME/.local/share/noodlebot}
	case $root in /*) ;; *) root=$PWD/$root ;; esac
	sd=$root/deploy
	mkdir -p "$sd" || die "cannot create $sd"
	exec 9>"$sd/lock" || die "cannot open the lock"
	command -v flock >/dev/null 2>&1 || die "flock not found"
	flock -w 300 9 || die "cannot take the lock"
	if [ "$mode" = rollback ]; then do_rollback; else do_deploy; fi
}

main "$@"; exit $?
