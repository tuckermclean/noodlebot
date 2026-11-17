#!/bin/sh
# Tests plugin/skills/node/SKILL.md: the update procedure (G02-AC-4), the resolution review (G02-AC-5, node skill),
# the tester step's scratch-folder rule (G02-AC-6).
#   sh plugin/skills/node/skill.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
sk="$src/SKILL.md"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
d="$tmp/G02"; mkdir -p "$d"
fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# g02_section <heading-regex> <outfile>: the lines from the first "## " heading matching the regex up to the next "## " heading.
g02_section() {
	awk -v re="$1" '
		/^## / { if (on) exit; if (tolower($0) ~ re) on = 1 }
		on { print }' "$sk" >"$2"
}
# g02_win <file> <n> <ere>...: some window of <n> consecutive lines matches every ERE (case-insensitive).
g02_win() {
	f=$1; n=$2; shift 2
	pats=$(printf '%s\n' "$@")
	awk -v n="$n" -v pats="$pats" '
		BEGIN { k = split(pats, P, "\n") }
		{ L[NR] = tolower($0) }
		END {
			for (i = 1; i <= NR; i++) {
				w = ""; for (j = i; j < i + n && j <= NR; j++) w = w " " L[j]
				good = 1; for (p = 1; p <= k; p++) if (w !~ P[p]) { good = 0; break }
				if (good) exit 0
			}
			exit 1 }' "$f"
}
# g02_line <file> <ere>: number of the first line matching (case-insensitive), empty if none.
g02_line() { awk -v re="$2" 'tolower($0) ~ re { print NR; exit }' "$1"; }
g02_check() { # g02_check <label> <file> <n> <ere>...
	lbl=$1; f=$2; n=$3; shift 3
	if g02_win "$f" "$n" "$@"; then ok "$lbl"; else bad "$lbl"; fi
}

if [ ! -f "$sk" ]; then bad "plugin/skills/node/SKILL.md is missing"; echo "$fails failed"; exit 1; fi

# ---------- G02-AC-4: the update section ----------
u="$d/update.txt"
g02_section '^## .*--update' "$u"
if [ -s "$u" ]; then ok "G02-AC-4: a '## ' heading names --update"; else bad "G02-AC-4: no '## ' heading names --update"; fi
g02_check "G02-AC-4: update section describes --update <PR>" "$u" 3 '--update <pr>'
g02_check "G02-AC-4: update section describes --dry-run" "$u" 3 '--dry-run'
g02_check "G02-AC-4: --dry-run stops before the push and writes out/node/pr-<N>/result.md" "$u" 4 '--dry-run' 'out/node/pr-<n>/result\.md' 'push'
g02_check "G02-AC-4: merges origin/main into the PR's branch" "$u" 3 'merge' 'origin/main'
g02_check "G02-AC-4: the merge is a merge commit" "$u" 3 'merge commit'
g02_check "G02-AC-4: no rebase" "$u" 3 '(never|no|not|without)[^.]*rebase|rebase[^.]*(never|forbidden|not)'
g02_check "G02-AC-4: no force push" "$u" 3 '(never|no|not|without)[^.]*force|force[^.]*(never|forbidden|not)'
g02_check "G02-AC-4: a frozen test or fixture line that would change aborts the merge, pushes nothing, ends in QUESTION.md" "$u" 5 'frozen' 'abort' 'question\.md' 'nothing'
g02_check "G02-AC-4: a spec file that would change ends in QUESTION.md" "$u" 5 'spec file' 'question\.md'
g02_check "G02-AC-4: added test lines only keep appended test blocks apart" "$u" 4 'appended' 'apart|separat' 'test (file|line)|line'
g02_check "G02-AC-4: added test lines are listed in the PR comment" "$u" 4 'comment' 'added|each' 'test line|line'
g02_check "G02-AC-4: reruns make test and the PR's red targets" "$u" 4 'make test' 'red target'
g02_check "G02-AC-4: pushes only after the resolution review" "$u" 4 'push' 'resolution review' 'only|until|after|approv'
g02_check "G02-AC-4: comment holds each resolved file, the test results and the review's verdict" "$u" 5 'comment' 'resolved file|each file|each resolved' 'test result' 'verdict'
g02_check "G02-AC-4: reruns the whole-node fresh review only when the node's own code changed beyond keeping both sides" "$u" 4 'fresh review' 'only (when|if)|unless' 'beyond|own code'
g02_check "G02-AC-4: a failing test it cannot fix is a QUESTION.md with nothing pushed" "$u" 4 'fail' 'test' 'question\.md' 'nothing'
a=$(g02_line "$u" 'make test'); b=$(g02_line "$u" 'new reviewer'); c=$(g02_line "$u" 'resolved file|each file|each resolved')
if [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]; then ok "G02-AC-4: order: make test, then the new reviewer, then the comment"; else bad "G02-AC-4: order make test < new reviewer < comment not found (${a:-none}, ${b:-none}, ${c:-none})"; fi

# ---------- G02-AC-5: the resolution review (node skill) ----------
g02_check "G02-AC-5: a new reviewer reviews the resolution" "$u" 4 'resolution review|review of (the|every) (conflict )?resolution' 'new reviewer|fresh reviewer'
g02_check "G02-AC-5: the reviewer gets the merge commit and its diffs against both parents" "$u" 4 'merge commit' 'both parents' 'diff'
g02_check "G02-AC-5: it checks both sides' intent" "$u" 6 'intent' 'both sides'
g02_check "G02-AC-5: it checks that test blocks of different nodes share no names or state" "$u" 6 'test block' 'different nodes|other nodes|another node' 'names|state'
g02_check "G02-AC-5: it checks that no frozen test line changed" "$u" 6 'review' 'frozen test line|frozen line|frozen test' 'no .*(changed|removed|renamed)|not (been )?(changed|removed|renamed)|unchanged'
g02_check "G02-AC-5: nothing is pushed before the review approves" "$u" 5 'review' 'approv' 'push'
g02_check "G02-AC-5: the verdict is posted on the PR headed 'Resolution review (<verdict>)'" "$u" 4 'resolution review [(]' 'verdict'
g02_check "G02-AC-5: the review is a comment, never an approval" "$u" 5 'resolution review' 'comment' 'never an approval|not an approval|never approv|not approv'
g02_check "G02-AC-5: a second rejection pushes nothing and ends with QUESTION.md" "$u" 5 'second' 'reject|request_changes' 'nothing' 'question\.md'
s6="$d/step6.txt"; g02_section '^## 6\.' "$s6"
if [ -s "$s6" ]; then ok "G02-AC-5: step 6 (Pull request) found"; else bad "G02-AC-5: step 6 (Pull request) not found"; fi
g02_check "G02-AC-5: the merge of origin/main before the final CI run gets the resolution review" "$s6" 6 'origin/main' 'resolution review|resolution.*new reviewer|new reviewer.*resolution'

# ---------- G02-AC-6: the tester step's scratch-folder rule ----------
s2="$d/step2.txt"; g02_section '^## 2\.' "$s2"
if [ -s "$s2" ]; then ok "G02-AC-6: step 2 (RED) found"; else bad "G02-AC-6: step 2 (RED) not found"; fi
g02_check "G02-AC-6: a test block appended to a shared test file keeps its scratch paths under a folder named after its node" "$s2" 4 'append' 'shared' 'scratch' 'folder|director' 'named after|<id>'
g02_check "G02-AC-6: the rule names what the scratch paths are (folders, remotes, state, fake binaries)" "$s2" 4 'scratch' 'remote|state|fake'

