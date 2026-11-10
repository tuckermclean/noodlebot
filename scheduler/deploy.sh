#!/bin/sh
# deploy.sh <live checkout>        deploy origin/main into the live checkout if it passes make test
# deploy.sh --rollback <live>      return the live checkout to the recorded previous commit
#
# Fetches origin main (fatal on failure) and then origin's tags, forced (non-fatal: a failure only
# notes "could not fetch tags" on stderr and versions may be stale). Every status line names the
# version of its commit, <v> = git describe --tags --always ("unknown" if that fails).
# When origin/main is a new commit that has not been rejected, runs `make test`
# in a scratch worktree of that commit; on success it fast-forwards the live checkout and prints
# "deployed <old>..<new> (version <v>)"; on failure it prints "not deployed: <sha> (version <v>) fails make test" once and records
# the sha so it is not tried again. A sha whose make test passed but that cannot be fast-forwarded is
# remembered as passed (deploy/passed, "<sha> <failed fast-forwards>") with one line "not deployed:
# <sha> (version <v>) cannot fast-forward <live> (will retry the fast-forward)"; later runs for that sha skip make
# test and retry only the fast-forward (stderr only), and after $max_tries failed fast-forwards in all
# it is recorded as rejected (stderr only; the status line was already given). A newer origin/main
# supersedes it. A make test that times out or is killed by a signal is retried on later runs (stderr
# only), and after $max_tries such attempts for the same sha it is recorded with one line "not
# deployed: <sha> (version <v>) make test timed out or was killed <n> times". Nothing to do prints
# nothing; every stdout line is one status event.
# --rollback resets to deploy/previous and, once the reset succeeded, records the commit it left as
# rejected, so the rollback sticks, and prints "rolled back <cur>..<prev> (version <v>)".
# A normal run first consumes, under the lock, the one-shot markers the API writes (both removed first, in every case, even
# when the rollback fails, which prints one line "rollback failed" and exits 2 without deploying): deploy/rollback-request rolls back as --rollback does, its one status line saying
# "(rollback requested)", or one line "nothing to roll back" without a rollback point or when already at it; deploy/retry names a
# commit that is removed from rejected, with its counts in tries and passed, and prints one line "retry requested: <sha> ...",
# or "nothing to retry" if it is not rejected; the run then goes on, so a retried origin/main head is tested again.
# State: $NOODLEBOT_DATA/deploy/{previous,rejected,tries,passed,retry,rollback-request} (default ~/.local/share/noodlebot; relative made absolute against $PWD); lock $NOODLEBOT_DATA/deploy/lock (waited for up to 5 minutes, so a
# concurrent run finds nothing left to do; git commands that may leave a background process run with it closed).
# Nothing is written inside the live checkout. Exit:
# 0 nothing to do, deployed, or rolled back;
# 1 not deployed and recorded as rejected (fails make test, $max_tries failed fast-forwards, or timed
#   out / killed $max_tries times);
# 2 not rejected, retried next run: usage, not a git checkout, fetch or git failure, a live checkout
#   that cannot fast-forward or has uncommitted changes, make test timed out or killed (fewer than
#   $max_tries times), make could not run (status 125-127: timeout or make missing), a fast-forward
#   that failed after make test passed (fewer than $max_tries times; the pass is remembered), a failed
#   rollback (nothing recorded), or a TERM/INT (message on stderr).
# The body is in functions called last, so the file is fully read before the checkout changes under it.

die() { echo "deploy.sh: $*" >&2; exit 2; }

max_tries=3

# version <sha>: the version of a commit, git describe --tags --always; "unknown" when that fails.
version() {
	v=$(git -C "$live" describe --tags --always "$1" 2>/dev/null 9>&-) && [ -n "$v" ] && echo "$v" || echo unknown
}

rejected() { grep -Fqx "$1" "$sd/rejected" 2>/dev/null; }

# reject <sha> <reason>: record the sha so it is not tried again, and print the one status line.
reject() {
	echo "$1" >>"$sd/rejected"
	rm -f "$sd/tries" "$sd/passed"
	echo "not deployed: $1 (version $(version "$1")) $2"
}

cleanup() {
	[ -n "${scratch:-}" ] || return 0
	git -C "$live" worktree remove --force "$scratch/wt" >/dev/null 2>&1 9>&-
	rm -rf "$scratch"
	git -C "$live" worktree prune >/dev/null 2>&1 9>&-
	scratch=
}

do_deploy() {
	timeout 60 git -C "$live" fetch -q origin main >/dev/null 2>&1 9>&- || die "git fetch failed in $live"
	# Tags only name versions: a failed tag fetch (moved or conflicting tag) never stops a deploy; +refs/tags force moved ones.
	timeout 60 git -C "$live" fetch -q origin '+refs/tags/*:refs/tags/*' >/dev/null 2>&1 9>&- ||
		echo "deploy.sh: could not fetch tags in $live; versions may be stale" >&2
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
	# A sha whose make test already passed ("<sha> <failed fast-forwards>" in $sd/passed) only retries the fast-forward.
	pn=
	if [ -f "$sd/passed" ] && read -r psha pn <"$sd/passed" && [ "$psha" = "$new" ]; then
		case $pn in ''|*[!0-9]*) pn=0 ;; esac
	else
		pn=
	fi
	[ -n "$pn" ] || { run_test || return $?; }
	fast_forward
}

