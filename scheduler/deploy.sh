#!/bin/sh
# deploy.sh <live checkout>        deploy origin/main into the live checkout if it passes make test, or CI and the smoke check when deploy-ci is set
# deploy.sh --rollback <live>      return the live checkout to the recorded previous commit
# deploy.sh --runtime-changed <live checkout> <from> [<to>]   exit 0 if the range changes a runtime path, 1 if not, 2 if unknown
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
# A failed make test (not a timeout, a signal or status 125-127) is read for the "FAILED <file>" lines scheduler/runtests.sh
# prints; if it named files, they are rerun once, alone (make test TESTS="<files>" TEST_JOBS=1, same scratch worktree and
# clean environment, same timeout). A rerun that passes deploys as a pass does, with "deployed <old>..<new> (version <v>)
# after a flaky make test: <n> file(s) failed and passed alone" and the stderr line "flaky: <sha> <files> failed in make
# test and passed alone; log in <path>"; a rerun that fails, or no file named, rejects as above, with the stderr line "make
# test failed for <sha> in: <files> (or "no file named"); log in <path>". The output of both runs is kept, under a header
# (sha, version, UTC time, rejected or flaky), in deploy/test-failed.log (a temporary file renamed over the last one).
# --rollback resets to deploy/previous and, once the reset succeeded, records the commit it left as
# rejected, so the rollback sticks, and prints "rolled back <cur>..<prev> (version <v>)".
# A normal run first consumes, under the lock, the one-shot markers the API writes (both removed
# first, in every case, even when the rollback fails, which prints one line "rollback failed" and
# exits 2 without deploying): deploy/rollback-request rolls back as --rollback does, its one status
# line saying "(rollback requested)", or one line "nothing to roll back" without a rollback point or
# when already at it; deploy/retry names a commit that is removed from rejected, with its counts in
# tries, passed and plain-tries, and prints one line "retry requested: <sha> ...", or "nothing to retry" if it is
# not rejected (if rejected cannot be updated the line says the retry could not be applied); the run
# then goes on, so a retried origin/main head is tested again.
# CI gate (D07): when the first line of $HOME/.config/noodlebot/deploy-ci, "<owner/name> <workflow file> <branch>", is
# present, a runtime range never runs make test; the push runs of that workflow on that branch for the new origin/main sha are
# read (gh api repos/<owner/name>/actions/workflows/<workflow>/runs, head_sha, event=push, branch; GH_TOKEN fresh from
# $HOME/.config/noodlebot/token <owner/name> on each run, never printed; 30 s timeouts) and the newest run decides. Missing or
# empty file: the gate is off and make test runs as above. A malformed line deploys nothing, runs no make test, prints one
# stderr line "deploy-ci: <reason>" and exits 2. A non-runtime range is fast-forwarded without CI as above.
#  - completed, success: the smoke check (below), then the deploy, with "deployed <old>..<new> (version <v>) after CI:
#    <workflow> run <id> passed" (the pass is remembered in deploy/passed as after a make test pass);
#  - completed, any other conclusion: rejected with one line "not deployed: <sha> (version <v>) fails CI: <workflow> run <id>
#    <conclusion>", not tried again (deploy/retry puts it back to be read again);
#  - queued, in progress or no run: nothing deployed or rejected, exit 2; the first wait for a sha prints the line "waiting for
#    CI: <sha> (version <v>) <workflow>" and records the sha in deploy/waiting, every wait writes the stderr line "waiting for CI:
#    <sha> <workflow> <queued|in_progress|no run>";
#  - gh or the token script fails, times out or answers something unreadable: a wait whose stderr line names the failure
#    ("deploy.sh: gh failed ...", "deploy.sh: token script failed ..."), no status line, nothing recorded.
# Smoke check (D07): the CI-passed sha is checked out in a scratch worktree and, in the clean environment of make test under a
# 60 s timeout, each tracked *.sh under scheduler/ and plugin/ is read with bash -n if its first line is a #! line naming bash,
# sh -n if it is a #! line naming sh, and bash -n if it has no #! line, and each tracked *.py there is compiled with python3 -I, writing no bytecode. A file that fails rejects the sha with
# "not deployed: <sha> (version <v>) fails the smoke check: <file>" and the checker's message on stderr; a smoke check that
# times out or is killed is retried and counted as a timed-out make test is ("smoke check timed out or was killed <n> times").
# A smoke check that fails without naming a file (the checker could not run) rejects nothing and is retried, with the stderr
# line "deploy.sh: smoke check for <sha> could not run (status <n>); will retry".
# State: $NOODLEBOT_DATA/deploy/{previous,rejected,tries,passed,plain-tries,waiting,test-failed.log,retry,rollback-request} (default
# ~/.local/share/noodlebot; relative made absolute against $PWD); lock $NOODLEBOT_DATA/deploy/lock
# (waited for up to 5 minutes, so a concurrent run finds nothing left to do; git commands that may
# leave a background process run with it closed).
# Nothing is written inside the live checkout. Exit:
# 0 nothing to do, deployed, or rolled back;
# 1 not deployed and recorded as rejected (fails make test, $max_tries failed fast-forwards, or timed
#   out / killed $max_tries times, fails CI, fails the smoke check, or the smoke check timed out / was
#   killed $max_tries times);
# 2 not rejected, retried next run: usage, not a git checkout, fetch or git failure, a live checkout
#   that cannot fast-forward or has uncommitted changes, make test timed out or killed (fewer than
#   $max_tries times), make could not run (status 125-127: timeout or make missing), a fast-forward
#   that failed after make test passed (fewer than $max_tries times; the pass is remembered), a failed
#   rollback (nothing recorded), waiting for CI (queued, in progress or no run), a gh or token script
#   failure, a malformed deploy-ci, a smoke check that timed out or was killed (fewer than $max_tries
#   times) or that could not run (no file named; nothing recorded), or a TERM/INT (message on stderr).
# Runtime paths: a range that changes only the non-runtime paths (see is_runtime_path) is fast-forwarded without
# make test (a failed plain fast-forward is counted in deploy/plain-tries and the sha rejected after $max_tries, as
# a failed fast-forward after a pass is), with the line "deployed <old>..<new> (version <v>) without make test: no runtime change", and deploy/previous
# stays as it is. Every other path is runtime, because a loop or session reads it from the live checkout or make test runs
# it: scheduler/ (the loop, its helpers, the session templates and the test files make test runs), plugin/ (every session
# loads the live checkout's plugin, --plugin-dir), site/ (the status site's front end and its tests in make test), the
# Makefile (the deploy's own make test), .claude/ (the role agents of a session started in the live checkout) and any path
# not named, so a new top-level path is runtime until it is listed. A range with any runtime path anywhere gets the full deploy.
# deploy.sh --runtime-changed <live> <from> [<to>] (to: HEAD) uses the same list and takes no lock and writes no state: exit
# 0 a runtime path changed (git diff --name-only <from> <to>), 1 none, 2 git failed.
# The body is in functions called last, so the file is fully read before the checkout changes under it.