# ---------- G02-AC-4: the skill names no repository ----------
# Allowed: the plugin's own `noodlebot:` agents and command, `.noodlebot/` config. Not allowed: an owner or a repository name.
sed -e 's/noodlebot:/PLUGIN:/g' -e 's#\.noodlebot/#.CONF/#g' "$sk" >"$d/skill.stripped"
if grep -qi 'tuckermclean' "$d/skill.stripped"; then bad "G02-AC-4: SKILL.md names an owner (tuckermclean)"; else ok "G02-AC-4: SKILL.md names no owner"; fi
if grep -qi 'themonolith\|noodlebot' "$d/skill.stripped"; then bad "G02-AC-4: SKILL.md names a repository (noodlebot / themonolith)"; else ok "G02-AC-4: SKILL.md names no repository outside the plugin's own names"; fi
if grep -Eqi -e '--repo[ =]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|github\.com[:/]|git@github' "$d/skill.stripped"; then bad "G02-AC-4: SKILL.md has a repository slug or URL"; else ok "G02-AC-4: SKILL.md has no repository slug or URL"; fi


# ---------- G02 slice 3b (review3 findings 1-4): checks tied to the numbered steps of the update section ----------
# g02b_steps <in> <out>: one line per numbered step "<n><TAB><text>" (wrapped lines joined, lowercase, no asterisks).
g02b_steps() {
	tr -d '*' <"$1" | awk '
		function flush() { if (cur != "") print tolower(cur); cur = "" }
		/^[0-9]+\. / { flush(); n = $0; sub(/\..*/, "", n); t = $0; sub(/^[0-9]+\. */, "", t); cur = n "\t" t; next }
		/^[ \t]*$/ || /^#/ { flush(); next }
		cur != "" { sub(/^[ \t]+/, ""); cur = cur " " $0 }
		END { flush() }' >"$2"
}
# g02b_no <file> <ere>: number of the first step whose text matches.
g02b_no() { awk -F'\t' -v re="$2" '$2 ~ re { print $1; exit }' "$1"; }
g02b_has() { # g02b_has <label> <file> <ere>...: one line (a step, a bullet, a paragraph) matches every ERE
	lbl=$1; f=$2; shift 2
	if awk -v pats="$(printf '%s\n' "$@")" 'BEGIN { k = split(pats, P, "\n") }
		{ l = tolower($0); good = 1; for (p = 1; p <= k; p++) if (l !~ P[p]) { good = 0; break } if (good) found = 1 }
		END { exit !found }' "$f"; then ok "$lbl"; else bad "$lbl"; fi
}
g02b_steps "$u" "$d/usteps.txt"
tn=$(g02b_no "$d/usteps.txt" 'make test'); rn=$(g02b_no "$d/usteps.txt" 'resolution review'); pn=$(g02b_no "$d/usteps.txt" '^push')
fn=$(g02b_no "$d/usteps.txt" 'frozen')
if [ -n "$tn" ] && [ -n "$rn" ] && [ -n "$pn" ] && [ "$tn" -lt "$pn" ] && [ "$rn" -lt "$pn" ]; then ok "G02-AC-4: the push step ($pn) comes after the make-test step ($tn) and the resolution-review step ($rn)"; else bad "G02-AC-4: the push step must come after the make-test step and the resolution-review step (test ${tn:-none}, review ${rn:-none}, push ${pn:-none})"; fi
pt=$(awk -F'\t' -v n="${pn:-0}" '$1 == n { print $2 }' "$d/usteps.txt")
for pair in 'resolved file|each file|each resolved:each resolved file' 'added test line|each added test:each added test line' 'test result:the test results' 'verdict:the review.s verdict' 'comment:a PR comment'; do
	if printf '%s\n' "$pt" | grep -Eqi -e "${pair%%:*}"; then ok "G02-AC-4: the push step names ${pair#*:}"; else bad "G02-AC-4: the push step (${pn:-none}) does not name ${pair#*:}"; fi
done
ft=$(awk -F'\t' -v n="${fn:-0}" '$1 == n { print $2 }' "$d/usteps.txt")
for pair in 'abort:abort the merge' 'push(es)? nothing:push nothing' 'question\.md:QUESTION.md'; do
	if printf '%s\n' "$ft" | grep -Eqi -e "${pair%%:*}"; then ok "G02-AC-4: the frozen/spec rule step (${fn:-none}) says: ${pair#*:}"; else bad "G02-AC-4: the frozen/spec rule step (${fn:-none}) lacks: ${pair#*:}"; fi
done
# the ### Resolution review subsection
rv="$d/rv.txt"; awk '/^### / { if (on) exit; if (tolower($0) ~ /resolution review/) on = 1; next } on { print }' "$u" >"$rv"
if [ -s "$rv" ]; then ok "G02-AC-5: a '### Resolution review' subsection exists"; else bad "G02-AC-5: no '### Resolution review' subsection"; fi
g02b_has "G02-AC-5: the reviewer's checklist (a bullet) names the frozen test line rule" "$rv" '^- ' 'frozen' 'changed|removed|renamed'
g02b_has "G02-AC-5: the review section says nothing is pushed until it approves" "$rv" 'nothing is pushed until|push(ed)? only after' 'approv'
if [ "$(tr -d '*' <"$rv" | grep -oi 'new reviewer' | wc -l)" -ge 2 ] && ! grep -Eqi 'earlier reviewer|same reviewer|previous reviewer|first reviewer|resume' "$rv"; then ok "G02-AC-5: both rounds of the review use a new reviewer"; else bad "G02-AC-5: the second round must use a new reviewer too (not the earlier one)"; fi
# finding 2: a restarted update reads the owner's answer
g02b_has "G02-AC-4: a restarted update reads the owner's answer in answered/" "$u" 'answered/' 'answer' 'restart|resum|read'
g02b_has "G02-AC-4: an owner's approval in answered/ permits the change it approves, quoted in the PR comment" "$u" 'approv' 'answered/|answer' 'permit|allow' 'quot' 'comment'
# finding 3: no merge commit is left when the update ends in QUESTION.md
cn=$(g02b_no "$d/usteps.txt" 'commit (the|this) (merge|resolution)|commit it|merge is committed')
if [ -n "$cn" ] && [ -n "$tn" ] && [ "$cn" -le "$tn" ]; then ok "G02-AC-4: the merge is committed (step $cn) no later than the tests step ($tn)"; else bad "G02-AC-4: no step commits the merge before the tests and the review (commit ${cn:-none}, tests ${tn:-none})"; fi
g02b_has "G02-AC-4: a failing test it cannot fix leaves the branch as it was (reset --hard origin/<branch>)" "$d/usteps.txt" 'fail' 'question\.md' 'reset --hard origin/<branch>'
g02b_has "G02-AC-5: a second rejection leaves the branch as it was (reset --hard origin/<branch>)" "$rv" 'second' 'question\.md' 'reset --hard origin/<branch>'
# finding 4: --dry-run and the review's verdict
g02b_has "G02-AC-5: with --dry-run the review's verdict goes into result.md and is not posted on the PR" "$rv" '--dry-run' 'verdict' 'result\.md' 'not (be )?posted|not post|never posted|instead of post'


