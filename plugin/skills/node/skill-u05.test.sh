#!/bin/sh
# Tests U05 (frozen-approval) AC-1: step 6 of plugin/skills/node/SKILL.md says that every final review (the first one
# and the new one after a push) carries a `Frozen test lines changed:` line, what <n> counts (kinds (a) and (b), merges
# of the base branch left out of (b), each line once), what is listed (path, line number, the commit it refers to),
# the owner's approval comment `Frozen lines approved at <head>` and the reviewer's check against the diffs.
#   sh plugin/skills/node/skill-u05.test.sh   (make test)
# U05_ROOT (default: this checkout) names the tree whose files are read; the test only reads.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
root=${U05_ROOT:-$(cd "$src/../../.." && pwd -P)}
sk="$root/plugin/skills/node/SKILL.md"
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
d="$tmp/U05"; mkdir -p "$d"
fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

if [ ! -f "$sk" ]; then bad "plugin/skills/node/SKILL.md is missing"; echo "$fails failed"; exit 1; fi

# step 6 (from its heading up to step 7's), and its last paragraph "A push after the final review" up to the next
# blank-line-separated paragraph that does not belong to it
s6="$d/step6.txt"; push="$d/push.txt"
awk '
	on && /^## 7[.]/ { exit }
	!on && /^## 6[.]/ { on = 1 }
	on { print }' "$sk" >"$s6"
awk '
	!on && /^[*][*]A push after the final review[*][*]/ { on = 1 }
	on && /^$/ { exit }
	on { print }' "$s6" >"$push"

# win <file> <n> <ere>...: some window of <n> consecutive lines matches every ERE (case-insensitive).
win() {
	w_f=$1; w_n=$2; shift 2
	pats=$(printf '%s\n' "$@")
	awk -v n="$w_n" -v pats="$pats" '
		BEGIN { k = split(pats, P, "\n") }
		{ L[NR] = tolower($0) }
		END {
			for (i = 1; i <= NR; i++) {
				w = ""; for (j = i; j < i + n && j <= NR; j++) w = w " " L[j]
				good = 1; for (p = 1; p <= k; p++) if (w !~ P[p]) { good = 0; break }
				if (good) exit 0
			}
			exit 1 }' "$w_f"
}
# chk <label> <file> <n> <ere>...: the clause is there (a missing section is a failure, not a pass)
chk() {
	c_l=$1; c_f=$2; c_n=$3; shift 3
	if [ ! -s "$c_f" ]; then bad "$c_l (section missing)"; return; fi
	if win "$c_f" "$c_n" "$@"; then ok "$c_l"; else bad "$c_l"; fi
}
# never <label> <file> <ere>: the whole section, as one line, has no match of the ERE (a reversed clause)
never() {
	if [ ! -s "$2" ]; then bad "$1 (section missing)"; return; fi
	if tr '\n' ' ' <"$2" | tr 'A-Z' 'a-z' | grep -Eq -e "$3"; then bad "$1"; else ok "$1"; fi
}

L='frozen test lines changed:'
chk "U05-AC-1: step 6: the first final review carries the line 'Frozen test lines changed: none' or '... <n>'" "$s6" 4 \
	'every (final )?review|first (final )?review' 'carr(y|ies)|has a line|includes' "first (final )?review" \
	"$L none" "$L <n>"
chk "U05-AC-1: step 6: every final review is the one posted as 'Fresh review (<verdict>) at <sha>'" "$s6" 3 \
	'every (final )?review' 'fresh review [(]<verdict>[)] at <sha>' "$L"
c2=0
if [ -s "$push" ] && grep -qiF "$L" "$push"; then c2=1; fi
if [ "$c2" = 0 ] && win "$s6" 3 "$L" 'new (final )?review' 'after a push'; then c2=1; fi
if [ ! -s "$push" ]; then bad "U05-AC-1: step 6: the new final review after a push carries the line too (section missing)"
elif [ "$c2" = 1 ]; then ok "U05-AC-1: step 6: the new final review after a push carries the line too"
else bad "U05-AC-1: step 6: the new final review after a push carries the line too"; fi
chk "U05-AC-1: step 6: <n> counts the lines of the repository's frozen test and fixture paths" "$s6" 4 \
	'<n>' 'counts' 'frozen test' 'fixture' 'paths'
