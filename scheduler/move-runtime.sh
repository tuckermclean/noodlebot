#!/bin/bash
# One-time move of an installation's runtime folders (repos/, worktrees/, state/) from a checkout
# to the runtime root $NOODLEBOT_DATA (default ~/.local/share/noodlebot), the layout loop.sh uses.
#   scheduler/move-runtime.sh <checkout>      (e.g. ~/gitrepos/noodlebot)
# Stop the loops first (touch ~/STOP) and wait until no session runs. It refuses, moving nothing,
# while a loop holds a state/*/loop.lock, a recorded session.pid is alive, or the root already has
# a folder it would move onto; exit 2 if the root lies inside a Git working tree. On every run it
# runs `git worktree repair` in every clone under the root so the clones and their worktrees find
# each other; a rerun therefore finishes an interrupted move.
# The move is meant within one filesystem. If the root is on another one, `mv` copies and deletes,
# and container-made files (podman's subordinate ids) may stop it partway; then remove them with
# `podman unshare` and rerun.
# Every loop, status.sh and this script must see the same NOODLEBOT_DATA.
set -u -o pipefail
shopt -s dotglob nullglob
[ $# -eq 1 ] && [ -d "$1" ] || { echo "usage: move-runtime.sh <checkout>" >&2; exit 2; }
co=$(cd "$1" && pwd -P) || exit 2
root=${NOODLEBOT_DATA:-$HOME/.local/share/noodlebot}
case $root in /*) ;; *) root=$PWD/$root ;; esac
probe=$root
while [ ! -d "$probe" ] && [ "$probe" != / ] && [ "$probe" != . ]; do probe=$(dirname "$probe"); done
if top=$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null); then
	echo "move-runtime.sh: the runtime root $root is inside the Git working tree $top; set NOODLEBOT_DATA to a folder outside it" >&2
	exit 2
fi

# What is there to move: <dir>/<name> for each of the three folders.
todo=
for d in repos worktrees state; do [ -d "$co/$d" ] && todo="$todo $d"; done

# Repair each clone and its worktrees (both directions of the links); safe to repeat, so a rerun
# after an interrupted move fixes what it left broken.
repair() {
	local rc=0 clone n w
	for clone in "$root"/repos/*/; do
		[ -d "$clone/.git" ] || continue
		n=$(basename "$clone")
		set --
		for w in "$root/worktrees/$n"/*/; do [ -e "$w/.git" ] && set -- "$@" "${w%/}"; done
		git -C "$clone" worktree repair >/dev/null 2>&1
		git -C "$clone" worktree repair "$@" >/dev/null 2>&1 || { echo "move-runtime.sh: worktree repair failed in $clone" >&2; rc=1; }
	done
	return $rc
}
if [ -z "$todo" ]; then
	repair || exit 1
	echo "move-runtime.sh: nothing to move in $co (no repos/, worktrees/ or state/)"; exit 0
fi

# Refuse while anything is in use.
for l in "$co"/state/*/loop.lock; do
	[ -e "$l" ] || continue
	if ! flock -n "$l" true 2>/dev/null; then
		echo "move-runtime.sh: a loop holds $l; stop the loops (touch ~/STOP) and retry" >&2
		exit 1
	fi
done
for f in "$co"/state/*/node/*/session.pid "$co"/state/*/issue/*/session.pid; do
	[ -e "$f" ] || continue
	p=$(cat "$f" 2>/dev/null)
	if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
		echo "move-runtime.sh: the session in $f (pid $p) is alive; wait until it ends and retry" >&2
		exit 1
	fi
done
for d in $todo; do
	for src in "$co/$d"/*; do
		if [ -e "$root/$d/$(basename "$src")" ]; then
			echo "move-runtime.sh: $root/$d/$(basename "$src") already exists; move nothing onto it" >&2
			exit 1
		fi
	done
done

# Move.
mkdir -p "$root/repos" "$root/worktrees" "$root/state" || exit 2
for d in $todo; do
	for src in "$co/$d"/*; do
		mv "$src" "$root/$d/" || { echo "move-runtime.sh: cannot move $src" >&2; repair; exit 1; }
	done
	rmdir "$co/$d" 2>/dev/null || { echo "move-runtime.sh: $co/$d is not empty, left in place" >&2; repair; exit 1; }
done

repair || exit 1
echo "move-runtime.sh: moved$todo from $co to $root"