# ---------- G02 slice 3c (review3b findings 2, 4, 5) ----------
# the text before the review step is run (steps before it, and the review step up to its first "resolution review") pushes nothing
g02c_strip() { sed -E -e 's/(never|no|not|without)[^.;]*push[a-z]*//g' -e 's/push(es)? nothing//g' -e 's/nothing is pushed//g'; }
g02c_pre=$(awk -F'\t' -v n="${rn:-0}" '$1 < n { print $2 } $1 == n { t = $2; i = index(t, "resolution review"); if (i) t = substr(t, 1, i - 1); print t }' "$d/usteps.txt" | g02c_strip)
if [ -n "$rn" ] && ! printf '%s\n' "$g02c_pre" | grep -Eqi 'push'; then ok "G02-AC-4: no step before the review step pushes"; else bad "G02-AC-4: a step before (or the start of) the review step ${rn:-none} pushes"; fi
# finding 4: no force push anywhere in the update section but in a prohibition
g02c_flat=$(tr -d '*\n' <"$u" | tr 'A-Z' 'a-z' | sed -E 's/(never|no|not|without)[^.;]*//g')
if printf '%s\n' "$g02c_flat" | grep -Eq -e '--force|--force-with-lease|push[^.]* -f( |$)|git push -f'; then bad "G02-AC-4: the update section force-pushes outside a prohibition"; else ok "G02-AC-4: the update section does not force-push outside a prohibition"; fi
g02b_has "G02-AC-4: the --dry-run step stops before the push and pushes nothing" "$d/usteps.txt" '--dry-run' 'result\.md' 'stop(s)? before the push' 'no push|not push|pushes nothing|nothing is pushed|without push'
g02b_has "G02-AC-4: the --dry-run step does not push" "$d/usteps.txt" '--dry-run' 'result\.md' 'no push|not push|pushes nothing|nothing is pushed|without push'
if printf '%s\n' "$ft" | grep -Eqi 'frozen test or fixture'; then ok "G02-AC-4: the frozen rule names 'test or fixture'"; else bad "G02-AC-4: the frozen rule (step ${fn:-none}) does not name 'frozen test or fixture'"; fi
# finding 5: the frozen/spec rule speaks of what resolving a conflict would change
if printf '%s\n' "$ft" | grep -Eqi 'resolv' && printf '%s\n' "$ft" | grep -Eqi 'would change'; then ok "G02-AC-4: the frozen/spec rule speaks of what resolving a conflict would change"; else bad "G02-AC-4: the frozen/spec rule (step ${fn:-none}) must speak of what resolving a conflict would change, not of everything the merge brings in"; fi
# finding 4: no repository named through -R / --repo / a slug after gh options
if grep -Eqi -e '(^|[[:space:]])(-R|--repo)[ =]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$d/skill.stripped"; then bad "G02-AC-4: SKILL.md names a repository after -R / --repo"; else ok "G02-AC-4: SKILL.md names no repository after -R / --repo"; fi
if grep -o '<forge> [^`]*' "$d/skill.stripped" | tr -s ' ' '\n' | grep -Eq '^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+(#[0-9]+)?$'; then bad "G02-AC-4: a <forge> command in SKILL.md carries an owner/name slug"; else ok "G02-AC-4: no forge CLI command in SKILL.md carries an owner/name slug"; fi
# finding 2: the resolution review scopes the second-rejection reset
rvj=$(tr -d '*\n' <"$rv" | tr 'A-Z' 'a-z')
if printf '%s\n' "$rvj" | grep -Fq 'reset --hard origin/<branch>'; then ok "G02-AC-5: the review section keeps 'reset --hard origin/<branch>'"; else bad "G02-AC-5: the review section lacks 'reset --hard origin/<branch>'"; fi
if printf '%s\n' "$rvj" | grep -Eq 'first parent|orig_head' && printf '%s\n' "$rvj" | grep -Eq 'node build|node.s own (merge|build)|in a (node )?build|own merge'; then ok "G02-AC-5: the second-rejection reset is scoped: --update resets to origin/<branch>, a node build's own merge to its first parent"; else bad "G02-AC-5: the review section does not distinguish --update (reset to origin/<branch>) from a node build's own merge (undo the merge at its first parent / ORIG_HEAD)"; fi
# ---------- G02 slice 3d (review3c findings 1-5): checks that only tighten the criteria checks above ----------
# finding 1 (AC-6): the scratch-folder sentence of step 2 is mandatory and names the node
g02d_s2=$(tr -d '*\n' <"$s2" | tr 'A-Z' 'a-z' | sed 's/\. /.\n/g' | grep -E 'scratch' | grep -E 'named after')
if printf '%s\n' "$g02d_s2" | grep -Eq 'named after (its|the|their) node|<id>'; then ok "G02-AC-6: the scratch-folder sentence names the folder after its node (its node / <ID>)"; else bad "G02-AC-6: the scratch-folder sentence ('${g02d_s2:-none}') must say the folder is named after its node (<ID>)"; fi
if [ -n "$g02d_s2" ] && ! printf '%s\n' "$g02d_s2" | grep -Eq '\bmay\b|\bmight\b|\bcan\b|if it like|if you like|optional|should' && printf '%s\n' "$g02d_s2" | grep -Eq '\bkeeps\b|\bmust\b|\bmust keep\b|\balways\b'; then ok "G02-AC-6: the scratch-folder rule is mandatory (no may / if it likes)"; else bad "G02-AC-6: the scratch-folder sentence must be mandatory (keeps / must), not optional"; fi
# finding 2 (AC-5 node): the sentence starting at "second rejection" itself says nothing is pushed and QUESTION.md
g02d_sr=$(tr -d '*\n' <"$rv" | tr 'A-Z' 'a-z' | awk '{ i = index($0, "second rejection"); if (i) { t = substr($0, i); j = match(t, /\. /); if (j) t = substr(t, 1, j); print t } }')
if printf '%s\n' "$g02d_sr" | grep -Eq 'push(es)? nothing|nothing is pushed' && printf '%s\n' "$g02d_sr" | grep -Fq 'question.md'; then ok "G02-AC-5: the second-rejection sentence itself says nothing is pushed and writes QUESTION.md"; else bad "G02-AC-5: the second-rejection sentence ('${g02d_sr:-none}') must say nothing is pushed and write QUESTION.md"; fi
# finding 3 (AC-5): the sentence holding "Resolution review (" says the verdict is posted on the PR
g02d_pv=$(tr -d '*\n' <"$rv" | tr 'A-Z' 'a-z' | sed 's/\. /.\n/g' | grep -F 'resolution review (')
if printf '%s\n' "$g02d_pv" | grep -Eq 'posted on the pr|<forge> pr comment'; then ok "G02-AC-5: the sentence with 'Resolution review (' says the verdict is posted on the PR"; else bad "G02-AC-5: the sentence with 'Resolution review (' ('${g02d_pv:-none}') must say the verdict is posted on the PR (the forge CLI's pr comment)"; fi
# finding 4 (AC-4): the fresh review is rerun only when the resolution changed the node's own code beyond keeping both sides
if grep -Eqi 'fresh review' "$d/usteps.txt" && grep -E 'fresh review' "$d/usteps.txt" | grep -Eq 'only when[^.]*changed[^.]*beyond keeping both sides'; then ok "G02-AC-4: the fresh-review step runs only when the resolution changed the node's code beyond keeping both sides"; else bad "G02-AC-4: the fresh-review step must say 'only when ... changed ... beyond keeping both sides'"; fi
# finding 5 (AC-4): the frozen/spec rule ends the run there and does not go on resolving
if printf '%s\n' "$ft" | grep -Eq '(^|[^a-z])end\.?[[:space:]]*$|and end' && ! printf '%s\n' "$ft" | grep -Eq 'as you see fit|continue with step|then resolve'; then ok "G02-AC-4: the frozen/spec rule step ends the run there and does not continue resolving"; else bad "G02-AC-4: the frozen/spec rule step (${fn:-none}) must end the run, not continue resolving"; fi

