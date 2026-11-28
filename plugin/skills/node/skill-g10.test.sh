#!/bin/sh
# Tests G10-AC-3: plugin/skills/node/SKILL.md says (next to the `branch push` line) that a branch a criterion pushes only
# to start a CI run, never as a PR's head, is named ci-probe/<ID>-<topic>; that once its run is recorded in the evidence the
# session deletes it with `<forge> branch delete --branch <name>`; that a session of the node (a build, an update or a
# feedback session) also deletes each ci-probe/<ID>-* branch its PR's evidence names that is still on the forge; and that
# a deletion the forge refuses is recorded in the PR next to the branch's name and does not stop the session.
# One statement within one sentence per case, over the whole of SKILL.md. A sentence is cut at ". " (emphasis and
# backticks removed, lower-cased, so <ID> reads <id>); a case passes when one sentence matches every pattern; a pattern
# starting with "!" must not match that sentence. Key words each case needs in one sentence:
#   case 1  ci-probe/<ID>-<topic>, "name", "CI run", "only", "never" and a PR's head ("PR's head", "head of a PR",
#           "heads a PR"), and not "not named"
#   case 2  "delete", "branch delete --branch", "recorded", "evidence", "once" (or "after", "when", "as soon as") before
#           "recorded", no "not/never/without delet"
#   case 3  "session", "node", "delet", ci-probe/<ID>-*, "evidence", "on the forge", "build", "update", "feedback",
#           no "not/never delet"
#   case 4  "refus", "delet", "recorded", "in the PR", "next to" (or beside, alongside, with) "branch's name" (or "name of
#           the branch", "its name"); case 5 (the same sentence or another): "refus", "delet", "session" and "does not
#           stop" (or "not stop", "never stop", "without stopping", "not block")
# No forge name is used. G10_ROOT (default: this checkout) names the tree whose SKILL.md is read; the test only reads.
#   sh plugin/skills/node/skill-g10.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
root=${G10_ROOT:-$(cd "$src/../../.." && pwd -P)}
sk="$root/plugin/skills/node/SKILL.md"
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
d="$tmp/G10"; mkdir -p "$d"
fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# g10_sen <label> <file> <ere>...: one sentence of the file matches every ERE (a leading "!" negates). An empty or
# missing file fails.
g10_sen() {
	s_l=$1; s_f=$2; shift 2
	s_pats=$(printf '%s\n' "$@")
	if [ -s "$s_f" ] && awk -v pats="$s_pats" '
		BEGIN { k = split(pats, P, "\n") }
		{ gsub(/[*`]/, ""); t = t " " tolower($0) }
		END {
			gsub(/e[.]g[.]/, "for example", t); gsub(/i[.]e[.]/, "that is", t)
			n = split(t, S, /[.] /)
			for (i = 1; i <= n; i++) {
				s = S[i]
				good = 1
				for (p = 1; p <= k; p++) {
					if (substr(P[p], 1, 1) == "!") { if (s ~ substr(P[p], 2)) { good = 0; break } }
					else if (s !~ P[p]) { good = 0; break }
				}
				if (good) exit 0
			}
			exit 1 }' "$s_f"; then ok "$s_l"; else bad "$s_l"; fi
}

if [ ! -f "$sk" ]; then bad "G10-AC-3: plugin/skills/node/SKILL.md is missing"; echo "$fails failed"; exit 1; fi
cp "$sk" "$d/skill.md"

g10_sen "G10-AC-3: a branch a criterion pushes only to start a CI run, never a PR's head, is named ci-probe/<ID>-<topic>" "$d/skill.md" \
	'ci-probe/<id>-<topic>' 'name' 'ci run' 'only' "never [a-z ]*(pr.s head|head of a pr)|never heads a pr" '!(not|never) named'
g10_sen "G10-AC-3: once its run is recorded in the evidence the session deletes it with <forge> branch delete --branch <name>" "$d/skill.md" \
	'delete' 'branch delete --branch' 'evidence' '(once|after|when|as soon as) [a-z ]*recorded' '!(not|never|without) delet' '!(does|do|did) not delet'
g10_sen "G10-AC-3: a session of the node (build, update or feedback) also deletes each ci-probe/<ID>-* branch its PR's evidence names that is still on the forge" "$d/skill.md" \
	'session' 'node' 'delet' 'ci-probe/<id>-' 'evidence' 'on the forge' 'build' 'update' 'feedback' '!(not|never|without) delet' '!(does|do|did) not delet'
g10_sen "G10-AC-3: a deletion the forge refuses is recorded in the PR next to the branch's name" "$d/skill.md" \
	'refus' 'delet' 'recorded' 'in the pr' '(next to|beside|alongside|with) [a-z ]*(branch.s name|name of the branch|its name)' '!not recorded' '!(never|without) record'
g10_sen "G10-AC-3: a refused deletion does not stop the session" "$d/skill.md" \
	'refus' 'delet' 'session' '(does|do) not (stop|block|halt|abort)|not stop|never stop|without stopping|not block' '!(and|which|so|then) stops? the session'

# Round 2: the reversals the slice review found must fail too.
g10_sen "G10-AC-3: it is the session that deletes the recorded ci-probe branch with branch delete --branch, not the owner, not 'may'" "$d/skill.md" \
	'session (deletes|will delete|must delete)' 'branch delete --branch' 'recorded' '!(owner|asked to|may delete|can delete|might delete)'
g10_sen "G10-AC-3: the sessions that also delete a node's leftover ci-probe branches are a build, an update and a feedback session" "$d/skill.md" \
	'a build, an update,? (or|and) a feedback session' 'also delet' 'ci-probe/<id>-' '!not an? (update|feedback)' '!only' '!(not|never|without) delet' '!(does|do|did) not delet'
g10_sen "G10-AC-3: the leftover branches deleted are those still on the forge" "$d/skill.md" \
	'still on the forge' 'ci-probe/<id>-' 'evidence' 'delet' '!(no longer|not) on the forge'
g10_sen "G10-AC-3: the forge is the one that refuses the deletion" "$d/skill.md" \
	'(the forge refuses|refused by the forge|forge refuses)' 'delet' 'recorded' '!owner refuses' '!owner refused'
g10_sen "G10-AC-3: the branch named ci-probe/<ID>-<topic> is one a criterion pushes" "$d/skill.md" \
	'(a|the) criterion pushes' 'ci-probe/<id>-<topic>' '!owner pushes'
g10_sen "G10-AC-3: with --dry-run nothing is deleted and the branches it would delete go in result.md" "$d/skill.md" \
	'--dry-run' '(deletes no|delete no|nothing is deleted|no branch is deleted|no branch delete|not delete|no deletion)' 'would delete' 'result[.]md' '!(with|under) --dry-run[^,:]* deletes (the|each|every|it)'

# Round 3: mutants of the throwaway-branch paragraph the second review found still passing.
g10_sen "G10-AC-3: the leftover ci-probe branches deleted are those its PR's evidence names" "$d/skill.md" \
	'ci-probe/<id>-' 'pr.s evidence (names|lists)' 'delet' '!evidence (does not|doesn.t|never) (name|list)' '!(not|never) named'
g10_sen "G10-AC-3: the dry-run rule applies with --dry-run, not without it or in a build session" "$d/skill.md" \
	'(^| )with --dry-run the session' 'deletes no branch' '!(without|unless|even without) --dry-run' '!--dry-run (or|and) '
g10_sen "G10-AC-3: the session that deletes the leftovers is a session of the node, not of another node" "$d/skill.md" \
	'a session of the node' 'also delet' 'ci-probe/<id>-' '!(another|other) node'
g10_sen "G10-AC-3: a refused deletion is recorded in the PR, not only in the log" "$d/skill.md" \
	'refus' 'recorded in the pr' '!not in the pr' '!(in|to) the log' '!owner'
g10_sen "G10-AC-3: the refusal does not stop the session, and nothing else stops it" "$d/skill.md" \
	'refus' 'does not stop the session' '!refusal stops' '!though' '!owner'
g10_sen "G10-AC-3: the leftovers are branches still on the forge, with no owner condition" "$d/skill.md" \
	'still on the forge' 'ci-probe/<id>-' '!owner' '!(if|unless) '

# Strengthening: an added condition on the probe-deletion sentence ("unless ...", "after the PR merges") must fail.
g10_sen "G10-AC-3: the probe deletion after its run is recorded has no added condition (no if/unless, no merge)" "$d/skill.md" \
	'branch delete --branch' 'recorded' '!(if|unless) ' '!(merge|merged|merges)'

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
