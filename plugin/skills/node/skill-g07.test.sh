#!/bin/sh
# Tests G07 (final-review): step 6 of plugin/skills/node/SKILL.md (the final review is the last thing on the PR, AC-1),
# the head every posted review names (AC-2), a push after a posted review in the update and feedback procedures and in
# step 6 (AC-3), and the end-of-run line and the push rule of the four unattended templates (AC-4).
#   sh plugin/skills/node/skill-g07.test.sh   (make test)
# G07_ROOT (default: this checkout) names the tree whose files are read; the test only reads.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
root=${G07_ROOT:-$(cd "$src/../../.." && pwd -P)}
sk="$root/plugin/skills/node/SKILL.md"
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
d="$tmp/G07"; mkdir -p "$d"
fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# g07_section <heading-regex> <stop-regex> <outfile>: lines from the first heading line matching the first regex
# (lower-cased) up to the next line matching the stop regex.
g07_section() {
	awk -v re="$1" -v stop="$2" '
		on && $0 ~ stop { exit }
		!on && /^#/ && tolower($0) ~ re { on = 1 }
		on { print }' "$sk" >"$3"
}
# g07_win <file> <n> <ere>...: some window of <n> consecutive lines matches every ERE (case-insensitive).
g07_win() {
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
chk() { # chk <label> <file> <n> <ere>...
	c_l=$1; c_f=$2; c_n=$3; shift 3
	if [ ! -s "$c_f" ]; then bad "$c_l (section missing)"; return; fi
	if g07_win "$c_f" "$c_n" "$@"; then ok "$c_l"; else bad "$c_l"; fi
}
lit() { # lit <label> <file> <fixed string>: the string occurs literally
	if [ -s "$2" ] && grep -qF -e "$3" "$2"; then ok "$1"; else bad "$1"; fi
}

if [ ! -f "$sk" ]; then bad "plugin/skills/node/SKILL.md is missing"; echo "$fails failed"; exit 1; fi

s6="$d/step6.txt"; up="$d/update.txt"; fb="$d/feedback.txt"; rr="$d/resolution.txt"
g07_section '^## 6[.]' '^## 7[.]' "$s6"
g07_section '^## update a node pr' '^## 8[.]' "$up"
g07_section '^## 8[.] feedback' '^## cost' "$fb"
g07_section '^### resolution review' '^##? ' "$rr"
# the update section ends at its subsection "Resolution review": cut it from the update text
awk '/^### /{exit} {print}' "$up" >"$up.2" && mv "$up.2" "$up"

# ---------- G07-AC-1: step 6, the final review is the last thing on the PR ----------
chk "G07-AC-1: step 6: findings acted on are fixed first, test-first, then a new reviewer reviews the whole node at the final head" "$s6" 6 \
	'fix' 'test-first' 'new reviewer' 'whole node' 'final head'
lit "G07-AC-1: step 6: the posted review is headed 'Fresh review (<verdict>) at <sha>'" "$s6" 'Fresh review (<verdict>) at <sha>'
chk "G07-AC-1: step 6: only the final review is posted, with the head it reviewed" "$s6" 4 \
	'only' 'final' 'posted|post ' 'head'
chk "G07-AC-1: step 6: a review whose findings will still be acted on is never posted headed 'Fresh review ('" "$s6" 4 \
	'never' 'fresh review [(]' 'still' 'acted on|act on'
chk "G07-AC-1: step 6: such a review is kept in the session's notes (out/node/<ID>/)" "$s6" 5 \
	'still' 'notes' 'out/node/<id>/'
chk "G07-AC-1: step 6: or posted as a comment whose first line says the PR is not ready to merge" "$s6" 5 \
	'still' 'comment' 'first line' 'not ready to merge'
chk "G07-AC-1: step 6: the session posts nothing to the PR after its final review but its end" "$s6" 4 \
	'nothing' 'after' 'final review' 'end'
chk "G07-AC-1: step 6: the session posts nothing to the PR after its final review but its own end (that sentence)" "$s6" 2 \
	'posts nothing to the pr after its final review'
chk "G07-AC-1: step 6: the final review's <sha> is the head it reviewed" "$s6" 2 \
	'at <sha>' 'is the head it reviewed'
# no repository named: no owner of this repository, no repository URL, no forge kind with a real owner/name
if grep -nEi 'tuckermclean|github[.]com|gitlab[.]com' "$sk" >"$d/repo.txt"; then
	bad "G07-AC-1: the skill names a repository: $(head -3 "$d/repo.txt")"
elif grep -nE '(github|gitlab|gitea|forgejo):[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$sk" | grep -v 'owner/name' >"$d/repo.txt"; then
	bad "G07-AC-1: the skill names a repository: $(head -3 "$d/repo.txt")"
else ok "G07-AC-1: the skill names no repository"; fi

# ---------- G07-AC-2: every posted review names its head ----------
chk "G07-AC-2: every review comment the skill posts names the commit it covers on its first line as 'at <sha>'" "$sk" 4 \
	'every review' 'first line' 'at <sha>'
lit "G07-AC-2: the resolution review's heading reads 'Resolution review (<verdict>) at <sha>'" "$rr" 'Resolution review (<verdict>) at <sha>'

# ---------- G07-AC-3: a push after a posted review ----------
for part in update feedback; do
	case $part in update) tf=$up; tl="the update procedure";; *) tf=$fb; tl="the feedback procedure";; esac
	chk "G07-AC-3: $tl: a push after a posted Fresh review is preceded by a PR comment that the review at <sha> no longer covers the head" "$tf" 6 \
		'push' 'posted' 'fresh review' 'comment' 'at .?<sha>' 'no longer covers' 'head'
	chk "G07-AC-3: $tl: the PR is not ready to merge" "$tf" 6 'no longer covers' 'not ready to merge'
	lit "G07-AC-3: $tl: followed by a new 'Fresh review (<verdict>) at <new head>'" "$tf" 'Fresh review (<verdict>) at <new head>'
	chk "G07-AC-3: $tl: the new Fresh review comes from a new reviewer" "$tf" 6 'new reviewer' 'at <new head>'
	chk "G07-AC-3: $tl: the new 'Fresh review (<verdict>) at <new head>' is from a new reviewer (that phrase)" "$tf" 2 \
		'at <new head>[^a-z]*from a new reviewer'
	chk "G07-AC-3: $tl: the whole node when the node's own code changed since the reviewed head" "$tf" 6 \
		'whole node' 'own code' 'changed' 'reviewed head'
	chk "G07-AC-3: $tl: else the diff from the reviewed head to the new head" "$tf" 6 \
		'else|otherwise' 'diff' 'reviewed head' 'new head'