die() { echo "deploy.sh: $*" >&2; exit 2; }

max_tries=3

# version <sha>: the version of a commit, git describe --tags --always; "unknown" when that fails.
version() {
	v=$(git -C "$live" describe --tags --always "$1" 2>/dev/null 9>&-) && [ -n "$v" ] && echo "$v" || echo unknown
}

# is_runtime_path <path>: 0 unless the path is on the non-runtime list.
is_runtime_path() {
	case $1 in
	# read by people, and by sessions from their own worktrees, never by a loop from the live checkout
	SPEC.md|AGENTS.md|CLAUDE.md|README.md) return 1 ;;
	# the loop reads docs/graph.yaml from origin/main of its clone (repos/<name>), not from the live checkout
	docs/*) return 1 ;;
	# the loop, report.py and site.py read node specs from origin/main of the clone; sessions read them in their worktrees
	nodes/*) return 1 ;;
	# the workflows run on GitHub's runners, never on the scheduler's machine
	.github/*) return 1 ;;
	esac
	return 0
}

# runtime_changed <live> <from> <to>: 0 a runtime path changed, 1 none, 2 git failed.
runtime_changed() {
	rc_files=$(git -C "$1" diff --name-only --no-renames "$2" "$3" -- 2>/dev/null 9>&-) || return 2
	while IFS= read -r rc_p; do
		[ -n "$rc_p" ] || continue
		is_runtime_path "$rc_p" && return 0
	done <<LISTEND
$rc_files
LISTEND
	return 1
}

rejected() { grep -Fqx -e "$1" "$sd/rejected" 2>/dev/null; }

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
	# A range that changes no runtime path is fast-forwarded without make test (a git failure falls through to the full deploy).
	read_ci || return 2
	runtime_changed "$live" "$old" "$new"
	[ $? = 1 ] && { fast_forward_plain; return $?; }
	# A sha whose make test already passed ("<sha> <failed fast-forwards>" in $sd/passed) only retries the fast-forward.
	pn=
	if [ -f "$sd/passed" ] && read -r psha pn <"$sd/passed" && [ "$psha" = "$new" ]; then
		case $pn in ''|*[!0-9]*) pn=0 ;; esac
	else
		pn=
	fi
	if [ -z "$pn" ]; then
		if [ -n "$ci_on" ]; then ci_gate || return $?; else run_test || return $?; fi
	fi
	fast_forward
}

# read_ci: the deploy-ci configuration into ci_on, ci_repo, ci_wf, ci_branch; ci_on stays empty when the file is missing or
# empty (gate off). Returns 2 (with one "deploy-ci:" stderr line) when the first line is malformed.
read_ci() {
	ci_on=; ci_repo=; ci_wf=; ci_branch=; ci_line=
	[ -s "$HOME/.config/noodlebot/deploy-ci" ] || return 0
	read -r ci_line <"$HOME/.config/noodlebot/deploy-ci" 2>/dev/null || [ -n "$ci_line" ] || {
		echo "deploy-ci: cannot read $HOME/.config/noodlebot/deploy-ci" >&2
		return 2
	}
	set -f; set -- $ci_line; set +f
	[ $# -gt 0 ] || return 0
	if [ $# -ne 3 ]; then
		echo "deploy-ci: expected \"<owner/name> <workflow file> <branch>\", found $# field(s)" >&2
		return 2
	fi
	case $1 in
	*/*) ;;
	*) echo "deploy-ci: the repository \"$1\" is not <owner/name>" >&2; return 2 ;;
	esac
	ci_on=1; ci_repo=$1; ci_wf=$2; ci_branch=$3
}