# ---------- G02 slice 3e (review-fresh findings 3 and 4) ----------
# g02e_sent <file> <ere>...: some sentence (file flattened, lowercase, no asterisks, split after ". ") matches every ERE
g02e_sent() {
	g02e_f=$1; shift
	tr -d '*' <"$g02e_f" | tr '\n' ' ' | tr -s ' ' | tr 'A-Z' 'a-z' | sed 's/[.] /.\n/g' |
		awk -v pats="$(printf '%s\n' "$@")" 'BEGIN { k = split(pats, P, "\n") }
			{ good = 1; for (p = 1; p <= k; p++) if ($0 !~ P[p]) { good = 0; break } if (good) found = 1 }
			END { exit !found }'
}
g02e_t="$src/../../../scheduler/unattended-node-update.md"
if [ -s "$g02e_t" ]; then ok "G02-AC-4 (review-fresh #3): scheduler/unattended-node-update.md found"; else bad "G02-AC-4 (review-fresh #3): scheduler/unattended-node-update.md not found"; fi
# finding 3: only the newest QUESTION/ANSWER pair in answered/ is the owner's decision for this run
if g02e_sent "$u" 'answered/|answer' 'newest|latest|most recent' 'pair' 'decision|approv|count'; then ok "G02-AC-4 (review-fresh #3): the node skill says only the newest answered pair is the owner's decision for this run"; else bad "G02-AC-4 (review-fresh #3): the node skill does not say only the newest answered pair counts as the owner's decision"; fi
if g02e_sent "$u" 'older|earlier|previous' 'pair' 'context' 'not (an )?approv|no approv|never approv|not .*decision|not .*permit'; then ok "G02-AC-4 (review-fresh #3): the node skill says older pairs are context, not approval"; else bad "G02-AC-4 (review-fresh #3): the node skill does not say older pairs are context, not approval"; fi
if g02e_sent "$g02e_t" 'answered/|answer' 'newest|latest|most recent' 'pair' 'decision|approv|count'; then ok "G02-AC-2 (review-fresh #3): the unattended update template says only the newest answered pair is the owner's decision for this run"; else bad "G02-AC-2 (review-fresh #3): the unattended update template does not say only the newest answered pair counts as the owner's decision"; fi
if g02e_sent "$g02e_t" 'older|earlier|previous' 'pair' 'context' 'not (an )?approv|no approv|never approv|not .*decision|not .*permit'; then ok "G02-AC-2 (review-fresh #3): the unattended update template says older pairs are context, not approval"; else bad "G02-AC-2 (review-fresh #3): the unattended update template does not say older pairs are context, not approval"; fi
# finding 4: with --dry-run the whole-node fresh review posts nothing on the PR; its verdict goes into result.md
if g02e_sent "$u" 'fresh review' '--dry-run' 'result\.md' 'verdict' 'not (be )?posted|not post|never posted|posts? nothing|nothing (is )?posted|instead of post|no comment'; then ok "G02-AC-4 (review-fresh #4): with --dry-run the fresh review's verdict goes into result.md and is not posted on the PR"; else bad "G02-AC-4 (review-fresh #4): no sentence says that with --dry-run the fresh review's verdict goes into result.md and is not posted on the PR"; fi

# ---------- G05 slice 2: step 7 and step 6 state the spec-PR scope rule (G05-AC-2) ----------
g05d="$tmp/G05"; mkdir -p "$g05d"
# g05_win <file> <n> <ere>...: some window of <n> consecutive lines matches every ERE (case-insensitive, asterisks dropped).
g05_win() {
	g05_f=$1; g05_n=$2; shift 2
	g05_pats=$(printf '%s\n' "$@")
	awk -v n="$g05_n" -v pats="$g05_pats" '
		BEGIN { k = split(pats, P, "\n") }
		{ gsub(/\*/, ""); L[NR] = tolower($0) }
		END {
			for (i = 1; i <= NR; i++) {
				w = ""; for (j = i; j < i + n && j <= NR; j++) w = w " " L[j]
				good = 1; for (p = 1; p <= k; p++) if (w !~ P[p]) { good = 0; break }
				if (good) exit 0
			}
			exit 1 }' "$g05_f"
}
# g05_sec <skill> <heading-regex> <out>: the lines from the first "## " heading matching the regex to the next "## " heading.
g05_sec() { awk -v re="$2" '/^## / { if (on) exit; if (tolower($0) ~ re) on = 1 } on { print }' "$1" >"$3"; }
g05_sec "$sk" '^## 7[.]' "$g05d/s7.md"
g05_sec "$sk" '^## 6[.]' "$g05d/s6.md"
cat "$g05d/s6.md" "$g05d/s7.md" >"$g05d/s67.md"
g05c() { # g05c <label> <file> <n> <ere>...
	g05_l=$1; g05_ff=$2; g05_nn=$3; shift 3
	if g05_win "$g05_ff" "$g05_nn" "$@"; then ok "$g05_l"; else bad "$g05_l"; fi
}
if [ -s "$g05d/s7.md" ]; then ok "G05-AC-2: SKILL.md has a step 7 section"; else bad "G05-AC-2: SKILL.md has no '## 7.' section"; fi
g05c "G05-AC-2: step 7 says a spec PR changes only the repository's spec files" "$g05d/s7.md" 3 'spec pr' 'only' 'spec files'
g05c "G05-AC-2: step 7 says an approval of a frozen test line or of a file outside the node's Owns is recorded in the answer" "$g05d/s7.md" 6 'approv' 'frozen' 'outside' 'owns' 'record' 'answer'
g05c "G05-AC-2: step 7 says that change is made on the node branch, test-first" "$g05d/s7.md" 6 'approv' 'node branch' 'test-first|test first|tests first'
g05c "G05-AC-2: step 7 says adding a path to the node's own Owns is a small amendment" "$g05d/s7.md" 4 'add' 'path' 'node.s own[^.]*owns|own owns' 'small (spec )?amendment'
g05c "G05-AC-2: step 7 names the checker check-spec-diff.py" "$g05d/s7.md" 40 'check-spec-diff[.]py'
g05c "G05-AC-2: step 7 runs the checker against origin/main before a spec branch is pushed" "$g05d/s7.md" 6 'check-spec-diff' 'origin/main' 'before' 'push'
g05c "G05-AC-2: step 7 stops when the checker exits 1" "$g05d/s7.md" 6 'check-spec-diff' 'exit(s)? (code )?1|exit 1|non-zero' 'stop'
if grep -Eiq 'changes a frozen test still gets its own spec pr' "$g05d/s7.md" || tr -d '*\n' <"$g05d/s7.md" | tr -s ' ' | grep -Eiq 'frozen test[^.]*(still )?(gets|get|goes|go|needs|need)[^.]*(its own|a) spec pr'; then bad "G05-AC-2: step 7 still sends a frozen-test change to a spec PR"; else ok "G05-AC-2: step 7 no longer sends a frozen-test change to a spec PR"; fi
g05c "G05-AC-2: the skill says files outside the spec files that a merged spec PR carried get rows in the evidence table naming that PR" "$g05d/s67.md" 8 'merged spec pr' 'outside' 'spec files' 'row' 'evidence table' 'nam'
g05c "G05-AC-2: the skill gives those files to the fresh reviewer" "$g05d/s67.md" 8 'merged spec pr' 'fresh review'
g05c "G05-AC-2: the skill runs the checker on the merge commit as <sha>^ <sha>" "$sk" 8 'merge commit' 'check-spec-diff' '\^'
g05h=$(sed -e 's#/\{0,1\}noodlebot:[a-z]*##g' -e 's#\.noodlebot/##g' "$sk" | grep -in -e themonolith -e monolith -e tuckermclean -e 'docs/migration' | head -n 3)
if [ -z "$g05h" ]; then ok "G05-AC-2: SKILL.md names no repository (no themonolith, tuckermclean, docs/migration.tsv)"; else bad "G05-AC-2: SKILL.md names a repository: $g05h"; fi

