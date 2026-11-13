# Shared by loop-g06*.test.sh (source after loop-prelude.sh): G03's fixture (testdata/lib/loop-g03.sh) plus a fake node-PR
# update (kind nupd, id nupd.<PR>, prompt "/noodlebot:node --update <PR>") and helpers for the node-PR update of a PR
# that also has owner feedback (G06). Scratch paths stay under G03's fixture's $tmp; the G06 folder below holds the files
# these cases write.
. "$src/testdata/lib/loop-g03.sh"
sed -i '/^"\/noodlebot:triage --update "\*)/i "/noodlebot:node --update "*) kind=nupd k=${p##* } ;;' "$tmp/bin6/claude"
clone=$data6/repos/up
G06=$tmp/G06; mkdir -p "$G06"
g06_prs() { sed -i "s/^$1 \\(.*\\) [A-Z]*\$/$1 \\1 $2/" "$GD/prs.tsv"; }
# g06_fb <PR> <node ID> <branch> <run>: the node's feedback session <run> started in the node's worktree on the branch.
g06_fb() { grep -qF "fbnode $1 run $4 /noodlebot:node --feedback $1 | $wt6/$2 | $3 |" "$GD/claude.log"; }
g06_detached() { [ -d "$1" ] && ! git -C "$1" symbolic-ref -q HEAD >/dev/null; }
# g06_kept <commit> <branch>: the commit is on the branch or under refs/noodlebot/leftover/.
g06_kept() {
	git -C "$clone" merge-base --is-ancestor "$1" "refs/heads/$2" 2>/dev/null ||
		[ -n "$(git -C "$clone" for-each-ref --contains "$1" refs/noodlebot/leftover/)" ]
}
# g06_anyref <commit>: some branch or leftover ref still holds the commit (it is not lost).
g06_anyref() { [ -n "$(git -C "$clone" for-each-ref --contains "$1" refs/heads refs/noodlebot/leftover)" ]; }
# g06_leftover_setup <PR> <node ID> <branch> <mode>: the state an update of the PR left (after the first tick, loop running).
# The node's worktree gets a commit of its own that origin/<branch> lacks (printed as node=<sha>); mode "detached": the
# worktree is detached at it with node/<ID>/detached naming the branch (as free_branch leaves it); mode "plain": the worktree
# is on a branch of its own (node/<ID>-side) with that commit, no marker. pr-<PR> then holds <branch>, reset to origin/<branch>,
# with an unpushed commit of the update's own (printed as upd=<sha>).
g06_leftover_setup() {
	local n=$1 id=$2 br=$3 mode=$4 wt=$wt6/$2 nc uc
	git -C "$clone" fetch -q origin || return 1
	if [ "$mode" = detached ]; then git -C "$clone" worktree add -q -B "$br" "$wt" "origin/$br" || return 1
	else git -C "$clone" worktree add -q -b "node/$id-side" "$wt" "origin/$br" || return 1; fi
	git -C "$wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "node: its own commit" || return 1
	nc=$(git -C "$wt" rev-parse HEAD)
	if [ "$mode" = detached ]; then git -C "$wt" checkout -q --detach && mkdir -p "$state/node/$id" && echo "$br" >"$state/node/$id/detached" || return 1; fi
	git -C "$clone" worktree add -q -B "$br" "$wt6/pr-$n" "origin/$br" || return 1
	git -C "$wt6/pr-$n" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "update: merge of main (unpushed)" || return 1
	uc=$(git -C "$wt6/pr-$n" rev-parse HEAD)
	echo "node=$nc upd=$uc"
}
