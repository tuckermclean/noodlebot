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

# Guards against a reversed or weakened main clause (added after the slice review). The sentences of the final-review
# block and of the push paragraph that name the `Frozen test lines changed:` line must say the final review carries it:
# no negation, permission or omission before the verb, and the plain affirmative stays.
sentences() { tr '\n' ' ' <"$1" | sed 's/[.] /.\n/g' | grep -iF -e "$2"; }
main="$d/main.txt"; psent="$d/psent.txt"
awk '
	!on && /^[*][*]Frozen test lines in the final review[.][*][*]/ { on = 1 }
	on && /^$/ { exit }
	on && /^- [(]/ { exit }
	on { print }' "$s6" >"$main"
sentences "$main" 'frozen test lines changed' >"$d/msent.txt"
sentences "$push" 'frozen test lines changed' >"$psent"
NEG='(never|not|n.t|may|might|can|could|should|need not|optional|optionally|without|omit|omits|skip|skips|lacks?|leaves? out)[ a-z,`]{0,40}(carr|has|have|includes?|contains?|bears?|posts?|states?|gives?)|without an? [`]?frozen test lines changed|no [`]?frozen test lines changed'
never "U05-AC-1: step 6: the final review's main clause is not reversed or made optional (does not / need not / may / can carry, without the line)" "$d/msent.txt" "$NEG"
if [ -s "$psent" ]; then
	never "U05-AC-1: step 6: the push paragraph's sentence is not reversed or made optional (does not / need not / may carry ... either)" "$psent" "$NEG"
else ok "U05-AC-1: step 6: the push paragraph has no sentence about the line (the main block covers the new review after a push)"; fi
chk "U05-AC-1: step 6: the main clause is affirmative: the first and the new final review carry a line of their own" "$d/msent.txt" 3 \
	'every final review' 'after a push, (carries|has|includes|contains) a line of its own' 'frozen test lines changed: none'
if [ -s "$psent" ]; then
	chk "U05-AC-1: step 6: the push sentence is affirmative: the new final review carries the line too" "$psent" 3 \
		'the new final review (carries|has|includes|contains) the [`]?frozen test lines changed:' ' too'
fi
chk "U05-AC-1: step 6: (b) lists the node's commits with 'git rev-list --first-parent --no-merges <merge-base>..<head>'" "$s6" 4 \
	'git rev-list' '--first-parent' '--no-merges' '<merge-base>[.][.]<head>'
chk "U05-AC-1: step 6: (b) uses 'git blame' at the commit's parent to give the line to a RED or pin commit of this node" "$s6" 4 \
	'git blame' 'at [`]<commit>' 'gives it to a red or pin +commit of this node'

# Sentence-by-sentence guards (second slice review): the final-review block and the push sentence are cut into
# sentences and list items; each gets an affirmative check tight to its operative words and a guard that rejects a
# negation or a modal weakening (not, never, no, n't, may, might, can, could, should, optional, no longer, without,
# unless) once code spans and the sentence's own legitimate negation are taken out.
sents="$d/sents.txt"
tr '\n' ' ' <"$s6" | tr -s ' ' | sed -E 's/[.] /.\n/g; s/ - [(]([ab])[)]/\n- (\1)/g; s/^ +//' >"$sents"
pick() { grep -iF -e "$1" "$sents" >"$2"; }
AP="'"
NEGW="(^|[^a-z])(not|never|no|may|might|can|could|should|optional|optionally|longer|without|unless|nor|neither)([^a-z]|$)|n($AP|’)t"
# negs <label> <sentence file> [<legit ERE removed first>]
negs() {
	if [ ! -s "$2" ]; then bad "$1 (sentence missing)"; return; fi
	if tr 'A-Z' 'a-z' <"$2" | sed -E 's/`[^`]*`/ /g' | sed -E "s/${3:-@@@@}/ /g" | grep -Eq -e "$NEGW"
	then bad "$1"; else ok "$1"; fi
}
v="$d/s"
pick 'Every final review posted as' "${v}1"
pick 'counts each line once' "${v}2"
pick 'the `-` lines of' "${v}3"
pick 'lines that a RED or pin commit' "${v}4"
pick 'non-merge commits' "${v}5"
pick 'gives it to a RED' "${v}6"
pick 'brought in by merging' "${v}7"
pick 'kind (a) is' "${v}8"
pick 'is followed by those lines' "${v}9"
pick 'needs the owner' "${v}10"
pick 'The reviewer checks' "${v}11"
pick 'counted at the new head' "${v}12"
chk "U05-AC-1: step 6: sentence 1 says the first and the new final review carry a line of their own" "${v}1" 1 \
	'every final review posted as .fresh review [(]<verdict>[)] at <sha>., the first final review and the new final review after a push, carries a line of its own'
negs "U05-AC-1: step 6: sentence 1 has no negation or modal (not, never, may, can, optional, no longer ...)" "${v}1"
chk "U05-AC-1: step 6: sentence 2: <n> counts each line once over the frozen test and fixture paths, of two kinds" "${v}2" 1 \
	'<n>. counts each line once over the repository.s frozen test and fixture paths, of two kinds'
negs "U05-AC-1: step 6: sentence 2 has no negation or modal" "${v}2"
chk "U05-AC-1: step 6: kind (a): the '-' lines of git diff <merge-base>..<head> that existed at the merge base and that the PR changes or removes" "${v}3" 1 \
	'^ - [(]a[)] the .-. lines of .git diff <merge-base>[.][.]<head> -- <frozen paths>.: lines that existed at the merge base and that the pr changes or removes;'
negs "U05-AC-1: step 6: kind (a) has no negation or modal" "${v}3"
chk "U05-AC-1: step 6: kind (b): lines that a RED or pin commit of this node added and that a later commit of the node changes or removes" "${v}4" 1 \
	'^ - [(]b[)] lines that a red or pin commit of this node added and that a later commit of the node changes or removes'
negs "U05-AC-1: step 6: kind (b) has no negation or modal" "${v}4"
chk "U05-AC-1: step 6: the node's commits are the non-merge commits of the first-parent history after the merge base, by git rev-list" "${v}5" 1 \
	"the node.s commits are the non-merge commits of the branch.s first-parent history after the merge base [(].git rev-list --first-parent --no-merges <merge-base>[.][.]<head>.[)]"
negs "U05-AC-1: step 6: the node's commits sentence has no negation or modal" "${v}5"
chk "U05-AC-1: step 6: for each such commit a '-' line of git diff <commit>^..<commit> counts when git blame at <commit>^ gives it to a RED or pin commit" "${v}6" 1 \
	'for each such commit, a .-. line of .git diff <commit>.[.][.]<commit> -- <frozen paths>. counts when .git blame. at .<commit>.. gives it to a red or pin commit of this node'
negs "U05-AC-1: step 6: the blame sentence has no negation or modal" "${v}6"
chk "U05-AC-1: step 6: changes brought in by merging the base branch are not counted under (b): merge commits are left out" "${v}7" 1 \
	'^ changes brought in by merging the base branch are not counted under [(]b[)]: merge commits are left out'
negs "U05-AC-1: step 6: the merge sentence has no negation or modal beyond 'are not counted'" "${v}7" 'are not counted'
chk "U05-AC-1: step 6: a line of kind (a) is not counted again under (b)" "${v}8" 1 \
	'^ a line of kind [(]a[)] is not counted again under [(]b[)]'
negs "U05-AC-1: step 6: the (a)-not-again sentence has no negation or modal beyond 'is not counted'" "${v}8" 'is not counted'
chk "U05-AC-1: step 6: when <n> is 1 or more the line is followed by those lines: path, line number, the commit the number refers to (merge base for (a), RED or pin commit for (b))" "${v}9" 1 \
	'^ when .<n>. is 1 or more, the line is followed by those lines, each as its path, its line number and the commit that number refers to: the merge base for [(]a[)], the red or pin commit that added the line for [(]b[)]'
negs "U05-AC-1: step 6: the list sentence has no negation or modal (is not followed, may be followed ...)" "${v}9"
chk "U05-AC-1: step 6: then it says that the PR needs the owner's approval: a comment by the owner on the PR whose first line is 'Frozen lines approved at <head>'" "${v}10" 1 \
	'^ then it says that the pr needs the owner.s approval: a comment by the owner on the pr whose first line is .frozen lines approved at <head>.[.]?$'
negs "U05-AC-1: step 6: the approval sentence has no negation or modal (does not say, never says, may say, needs no ...)" "${v}10"
chk "U05-AC-1: step 6: the reviewer checks the line and the list against those diffs" "${v}11" 1 \
	'^ the reviewer checks the line and the list against those diffs'
negs "U05-AC-1: step 6: the reviewer sentence has no negation or modal (does not check, may check ...)" "${v}11"
chk "U05-AC-1: step 6: push: the new final review carries the Frozen test lines changed line too, counted at the new head" "${v}12" 1 \
	'the new final review carries the .frozen test lines changed:. line too, counted at the new head[.]?$'
negs "U05-AC-1: step 6: the push sentence has no negation or modal (does not carry, may carry, need not ...)" "${v}12"
if [ "$(grep -ci 'counted at the new head' "$push")" = 1 ]; then ok "U05-AC-1: step 6: the 'counted at the new head' sentence is in the push paragraph"
else bad "U05-AC-1: step 6: the 'counted at the new head' sentence is in the push paragraph"; fi

# no repository named: no owner/name, no repository URL, no forge kind with a real owner/name
if grep -nEi 'tuckermclean|github[.]com|gitlab[.]com|https?://' "$sk" >"$d/repo.txt"; then
	bad "U05-AC-1: the skill names a repository: $(head -3 "$d/repo.txt")"
elif grep -nE '(github|gitlab|gitea|forgejo):[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$sk" | grep -v 'owner/name' >"$d/repo.txt"; then
	bad "U05-AC-1: the skill names a repository: $(head -3 "$d/repo.txt")"
else ok "U05-AC-1: the skill names no repository"; fi
# a bare owner/name slug (not the placeholder owner/name) right after a word that introduces a repository or an example
if grep -oEi '(--repo|repositor(y|ies)|repo|for example|e[.]g[.]|such as|forge)[ :=]+[`]?[a-z0-9_.-]+/[a-z0-9_.-]+' "$sk" |
	grep -viE 'owner/name$' >"$d/repo.txt"; then
	bad "U05-AC-1: the skill names a bare owner/name repository slug: $(head -3 "$d/repo.txt")"
else ok "U05-AC-1: the skill names no bare owner/name repository slug"; fi

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
