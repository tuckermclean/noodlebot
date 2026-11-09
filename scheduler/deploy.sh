#!/bin/sh
# deploy.sh <live checkout>        deploy origin/main into the live checkout if it passes make test
# deploy.sh --rollback <live>      return the live checkout to the recorded previous commit
#
# Fetches origin, and when origin/main is a new commit that has not been rejected, runs `make test`
# in a scratch worktree of that commit; on success it fast-forwards the live checkout and prints
# "deployed <old>..<new>"; on failure it prints "not deployed: <sha> fails make test" once and records
# the sha so it is not tried again. Nothing to do prints nothing. --rollback resets to
# deploy/previous and records the commit it left as rejected, so the rollback sticks.
# State: $NOODLEBOT_DATA/deploy/{previous,rejected} (default ~/.local/share/noodlebot; relative made absolute against $PWD); lock $NOODLEBOT_DATA/deploy/lock (waited for up to 5 minutes, so a
# concurrent run finds nothing left to do). Nothing is written inside the live checkout. Exit: 0 nothing to do / deployed / rolled back;
# 1 make test failed; 2 usage, not a git checkout, fetch or git failure (message on stderr).
# The body is a function called last, so the file is fully read before the checkout changes under it.

die() { echo "deploy.sh: $*" >&2; exit 2; }

rejected() { grep -qx "$1" "$sd/rejected" 2>/dev/null; }

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
		echo "deploy.sh: make test for $new timed out or was killed (status $rc); will retry" >&2
		return 2
	fi
	if [ "$rc" != 0 ]; then
		echo "$new" >>"$sd/rejected"
		echo "not deployed: $new fails make test"
		return 1
	fi
	if ! git -C "$live" merge -q --ff-only "$new" >/dev/null 2>&1; then
		echo "$new" >>"$sd/rejected"
		die "cannot fast-forward $live to $new (recorded; not tried again)"
	fi
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
