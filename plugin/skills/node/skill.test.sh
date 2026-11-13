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
if grep -o 'gh [^`]*' "$d/skill.stripped" | tr -s ' ' '\n' | grep -Eq '^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+(#[0-9]+)?$'; then bad "G02-AC-4: a gh command in SKILL.md carries an owner/name slug"; else ok "G02-AC-4: no gh command in SKILL.md carries an owner/name slug"; fi
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
if printf '%s\n' "$g02d_pv" | grep -Eq 'posted on the pr|gh pr comment'; then ok "G02-AC-5: the sentence with 'Resolution review (' says the verdict is posted on the PR"; else bad "G02-AC-5: the sentence with 'Resolution review (' ('${g02d_pv:-none}') must say the verdict is posted on the PR (gh pr comment)"; fi
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

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