done
chk "G07-AC-3: step 6: a push after the final review is preceded by a comment that the review no longer covers the head (not ready to merge)" "$s6" 6 \
	'push' 'after' 'final review' 'no longer covers' 'not ready to merge'
lit "G07-AC-3: step 6: followed by a new 'Fresh review (<verdict>) at <new head>'" "$s6" 'Fresh review (<verdict>) at <new head>'
chk "G07-AC-3: step 6: the push after the final review is a CI fix or a resumed session after an answer" "$s6" 6 \
	'push' 'no longer covers' 'ci' 'answer'
chk "G07-AC-3: step 6: the new Fresh review comes from a new reviewer" "$s6" 6 'new reviewer' 'at <new head>'
chk "G07-AC-3: step 6: the new 'Fresh review (<verdict>) at <new head>' is from a new reviewer (that phrase)" "$s6" 2 \
	'at <new head>[^a-z]*from a new reviewer'
chk "G07-AC-3: step 6: the whole node when the node's own code changed since the reviewed head" "$s6" 6 \
	'whole node' 'own code' 'changed' 'reviewed head'
chk "G07-AC-3: step 6: else the diff from the reviewed head to the new head" "$s6" 6 \
	'else|otherwise' 'diff' 'reviewed head' 'new head'

# ---------- G07-AC-4: the templates ----------
t1="$root/scheduler/unattended.md"; t2="$root/scheduler/unattended-followup.md"
t3="$root/scheduler/unattended-feedback.md"; t4="$root/scheduler/unattended-node-update.md"
for t in "$t1" "$t2"; do
	tn=${t##*/}
	if [ ! -f "$t" ]; then bad "G07-AC-4: $tn is missing"; continue; fi
	chk "G07-AC-4: $tn: the run ends when the PR is open, the last posted review is a 'Fresh review (<verdict>) at <sha>' naming the PR's head, CI on that head green" "$t" 5 \
		'pr is open' 'last' 'fresh review [(]<verdict>[)] at <sha>' 'head' 'ci' 'green' 'end the run'
	chk "G07-AC-4: $tn: the end-of-run line's 'at <sha>' is naming the PR's head (that phrase)" "$t" 2 \
		'at <sha>[^a-z]*naming the pr.s head'
done
for t in "$t1" "$t2" "$t3" "$t4"; do
	tn=${t##*/}
	if [ ! -f "$t" ]; then bad "G07-AC-4: $tn is missing"; continue; fi
	chk "G07-AC-4: $tn: a run that pushes after a posted review first comments that the review no longer covers the head" "$t" 6 \
		'push' 'posted' 'review' 'comment' 'no longer cover' 'head'
	chk "G07-AC-4: $tn: ... and ends with a new final review naming the new head" "$t" 6 \
		'push' 'posted' 'no longer cover' 'new final review|new fresh review' 'new head' 'end'
	if grep -nEi 'tuckermclean|github|gitlab|gitea|forgejo|(^|[^A-Za-z])gh ' "$t" >"$d/t.txt"; then
		bad "G07-AC-4: $tn names a repository or a forge: $(head -3 "$d/t.txt")"
	else ok "G07-AC-4: $tn names no repository and no forge"; fi
done

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