chk "U05-AC-1: step 6: each line is counted once" "$s6" 4 'counts? each line once|each line (is )?counted once|each line counts once'
chk "U05-AC-1: step 6: kind (a): the '-' lines of 'git diff <merge-base>..<head>'" "$s6" 4 \
	'[(]a[)]' '[`]-[`] lines' 'git diff <merge-base>[.][.]<head>'
chk "U05-AC-1: step 6: kind (a): lines that existed at the merge base and that the PR changes or removes" "$s6" 4 \
	'[(]a[)]' 'existed at the merge base' 'the pr changes or removes'
never "U05-AC-1: step 6: kind (a) is not reversed (lines that did not exist at the merge base)" "$s6" \
	'(did not|not) exist(ed)? at the merge base'
chk "U05-AC-1: step 6: kind (b): lines that a RED or pin commit of this node added" "$s6" 4 \
	'[(]b[)]' 'red or pin commit of this node added'
chk "U05-AC-1: step 6: kind (b): that a later commit of the node changes or removes" "$s6" 4 \
	'[(]b[)]' 'red or pin commit.*added.*later commit of the node changes or removes'
chk "U05-AC-1: step 6: kind (b): the node's commits are the non-merge commits of the branch's first-parent history after the merge base" "$s6" 4 \
	'non-merge commits' 'first-parent history' 'after the merge base|<merge-base>[.][.]<head>'
chk "U05-AC-1: step 6: changes brought in by merging the base branch are not counted under (b)" "$s6" 4 \
	'brought in by merging the base branch[^.:;]*(are not counted|do not count|not counted)' 'under [(]b[)]'
chk "U05-AC-1: step 6: merge commits are left out under (b)" "$s6" 4 \
	'merge commits (are )?(left out|excluded|not included)|leaves? (out )?merge commits|(left|leaving) out' 'under [(]b[)]|[(]b[)]'
never "U05-AC-1: step 6: merge commits are not counted in (b) is not reversed (merge commits included or counted)" "$s6" \
	'merge commits (are )?(included|counted)|not (left|leaving) out|not excluded'
chk "U05-AC-1: step 6: a line of kind (a) is not counted again under (b)" "$s6" 4 \
	'[(]a[)]' 'not counted again|not counted twice' 'under [(]b[)]'
chk "U05-AC-1: step 6: when <n> is 1 or more, each listed line gives its path" "$s6" 3 \
	'<n>[`]? is 1 or more' 'its path'
chk "U05-AC-1: step 6: when <n> is 1 or more, each listed line gives its line number" "$s6" 3 \
	'<n>[`]? is 1 or more' 'its line number'
chk "U05-AC-1: step 6: each listed line gives the commit that its line number refers to" "$s6" 4 \
	'<n>[`]? is 1 or more' 'commit that (its |the )?(line )?number refers to'
chk "U05-AC-1: step 6: the commit that number refers to is the merge base for (a)" "$s6" 4 \
	'the merge base for [(]a[)]'
chk "U05-AC-1: step 6: the commit that number refers to is the RED or pin commit that added the line for (b)" "$s6" 4 \
	'red or pin commit that added[^.;]*for [(]b[)]'
chk "U05-AC-1: step 6: then that the PR needs the owner's approval when <n> is 1 or more" "$s6" 5 \
	'<n>[`]? is 1 or more' 'the pr needs the owner.s approval'
chk "U05-AC-1: step 6: the approval is a comment by the owner on the PR whose first line is 'Frozen lines approved at <head>'" "$s6" 3 \
	'comment by the owner|owner comment|owner.s comment' 'first line is [`]frozen lines approved at <head>[`]'
chk "U05-AC-1: step 6: the reviewer checks the line and the list against those diffs" "$s6" 3 \
	'the reviewer checks' 'the line' 'the list' 'against those diffs'
never "U05-AC-1: step 6: the reviewer's check is not reversed" "$s6" \
	'reviewer (does not|never|need not) check'

# no repository named: no owner/name, no repository URL, no forge kind with a real owner/name
if grep -nEi 'tuckermclean|github[.]com|gitlab[.]com|https?://' "$sk" >"$d/repo.txt"; then
	bad "U05-AC-1: the skill names a repository: $(head -3 "$d/repo.txt")"
elif grep -nE '(github|gitlab|gitea|forgejo):[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$sk" | grep -v 'owner/name' >"$d/repo.txt"; then
	bad "U05-AC-1: the skill names a repository: $(head -3 "$d/repo.txt")"
else ok "U05-AC-1: the skill names no repository"; fi

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