# G06-AC-5: the feedback procedure (section 8) requires the resolution review for a merge of origin/main that had conflicts,
# before any push, and on a second rejection pushes nothing and ends with QUESTION.md. Only section 8's own text counts
# (the update procedure above it already says all of this).
g06d="$tmp/G06"; mkdir -p "$g06d"
g05_sec "$sk" '^## 8[.]' "$g06d/s8.md"
if [ -s "$g06d/s8.md" ]; then ok "G06-AC-5: SKILL.md has a section 8 (the feedback procedure)"; else bad "G06-AC-5: SKILL.md has no '## 8.' section"; fi
g05c "G06-AC-5: section 8 names the resolution review" "$g06d/s8.md" 40 'resolution review'
g05c "G06-AC-5: section 8 requires the resolution review for a merge of origin/main that had conflicts" "$g06d/s8.md" 4 'resolution review' 'merge' 'origin/main' 'conflict'
g05c "G06-AC-5: section 8 requires the resolution review before anything is pushed" "$g06d/s8.md" 5 'resolution review' 'before' 'push'
g05c "G06-AC-5: section 8 says a second rejection pushes nothing and ends with QUESTION.md" "$g06d/s8.md" 4 'second' 'reject' 'push(es)? nothing|nothing is pushed|no push' 'question[.]md'

# R02-AC-1 (review 1): with no environment naming a forge CLI, the skill says how to reach one: scheduler/forge-cli.sh and --repo, close together
r02_forge_win() { # <file> <label>
	if awk '{ L[NR] = $0 } END { for (i = 1; i <= NR; i++) { w = ""; for (j = i; j < i + 6 && j <= NR; j++) w = w " " L[j]; if (w ~ /scheduler\/forge-cli\.sh/ && w ~ /--repo/) exit 0 } exit 1 }' "$1"; then ok "R02-AC-1: $2 SKILL.md says how to reach the forge CLI with no environment naming one (scheduler/forge-cli.sh, --repo)"; else bad "R02-AC-1: $2 SKILL.md does not say how to reach the forge CLI with no environment naming one (needs scheduler/forge-cli.sh and --repo within a few lines)"; fi
}
r02_forge_win "$sk" node


# ---------- A02-AC-5: the deps precondition accepts a dep that is merged, imported or pinned ----------
a02_pre="$tmp/A02-pre.md"
grep -i 'deps' "$sk" | grep -i 'merged' | head -n 1 >"$a02_pre"
if grep -qi 'imported' "$a02_pre"; then ok "A02-AC-5: the deps precondition accepts an imported dep"; else bad "A02-AC-5: the deps precondition does not accept an imported dep"; fi
if grep -qi 'pinned' "$a02_pre"; then ok "A02-AC-5: the deps precondition accepts a pinned dep"; else bad "A02-AC-5: the deps precondition does not accept a pinned dep"; fi
g05c "A02-AC-5: the precondition names merged, imported and pinned deps together and says to stop when one is missing" "$sk" 3 'deps' 'merged' 'imported' 'pinned' 'stop'