# ci_waiting <state>: the sha waits for CI; the status line only the first time, the stderr line every time. Returns 2.
ci_waiting() {
	echo "waiting for CI: $new $ci_wf $1" >&2
	w=
	[ -f "$sd/waiting" ] && read -r w <"$sd/waiting"
	if [ "$w" != "$new" ]; then
		echo "$new" >"$sd/waiting"
		echo "waiting for CI: $new (version $(version "$new")) $ci_wf"
	fi
	return 2
}

# ci_read: the newest push run for $new into ci_status, ci_concl, ci_id ("none" status when no run); 0, or 1 with the failure
# in ci_err (a wait without a status line).
ci_read() {
	ci_status=; ci_concl=; ci_id=; ci_err=
	ci_tok=$(timeout 30 "$HOME/.config/noodlebot/token" "$ci_repo" 2>/dev/null 9>&-) || ci_err="token script failed or timed out for $ci_repo"
	[ -n "$ci_err" ] || [ -n "$ci_tok" ] || ci_err="token script printed no token for $ci_repo"
	[ -z "$ci_err" ] || return 1
	ci_dir=$(mktemp -d) || { ci_err="mktemp failed"; return 1; }
	GH_TOKEN=$ci_tok timeout 30 gh api -X GET "repos/$ci_repo/actions/workflows/$ci_wf/runs" \
		-f "head_sha=$new" -f event=push -f "branch=$ci_branch" >"$ci_dir/out" 2>"$ci_dir/err" 9>&-
	ci_rc=$?
	ci_tok=
	if [ "$ci_rc" != 0 ]; then
		ci_err="gh failed or timed out (status $ci_rc): $(head -n 1 "$ci_dir/err" 2>/dev/null | cut -c1-200)"
		rm -rf "$ci_dir"
		return 1
	fi
	ci_res=$(python3 -I -c '
import json, sys
sha = sys.argv[1]
runs = [r for r in json.load(sys.stdin)["workflow_runs"] if isinstance(r, dict) and r.get("head_sha", sha) == sha]
if not runs:
    print("none - -")
else:
    r = max(runs, key=lambda r: (str(r.get("created_at") or ""), int(r["id"])))
    f = [str(r["status"]), str(r.get("conclusion") or "-"), str(int(r["id"]))]
    if any(not x or any(c.isspace() for c in x) for x in f):
        raise ValueError("bad run")
    print(" ".join(f))
' "$new" <"$ci_dir/out" 2>/dev/null 9>&-) || ci_err="gh gave an answer that does not parse"
	rm -rf "$ci_dir"
	[ -z "$ci_err" ] || return 1
	set -- $ci_res
	ci_status=$1; ci_concl=$2; ci_id=$3
}

# ci_gate: the CI gate for $new; 0 when CI passed it and the smoke check passed (remembered in $sd/passed), otherwise the
# status do_deploy returns.
ci_gate() {
	if ! ci_read; then
		echo "deploy.sh: $ci_err; waiting for CI of $new" >&2
		return 2
	fi
	case $ci_status in
	none) ci_waiting "no run"; return $? ;;
	completed)
		case $ci_concl in
		success) ;;
		-) echo "deploy.sh: gh gave a completed run without a conclusion; waiting for CI of $new" >&2; return 2 ;;
		*)
			rm -f "$sd/waiting"
			reject "$new" "fails CI: $ci_wf run $ci_id $ci_concl"
			return 1 ;;
		esac ;;
	*) ci_waiting "$ci_status"; return $? ;;
	esac
	smoke_check || return $?
	rm -f "$sd/tries" "$sd/waiting"
	pn=0
	echo "$new $pn" >"$sd/passed"
	flaky_note=" after CI: $ci_wf run $ci_id passed"
}