# run_test: make test for $new in a scratch worktree; 0 when it passed (remembered in $sd/passed),
# otherwise the status do_deploy returns.
run_test() {
	trap cleanup EXIT
	trap '[ -n "${mpid:-}" ] && kill "$mpid" 2>/dev/null; cleanup; exit 2' INT TERM
	scratch=$(mktemp -d) || die "mktemp failed"
	if ! git -C "$live" worktree add -q --detach "$scratch/wt" "$new" >/dev/null 2>&1 9>&-; then
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
	rm -f "$sd/tries"
	pn=0
	echo "$new $pn" >"$sd/passed"
}

# fast_forward: move the live checkout to $new, whose make test passed; $pn fast-forwards failed before.
fast_forward() {
	if ! git -C "$live" merge -q --ff-only "$new" >/dev/null 2>&1 9>&-; then
		pn=$((pn + 1))
		[ "$pn" = 1 ] && echo "not deployed: $new (version $(version "$new")) cannot fast-forward $live (will retry the fast-forward)"
		if [ "$pn" -ge "$max_tries" ]; then
			echo "deploy.sh: cannot fast-forward $live to $new ($pn times); recorded, not tried again" >&2
			echo "$new" >>"$sd/rejected"
			rm -f "$sd/passed"
			return 1
		fi
		echo "$new $pn" >"$sd/passed"
		echo "deploy.sh: cannot fast-forward $live to $new (attempt $pn of $max_tries); will retry the fast-forward" >&2
		return 2
	fi
	rm -f "$sd/tries" "$sd/passed"
	echo "$old" >"$sd/previous"
	echo "deployed $old..$new (version $(version "$new"))"
}

do_rollback() {
	prev=$(cat "$sd/previous" 2>/dev/null) || die "no recorded previous commit"
	prev=$(git -C "$live" rev-parse --verify -q "$prev^{commit}") || die "recorded previous commit is not in $live"
	cur=$(git -C "$live" rev-parse --verify -q HEAD) || die "no HEAD in $live"
	[ "$cur" = "$prev" ] && return 0
	git -C "$live" reset -q --hard "$prev" >/dev/null 2>&1 9>&- || die "cannot reset $live to $prev"
	echo "$cur" >>"$sd/rejected"
	echo "rolled back $cur..$prev (version $(version "$prev"))${1:+ ($1)}"
}

# consume_requests: the markers written by the API (see the header); both are read and removed first, so they are gone
# whatever happens. Returns 2 (nothing is deployed) if a requested rollback failed, else 0.
consume_requests() {
	want_rb=; had_retry=; rsha=; rc_rb=0
	[ -e "$sd/rollback-request" ] && want_rb=1
	if [ -e "$sd/retry" ]; then had_retry=1; rsha=$(head -n 1 "$sd/retry" 2>/dev/null | tr -d '[:space:]'); fi
	rm -f "$sd/rollback-request" "$sd/retry"
	if [ -n "$want_rb" ]; then
		if [ ! -f "$sd/previous" ]; then
			echo "nothing to roll back: rollback requested but there is no rollback point"
		else
			rprev=$(cat "$sd/previous" 2>/dev/null)
			rprev=$(git -C "$live" rev-parse --verify -q "$rprev^{commit}" 2>/dev/null)
			rcur=$(git -C "$live" rev-parse --verify -q HEAD 2>/dev/null)
			if [ -n "$rprev" ] && [ "$rcur" = "$rprev" ]; then
				echo "nothing to roll back: rollback requested but $live is already at the rollback point $rprev (version $(version "$rprev"))"
			elif ! ( do_rollback "rollback requested" ); then
				rc_rb=2
				echo "rollback failed: rollback requested but $live could not be rolled back"
			fi
		fi
	fi
	if [ -n "$rsha" ] && rejected "$rsha"; then
		if grep -Fvx "$rsha" "$sd/rejected" >"$sd/rejected.tmp" 2>/dev/null; then rc=0; else rc=$?; fi
		if [ "$rc" -le 1 ]; then mv -f "$sd/rejected.tmp" "$sd/rejected"; else rm -f "$sd/rejected.tmp"; fi
		for f in tries passed; do
			[ -f "$sd/$f" ] || continue
			if read -r fsha _ <"$sd/$f" && [ "$fsha" = "$rsha" ]; then rm -f "$sd/$f"; fi
		done
		echo "retry requested: $rsha (version $(version "$rsha")) will be tested again"
	elif [ -n "$had_retry" ]; then
		echo "nothing to retry: retry requested for ${rsha:-an empty commit}, which is not rejected"
	fi
	return "$rc_rb"
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
	if [ "$mode" = rollback ]; then do_rollback; else consume_requests || exit $?; do_deploy; fi
}

main "$@"; exit $?