# ---------- D09-AC-2: the quick gate runs locally, the whole suite's evidence is the PR's CI run ----------
# The skill's GREEN check (step 3), local runs (step 5), update procedure (its step 4) and feedback procedure (its step 3), and
# the plugin's tester, implementer and reviewer run the quick gate the repository's AGENTS.md names, locally, and take the
# whole suite's evidence from the PR's CI run; no text tells a session to run the whole suite (a bare `make test`, or
# "the repository's test entry point" as what is run). The update section keeps `make test` (G02-AC-4): in the form
# `make test TESTS="<files>"`, which is the quick gate, not the whole suite.
d09="$tmp/D09"; mkdir -p "$d09"
pa="$src/../../agents"
g05_sec "$sk" '^## 3[.]' "$d09/s3.md"
g05_sec "$sk" '^## 5[.]' "$d09/s5.md"
g05_sec "$sk" '^## .*--update' "$d09/upd.md"
g05_sec "$sk" '^## 8[.]' "$d09/s8.md"
# d09_whole <file> <label>: no line runs the whole suite: a bare make test (no TESTS=), or, with <strict> = 1, 'test entry point'.
d09_whole() { # d09_whole <label> <file> <strict>
	d09_hits=$(awk -v strict="$3" '
		{ low = tolower($0); rest = $0; bare = 0
		  if (strict == 1 && low ~ /test entry point/) bare = 1
		  while (match(rest, /make test/)) {
			after = substr(rest, RSTART + RLENGTH)
			if (after !~ /^[ \t]+TESTS=/ && after !~ /^[-A-Za-z0-9_]/) bare = 1
			rest = after
		  }
		  if (bare && low !~ /(never|do not|does not|not run|without|instead)|(^|[^a-z])ci([^a-z]|$)/) print NR ": " $0
		}' "$2")
	if [ -z "$d09_hits" ]; then ok "$1"; else bad "$1 (line $(printf '%s' "$d09_hits" | head -n 1 | cut -c1-120))"; fi
}
for d09s in s3 s5 upd s8; do
	if [ -s "$d09/$d09s.md" ]; then ok "D09-AC-2: section $d09s found"; else bad "D09-AC-2: section $d09s not found"; fi
done
g05c "D09-AC-2: the skill says the quick test gate is the one the repository's AGENTS.md names, run locally" "$sk" 4 'quick (test )?gate' 'agents\.md' 'local'
g05c "D09-AC-2: the skill says the whole suite's evidence is the PR's CI run, recorded in the evidence table" "$sk" 5 'whole suite|whole test suite' 'ci run' 'evidence'
g05c "D09-AC-2: GREEN (step 3) runs the quick gate locally" "$d09/s3.md" 3 'quick (test )?gate' 'local'
g05c "D09-AC-2: GREEN (step 3) takes the whole suite from the PR's CI run" "$d09/s3.md" 5 'whole suite|whole test suite' '(^|[^a-z])ci([^a-z]|$)'
g05c "D09-AC-2: local runs (step 5) run the quick gate the repository's AGENTS.md names" "$d09/s5.md" 4 'local' 'quick (test )?gate' 'agents\.md'
g05c "D09-AC-2: local runs (step 5) leave the whole suite to the PR's CI run" "$d09/s5.md" 5 'whole suite|whole test suite' 'ci run|pr.s ci'
g05c "D09-AC-2: the update procedure runs the quick gate and the red targets" "$d09/upd.md" 5 'quick (test )?gate' 'red target'
g05c "D09-AC-2: the update procedure runs the quick gate for the files the merge touched" "$d09/upd.md" 5 'quick (test )?gate' 'touched|changed'
g05c "D09-AC-2: the update procedure takes the whole suite's result from the PR's CI run after the push, said on the PR" "$d09/upd.md" 6 'whole suite|whole test suite' '(^|[^a-z])ci([^a-z]|$)' 'push|after' 'pr|comment'
g05c "D09-AC-2: the feedback procedure runs the quick gate and the red targets" "$d09/s8.md" 5 'quick (test )?gate' 'red target'
g05c "D09-AC-2: the feedback procedure takes the whole suite's result from the PR's CI run" "$d09/s8.md" 6 'whole suite|whole test suite' '(^|[^a-z])ci([^a-z]|$)'
d09_whole "D09-AC-2: SKILL.md tells no session to run a bare make test (make test TESTS=\"<files>\" is the quick gate)" "$sk" 0
d09_whole "D09-AC-2: the update procedure does not run 'the repository's test entry point' or a bare make test" "$d09/upd.md" 1
d09_whole "D09-AC-2: the feedback procedure does not run 'the repository's test entry point' or a bare make test" "$d09/s8.md" 1
d09_whole "D09-AC-2: GREEN (step 3) runs no whole suite" "$d09/s3.md" 1
d09_whole "D09-AC-2: local runs (step 5) run no whole suite" "$d09/s5.md" 1
for d09a in tester implementer reviewer; do
	if [ -f "$pa/$d09a.md" ]; then
		g05c "D09-AC-2: plugin $d09a names the quick gate" "$pa/$d09a.md" 400 'quick (test )?gate'
		d09_whole "D09-AC-2: plugin $d09a tells no session to run the whole suite" "$pa/$d09a.md" 1
	else bad "D09-AC-2: plugin/agents/$d09a.md is missing"; fi
done
g05c "D09-AC-2: the reviewer's GREEN re-run is the quick gate, and the whole suite's evidence is the PR's CI run" "$pa/reviewer.md" 400 'quick (test )?gate' 'whole suite|whole test suite' '(^|[^a-z])ci([^a-z]|$)'
g05c "D09-AC-2: the tester adds a new test file to the list of test files AGENTS.md names" "$pa/tester.md" 3 'new test file' 'list' 'test files' 'agents\.md'
if grep -Eiq 'wired into the repository.s quick test gate' "$pa/tester.md"; then bad "D09-AC-2: the tester still says a new test file is 'wired into the repository's quick test gate'"; else ok "D09-AC-2: the tester no longer says a new test file is wired into the quick test gate"; fi

# ---------- A05-AC-2 / A05-AC-3: ownership checks, the gate's pass condition, amendments, conflicts, imported tests ----------
# The text of the skill, the plugin agents and the session templates. Each point is checked in each file separately, in the
# paragraph or section it belongs to, so unrelated text elsewhere cannot satisfy it.
a05="$tmp/A05"; mkdir -p "$a05"
a05t="$src/../../../scheduler"
# a05_para <file> <start-ere> <out>: from the first line matching the start up to (not including) the next line that begins
# a new template bullet ("- ") or a marker line ("@").
a05_para() { awk -v re="$2" '!on && $0 ~ re { on = 1; print; next } on && /^(- |@)/ { exit } on { print }' "$1" >"$3"; }
for a05n in 3 5 6 7 8; do g05_sec "$sk" "^## $a05n[.]" "$a05/s$a05n.md"; done
g05_sec "$sk" '^## .*--update' "$a05/upd.md"
a05_para "$a05t/unattended.md" 'SMALL SPEC AMENDMENTS' "$a05/u-small.md"
a05_para "$a05t/unattended-followup.md" 'SMALL SPEC AMENDMENTS' "$a05/f-small.md"
a05_para "$a05t/unattended.md" 'MERGE CONFLICTS' "$a05/u-merge.md"
a05_para "$a05t/unattended-followup.md" 'MERGE CONFLICTS' "$a05/f-merge.md"
a05_para "$a05t/unattended-node-update.md" 'Never change a frozen test' "$a05/nu-spec.md"
for a05f in s3 s5 s6 s7 s8 upd u-small f-small u-merge f-merge nu-spec; do
	if [ -s "$a05/$a05f.md" ]; then ok "A05: text section $a05f found"; else bad "A05: text section $a05f not found"; fi
done
cp "$pa/tester.md" "$a05/tester.md"; cp "$pa/implementer.md" "$a05/implementer.md"; cp "$pa/reviewer.md" "$a05/reviewer.md"
cp "$a05t/unattended-node-update.md" "$a05/nu.md"
cp "$a05t/unattended.md" "$a05/u.md"; cp "$a05t/unattended-followup.md" "$a05/f.md"

# --- A05-AC-2: the two checks before the PR, their evidence, NOT OWNED through the owner's approval ---
g05c "A05-AC-2: the skill (step 6) runs check-owns-diff.py as <ID> origin/main HEAD" "$a05/s6.md" 6 'check-owns-diff[.]py' 'origin/main' 'head' '<id>'
g05c "A05-AC-2: the skill (step 6) runs it in a repository whose graph has owns (ownership)" "$a05/s6.md" 8 'check-owns-diff' 'ownership|owns'
g05c "A05-AC-2: the skill (step 6) runs check-coverage.py at the head and at origin/main" "$a05/s6.md" 6 'check-coverage[.]py' 'origin/main' 'head'
g05c "A05-AC-2: the skill (step 6) counts only the coverage problems at the head that are not at origin/main as the node's" "$a05/s6.md" 8 'check-coverage' 'only' 'problems?' 'not (at|in|on)|new|absent'
g05c "A05-AC-2: the skill (step 6) puts the check-owns-diff output in the criterion -> evidence table" "$a05/s6.md" 8 'check-owns-diff' 'evidence' 'row|table'
g05c "A05-AC-2: the skill (step 6) puts the check-coverage output in the criterion -> evidence table" "$a05/s6.md" 8 'check-coverage' 'evidence' 'row|table'
g05c "A05-AC-2: the skill sends a NOT OWNED path through the owner's approval, asked as a question and recorded in the answer" "$sk" 8 'not owned' 'approv' 'question' 'record' 'answer'
g05c "A05-AC-2: the reviewer names check-owns-diff.py run as <ID> origin/main HEAD" "$a05/reviewer.md" 6 'check-owns-diff[.]py' 'origin/main' 'head'
g05c "A05-AC-2: the reviewer names check-coverage.py at the head and at origin/main" "$a05/reviewer.md" 6 'check-coverage[.]py' 'origin/main' 'head'
g05c "A05-AC-2: the reviewer takes both outputs as evidence" "$a05/reviewer.md" 8 'check-owns-diff' 'check-coverage' 'evidence|output'
g05c "A05-AC-2: the reviewer treats a NOT OWNED path without a recorded approval as a finding" "$a05/reviewer.md" 6 'not owned' 'approv' 'record' 'finding'
g05c "A05-AC-2: the reviewer treats a new coverage problem as a finding" "$a05/reviewer.md" 6 'coverage' 'new' 'problem' 'finding'
g05c "A05-AC-2: the reviewer treats an unmatched failure (a failing line no known_red entry matches) as a finding" "$a05/reviewer.md" 6 'unmatched|no (known_red )?entry|matches? no|not match' 'fail' 'finding'

# --- A05-AC-3: the gate's pass condition, in the skill's steps and in each agent and the update template ---
for a05p in "skill step 3 (GREEN)|$a05/s3.md" "skill step 5 (local runs)|$a05/s5.md" "skill --update step (the failing test)|$a05/upd.md" \
	"skill step 8 (feedback)|$a05/s8.md" "tester|$a05/tester.md" "implementer|$a05/implementer.md" "reviewer|$a05/reviewer.md" \
	"unattended-node-update.md|$a05/nu.md"; do
	a05_who=${a05p%%|*}; a05_f=${a05p#*|}
	g05c "A05-AC-3: $a05_who: a run passes on exit 0, or on a non-zero exit whose fail_pattern lines each contain a known_red entry" "$a05_f" 8 'exit(s)? (code )?0|exits? zero|0 exit' 'fail_pattern' 'known_red' 'each'
	g05c "A05-AC-3: $a05_who: a non-zero exit with no matched line fails" "$a05_f" 8 'known_red' 'non-zero' 'no (matched )?line|no line (is )?matched|matches? no line|without a matched line' 'fail'
	g05c "A05-AC-3: $a05_who: the evidence lists each failing line with the known_red entry it matched" "$a05_f" 8 'evidence|list' 'each' 'failing line|matched line|line' 'known_red|entry' 'match'
done
g05c "A05-AC-3: the skill applies the pass condition to the local quick gate and the CI run of gate.command alike" "$sk" 10 'known_red' 'quick gate' 'ci run' 'gate[.]command' 'alike|both|same'
g05c "A05-AC-3: the skill requires no local run of gate.command" "$sk" 10 'gate[.]command' 'no local run|not (require|run|make)[^.]*local|without[^.]*local|never[^.]*local' 
g05c "A05-AC-3: the reviewer applies the pass condition to the quick gate and the CI run of gate.command alike, with no local run required" "$a05/reviewer.md" 10 'known_red' 'quick gate' 'ci' 'gate[.]command' 'no local run|not (require|run|make)[^.]*local|without[^.]*local|never[^.]*local'
g05c "A05-AC-3: unattended-node-update.md applies the pass condition to the quick gate and the CI run of gate.command, with no local run required" "$a05/nu.md" 10 'known_red' 'quick gate' 'ci' 'gate[.]command' 'no local run|not (require|run|make)[^.]*local|without[^.]*local|never[^.]*local'

# --- A05-AC-3: the amendments of change 3 ---
for a05p in "skill step 7|$a05/s7.md" "unattended.md SMALL SPEC AMENDMENTS|$a05/u-small.md" "unattended-followup.md SMALL SPEC AMENDMENTS|$a05/f-small.md"; do
	a05_who=${a05p%%|*}; a05_f=${a05p#*|}
	g05c "A05-AC-3: $a05_who: adding, correcting or removing a glob of the node's own owns is a small amendment" "$a05_f" 8 'glob' 'owns' 'add' 'correct' 'remov' 'amendment'
	g05c "A05-AC-3: $a05_who: an added own glob only for paths no other node's glob and no out_of_scope glob matches" "$a05_f" 8 'glob' 'only' 'out[_ -]of[_ -]scope' 'no other|no existing|not match|matches? none|matches? no'
	g05c "A05-AC-3: $a05_who: removing a known_red entry the change makes pass is a small amendment" "$a05_f" 8 'known_red' 'remov' 'pass' 'amendment'
	g05c "A05-AC-3: $a05_who: removing a dep's glob the change leaves matching nothing, unless it is the dep's last glob" "$a05_f" 8 'dep' 'glob' 'remov' 'matching nothing|matches nothing|match(es)? no' 'last'
done

# --- A05-AC-3: conflict resolution of those lines ---
for a05p in "skill --update step|$a05/upd.md" "unattended-node-update.md spec-file rule|$a05/nu-spec.md" \
	"unattended.md MERGE CONFLICTS|$a05/u-merge.md" "unattended-followup.md MERGE CONFLICTS|$a05/f-merge.md"; do
	a05_who=${a05p%%|*}; a05_f=${a05p#*|}
	g05c "A05-AC-3: $a05_who: a conflict in owns globs or known_red entries applies both sides' changes, each line taking the side that changed it" "$a05_f" 8 'known_red' 'glob|owns' 'both sides' 'each line' 'side that changed'
	g05c "A05-AC-3: $a05_who: that resolution needs no question" "$a05_f" 8 'known_red' 'both sides' 'without a question|no question|needs no question|not a question'
	g05c "A05-AC-3: $a05_who: a line both sides changed is not resolved: QUESTION.md is written" "$a05_f" 8 'known_red' 'both sides changed' 'same' 'question[.]md'
done

# --- A05-AC-3: the tests an imported or pinned node's criteria name are frozen ---
for a05p in "skill|$sk" "tester|$a05/tester.md" "implementer|$a05/implementer.md" "reviewer|$a05/reviewer.md" \
	"unattended.md|$a05/u.md" "unattended-followup.md|$a05/f.md" "unattended-node-update.md|$a05/nu.md"; do
	a05_who=${a05p%%|*}; a05_f=${a05p#*|}
	g05c "A05-AC-3: $a05_who: the tests an imported or pinned node's criteria name in their Verify are frozen like an earlier node's" "$a05_f" 6 'imported' 'pinned' 'verify' 'frozen' 'criteri'
done

# ---------- A08-AC-1 / A08-AC-2 / A08-AC-3: pin commits, their checks, the dep amendments and their conflict resolution ----------
# Text checks. Each point is checked in the file or section it belongs to (the skill's steps and --update section, the agents,
# the templates' SMALL SPEC AMENDMENTS and MERGE CONFLICTS paragraphs, the update template's spec-file rule); the patterns avoid
# backslashes so they mean the same to gawk and mawk. Reuses the section files of the A05 block above.
g08="$tmp/A08"; mkdir -p "$g08"
g08c() { # g08c <label> <file> <n> <ere>...
	g08_l=$1; g08_f=$2; g08_n=$3; shift 3
	if g02_win "$g08_f" "$g08_n" "$@"; then ok "$g08_l"; else bad "$g08_l"; fi
}
cp "$sk" "$g08/skill.md"

# --- A08-AC-1: which criteria are pinned or superseded, and what a pin commit contains ---
for g08p in "skill|$g08/skill.md" "tester|$a05/tester.md"; do
	g08_who=${g08p%%|*}; g08_f=${g08p#*|}
	g08c "A08-AC-1: the $g08_who: a pin is for an unpinned criterion of an imported dep whose behaviour the node relies on" "$g08_f" 8 'unpinned' 'criteri' 'imported' 'dep'
	g08c "A08-AC-1: the $g08_who: a criterion whose behaviour the node keeps is pinned, one it changes is superseded and not pinned" "$g08_f" 8 'keeps?|kept' 'pinned' 'superseded' 'chang'
	g08c "A08-AC-1: the $g08_who: a superseded criterion's frozen test is changed only with the owner's approval" "$g08_f" 8 'superseded' 'frozen' 'test' 'only' 'approv' 'owner'
	g08c "A08-AC-1: the $g08_who: a pin passes when written, so it is not a RED commit but a pin(<ID>): commit" "$g08_f" 8 'pin[(]<id>[)]:' 'pass' 'red'
	g08c "A08-AC-1: the $g08_who: a pin(<ID>): commit touches test and fixture paths only" "$g08_f" 8 'pin[(]<id>[)]:' 'test' 'fixture' 'paths?' 'only'
	g08c "A08-AC-1: the $g08_who: a pin(<ID>): commit carries a Pin-Mutation: trailer naming each pinned criterion" "$g08_f" 8 'pin[(]<id>[)]:' 'pin-mutation:' 'trailer' 'each|every|per' 'criterion'
	g08c "A08-AC-1: the $g08_who: each mutation is returned as a diff, the code is not edited" "$g08_f" 8 'mutation' 'diff' 'return' 'not edit|never edit|no edit|without edit|does not (change|modify)|not (change|modify)'
	g08c "A08-AC-1: the $g08_who: the Pin-Mutation trailer names the path, what is broken and the case that fails" "$g08_f" 8 'pin-mutation: <dep>-ac-<n>' 'path' 'broken' 'fails?'
done
g08c "A08-AC-1: the skill pins before the node's first RED commit, in a repository whose graph has imported nodes" "$g08/skill.md" 8 'pin' 'before' 'first red' 'imported'
g08c "A08-AC-1: the skill takes the criteria from the node's Changes and the deps' owns" "$g08/skill.md" 8 'unpinned' 'changes' 'owns' 'touch'

# --- A08-AC-2: the three-run check, its patch and log, frozen pin lines, the reviewer ---
g08c "A08-AC-2: the skill has the orchestrator write each mutation to out/node/<ID>/pin-<n>.patch" "$g08/skill.md" 8 'orchestrator' 'mutation' 'out/node/<id>/pin-<n>[.]patch'
g08c "A08-AC-2: the skill keeps the three runs as out/node/<ID>/pin-<n>.log" "$g08/skill.md" 8 'three|3' 'runs' 'out/node/<id>/pin-<n>[.]log'
g08c "A08-AC-2: the three runs: the pinned cases pass at the pin commit, the named case fails with the patch applied, they pass again with it reverted" "$g08/skill.md" 10 'pin commit' 'pass' 'patch' 'appl' 'fail' 'revert' 'again'
g08c "A08-AC-2: a pin that passes with its mutation applied goes back to a new tester" "$g08/skill.md" 8 'pin' 'pass' 'mutation|patch' 'appl' 'new tester'
g08c "A08-AC-2: the skill says a pin's test lines are frozen like a RED commit's: cases may be added, none changed or removed without the owner's approval" "$g08/skill.md" 8 'pin(.s)? (test )?lines|pin commit' 'frozen' 'like' 'red' 'add' 'never|not' 'approv'
g08c "A08-AC-2: the skill puts the pin check's patch and log in the criterion -> evidence table" "$g08/skill.md" 8 'pin-<n>|pin check|pin commit' 'evidence' 'row|table' 'patch' 'log'
g08c "A08-AC-2: the reviewer checks each pin commit's paths and Pin-Mutation trailers" "$a05/reviewer.md" 8 'pin[(]<id>[)]' 'path' 'trailer' 'pin-mutation'
g08c "A08-AC-2: the reviewer checks the pin patches and logs (the three runs)" "$a05/reviewer.md" 8 'pin' 'patch' 'log' 'three|3|runs'
g08c "A08-AC-2: the reviewer checks the pinned and superseded choices" "$a05/reviewer.md" 8 'pinned' 'superseded' 'choice|chose|choos|judg'
g08c "A08-AC-2: the reviewer checks that pin lines stay frozen like RED lines, a changed or removed one is a finding" "$a05/reviewer.md" 8 'pin(.s)? (test )?lines|pin commit' 'frozen' 'red' 'finding'
g08c "A08-AC-2: the reviewer checks the dep amendments (the pin named, superseded, pinned status)" "$a05/reviewer.md" 8 'dep' 'amendment' 'superseded' 'pinned'
g08c "A08-AC-2: the reviewer reads each mutation with its failing case" "$a05/reviewer.md" 8 'mutation' 'fail' 'case'

# --- A08-AC-3: the dep amendments are small amendments, and their conflict resolution ---
for g08p in "skill step 7|$a05/s7.md" "unattended.md SMALL SPEC AMENDMENTS|$a05/u-small.md" "unattended-followup.md SMALL SPEC AMENDMENTS|$a05/f-small.md"; do
	g08_who=${g08p%%|*}; g08_f=${g08p#*|}
	g08c "A08-AC-3: $g08_who: naming the pin's test in a dep's unpinned criterion is a small amendment" "$g08_f" 8 'dep' 'criterion' 'unpinned' 'pin' 'amendment'
	g08c "A08-AC-3: $g08_who: marking a changed dep criterion's Verify 'superseded by <ID>-AC-<n>' is a small amendment" "$g08_f" 8 'dep' 'verify' 'superseded by <id>-ac-<n>' 'amendment'
	g08c "A08-AC-3: $g08_who: setting the dep's status to pinned when no unpinned criterion is left is a small amendment" "$g08_f" 8 'dep' 'status' 'pinned' 'unpinned' 'left|remain' 'amendment'
done
for g08p in "skill --update step|$a05/upd.md" "unattended-node-update.md spec-file rule|$a05/nu-spec.md" \
	"unattended.md MERGE CONFLICTS|$a05/u-merge.md" "unattended-followup.md MERGE CONFLICTS|$a05/f-merge.md"; do
	g08_who=${g08p%%|*}; g08_f=${g08p#*|}
	g08c "A08-AC-3: $g08_who: a conflict in the pin, superseded or status lines applies both sides' changes, each line taking the side that changed it" "$g08_f" 10 'unpinned|superseded' 'verify|criteri' 'status' 'both sides' 'each line' 'side that changed'
	g08c "A08-AC-3: $g08_who: after the resolution the dep is set pinned when no unpinned criterion is left, even when neither side set it" "$g08_f" 10 'status' 'pinned' 'unpinned' 'after' 'resol' 'left|remain' 'neither'
	g08c "A08-AC-3: $g08_who: when both sides change the same criterion's Verify or set the same dep's status differently, QUESTION.md is written" "$g08_f" 10 'both sides' 'same' 'verify' 'status' 'differently' 'question[.]md'
done

# --- A08 strict cases (fresh-review findings 1-6): each is tied to text only the A08 clause has, in a 1-2 line window ---
# finding 1: the both-sides resolution of the dep amendments, with the wording of that clause (not A05's owns/known_red sentence)
g08c "A08-AC-3 strict: skill --update step: the dep amendments' conflict (superseded by <ID>-AC-<n>) is resolved by applying both sides' changes, each line taking the side that changed it, with no question" "$a05/upd.md" 1 'superseded by <id>-ac-<n>' 'resolved the same way: apply both sides. changes, each line taking the side that changed it, with no question'
for g08p in "unattended-node-update.md spec-file rule|$a05/nu-spec.md" "unattended.md MERGE CONFLICTS|$a05/u-merge.md" "unattended-followup.md MERGE CONFLICTS|$a05/f-merge.md"; do
	g08_who=${g08p%%|*}; g08_f=${g08p#*|}
	g08c "A08-AC-3 strict: $g08_who: the dep amendments' conflict (superseded by <ID>-AC-<n>) is resolved by applying both sides' changes, each line taking the side that changed it, with no question" "$g08_f" 1 'superseded by <id>-ac-<n>' 'status.{1,4} apply both sides. changes, each line taking the side that changed it, with no question'
done
# finding 2: both sides changing the same criterion's Verify or setting the dep's status differently is a QUESTION
for g08p in "skill --update step|$a05/upd.md" "unattended-node-update.md spec-file rule|$a05/nu-spec.md" \
	"unattended.md MERGE CONFLICTS|$a05/u-merge.md" "unattended-followup.md MERGE CONFLICTS|$a05/f-merge.md"; do
	g08_who=${g08p%%|*}; g08_f=${g08p#*|}
	g08c "A08-AC-3 strict: $g08_who: both sides changing the same criterion's Verify or setting the same dep's status differently is not resolved, QUESTION.md is written" "$g08_f" 1 'same criterion.s .{0,2}verify.{0,2} or set the same dep.s .status. differently' 'not resolved' 'question[.]md'
done
# finding 3: naming the pin's test in place of unpinned is a small amendment
for g08p in "skill step 7|$a05/s7.md" "unattended.md SMALL SPEC AMENDMENTS|$a05/u-small.md" "unattended-followup.md SMALL SPEC AMENDMENTS|$a05/f-small.md"; do
	g08_who=${g08p%%|*}; g08_f=${g08p#*|}
	g08c "A08-AC-3 strict: $g08_who: replacing 'unpinned' in a pinned dep criterion with the pin's test is a small amendment" "$g08_f" 2 'replacing .unpinned. in a pinned dep criterion with the pin.s test' 'small amendment'
done
# finding 4: the reviewer's three runs and frozen pin lines
g08c "A08-AC-2 strict: the reviewer checks pin-<n>.log: pass at the pin commit, the named case fails with the patch applied, they pass again with it reverted" "$a05/reviewer.md" 1 'pin-<n>[.]log.{1,3}: the three runs show the pinned cases pass at the pin commit, the named case fails with the patch applied and they pass again with it reverted'
g08c "A08-AC-2 strict: the reviewer: a pin's test lines are frozen like RED lines, a changed or removed one without the owner's recorded approval is a finding" "$a05/reviewer.md" 1 'pin.s test lines are frozen like red lines' 'changed or removed one without the owner.s recorded approval is a finding'
# finding 5: the skill's own frozen pin lines sentence
g08c "A08-AC-2 strict: the skill: a pin's test lines are frozen like a RED commit's, a later commit may add cases, never change or remove one without the owner's approval" "$g08/skill.md" 1 'pin.s test lines are frozen like a red commit.s: a later commit may add cases, never change or remove one without the owner.s approval'
# finding 6: the tester's keeps/pinned bullet
g08c "A08-AC-1 strict: the tester: a criterion whose behaviour the node keeps is pinned, with a test that passes today" "$a05/tester.md" 1 'a criterion whose behaviour the node keeps is pinned: write a test that passes today'

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