# smoke_check: the local check of $new (see the header) in a scratch worktree; 0 when it passed, otherwise the status
# do_deploy returns.
smoke_check() {
	trap cleanup EXIT
	trap '[ -n "${mpid:-}" ] && kill "$mpid" 2>/dev/null; cleanup; exit 2' INT TERM
	scratch=$(mktemp -d) || die "mktemp failed"
	if ! git -C "$live" worktree add -q --detach "$scratch/wt" "$new" >/dev/null 2>&1 9>&-; then
		rm -rf "$scratch"
		die "cannot create a scratch worktree for $new"
	fi
	(
		for v in $(env | sed -n 's/^\(\(SCHED\|USAGE\)_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
		unset NOODLEBOT_DATA
		PYTHONDONTWRITEBYTECODE=1; export PYTHONDONTWRITEBYTECODE
		exec timeout 60 sh -c '
			cd "$1" || exit 2
			git -c core.quotePath=false ls-files -- scheduler plugin | while IFS= read -r f; do
				case $f in
				*.sh)
					read -r first <"$f"
					case $first in
					"#!"*bash*) sh_n=bash ;;
					"#!"*sh*) sh_n=sh ;;
					*) sh_n=bash ;;
					esac
					"$sh_n" -n "$f" || { echo "$f" >&3; exit 1; } ;;
				*.py)
					python3 -I -c "import sys; compile(open(sys.argv[1], \"rb\").read(), sys.argv[1], \"exec\")" "$f" ||
						{ echo "$f" >&3; exit 1; } ;;
				esac
			done
		' smoke "$scratch/wt" 3>"$scratch/smoke.file" >/dev/null 2>"$scratch/smoke.err" 9>&-
	) &
	mpid=$!
	wait "$mpid"; sm_rc=$?
	mpid=
	if [ "$sm_rc" = 124 ] || [ "$sm_rc" -gt 128 ]; then
		cleanup
		n=0
		[ -f "$sd/tries" ] && read -r tsha tn <"$sd/tries" && [ "$tsha" = "$new" ] && n=$tn
		case $n in ''|*[!0-9]*) n=0 ;; esac
		n=$((n + 1))
		if [ "$n" -ge "$max_tries" ]; then
			rm -f "$sd/waiting"
			reject "$new" "smoke check timed out or was killed $n times"
			return 1
		fi
		echo "$new $n" >"$sd/tries"
		echo "deploy.sh: smoke check for $new timed out or was killed (status $sm_rc, attempt $n of $max_tries); will retry" >&2
		return 2
	fi
	if [ "$sm_rc" != 0 ]; then
		sm_file=$(head -n 1 "$scratch/smoke.file" 2>/dev/null)
		cat "$scratch/smoke.err" >&2 2>/dev/null
		cleanup
		if [ -z "$sm_file" ]; then
			echo "deploy.sh: smoke check for $new could not run (status $sm_rc); will retry" >&2
			return 2
		fi
		rm -f "$sd/waiting"
		reject "$new" "fails the smoke check: $sm_file"
		return 1
	fi
	cleanup
}

