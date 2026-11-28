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

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