# run_make <log> [<files>]: make test in the scratch worktree, in a clean environment, output to <log>; with files it is the
# rerun (TESTS="<files>", TEST_JOBS=1). Returns make's status; mpid is the child, so a signal can stop it.
run_make() {
	(
		for v in $(env | sed -n 's/^\(\(SCHED\|USAGE\)_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
		unset NOODLEBOT_DATA
		if [ -n "${2:-}" ]; then
			TEST_JOBS=1; export TEST_JOBS
			exec timeout 600 make -C "$scratch/wt" test TESTS="$2" TEST_JOBS=1 >"$1" 2>&1 9>&-
		fi
		exec timeout 600 make -C "$scratch/wt" test >"$1" 2>&1 9>&-
	) &
	mpid=$!
	wait "$mpid"; rm_rc=$?
	mpid=
	return "$rm_rc"
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
	# make test runs in a clean environment: the loop's SCHED_*, USAGE_* and NOODLEBOT_DATA are not passed on.
	run_make "$scratch/test.log"
	rc=$?
	if [ "$rc" = 124 ] || [ "$rc" -gt 128 ]; then
		cleanup
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
		cleanup
		echo "deploy.sh: make test for $new could not run (status $rc: timeout or make missing); will retry" >&2
		return 2
	fi
	flaky_note=
	if [ "$rc" != 0 ]; then
		# Rerun the files the runner named once, alone; the pass of all of them makes the failure flaky.
		files=$(sed -n 's/^FAILED //p' "$scratch/test.log" | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//')
		rerun_rc=1
		if [ -n "$files" ]; then
			run_make "$scratch/rerun.log" "$files"
			rerun_rc=$?
		fi
		tf=$sd/test-failed.log
		if [ "$rerun_rc" = 0 ]; then outcome=flaky; else outcome=rejected; fi
		{
			echo "make test failed for $new (version $(version "$new")) at $(date -u +%Y-%m-%dT%H:%M:%SZ): $outcome"
			cat "$scratch/test.log"
			[ -z "$files" ] || cat "$scratch/rerun.log"
		} >"$tf.tmp" 2>/dev/null && mv -f "$tf.tmp" "$tf" 2>/dev/null || rm -f "$tf.tmp"
		cleanup
		if [ "$rerun_rc" != 0 ]; then
			echo "make test failed for $new in: ${files:-no file named}; log in $tf" >&2
			reject "$new" "fails make test"
			return 1
		fi
		set -- $files
		flaky_note=" after a flaky make test: $# file(s) failed and passed alone"
		echo "flaky: $new $files failed in make test and passed alone; log in $tf" >&2
	else
		cleanup
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
	echo "deployed $old..$new (version $(version "$new"))${flaky_note:-}"
}

# fast_forward_plain: move the live checkout to $new without make test; deploy/previous is left as it is.
fast_forward_plain() {
	if ! git -C "$live" merge -q --ff-only "$new" >/dev/null 2>&1 9>&-; then
		# Failed attempts per sha ("<sha> <n>" in $sd/plain-tries), rejected after $max_tries as fast_forward does.
		pn=0
		[ -f "$sd/plain-tries" ] && read -r psha pn <"$sd/plain-tries" && [ "$psha" = "$new" ] || pn=0
		case $pn in ''|*[!0-9]*) pn=0 ;; esac
		pn=$((pn + 1))
		[ "$pn" = 1 ] && echo "not deployed: $new (version $(version "$new")) cannot fast-forward $live (will retry the fast-forward)"
		if [ "$pn" -ge "$max_tries" ]; then
			echo "deploy.sh: cannot fast-forward $live to $new ($pn times); recorded, not tried again" >&2
			echo "$new" >>"$sd/rejected"
			rm -f "$sd/plain-tries"
			return 1
		fi
		echo "$new $pn" >"$sd/plain-tries"
		echo "deploy.sh: cannot fast-forward $live to $new (attempt $pn of $max_tries); will retry the fast-forward" >&2
		return 2
	fi
	rm -f "$sd/tries" "$sd/passed" "$sd/plain-tries"
	echo "deployed $old..$new (version $(version "$new")) without make test: no runtime change"
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
		if grep -Fvx -e "$rsha" "$sd/rejected" >"$sd/rejected.tmp" 2>/dev/null; then rc=0; else rc=$?; fi
		if [ "$rc" -le 1 ] && mv -f "$sd/rejected.tmp" "$sd/rejected" 2>/dev/null; then
			for f in tries passed plain-tries; do
				[ -f "$sd/$f" ] || continue
				if read -r fsha _ <"$sd/$f" && [ "$fsha" = "$rsha" ]; then rm -f "$sd/$f"; fi
			done
			echo "retry requested: $rsha (version $(version "$rsha")) will be tested again"
		else
			rm -f "$sd/rejected.tmp"
			echo "retry requested: $rsha (version $(version "$rsha")) could not be applied: $sd/rejected was not updated"
		fi
	elif [ -n "$had_retry" ]; then
		echo "nothing to retry: retry requested for ${rsha:-an empty commit}, which is not rejected"
	fi
	return "$rc_rb"
}

main() {
	if [ "${1:-}" = --runtime-changed ]; then
		[ $# -eq 3 ] || [ $# -eq 4 ] || die "usage: deploy.sh --runtime-changed <live checkout> <from> [<to>]"
		runtime_changed "$2" "$3" "${4:-HEAD}"
		return $?
	fi
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
