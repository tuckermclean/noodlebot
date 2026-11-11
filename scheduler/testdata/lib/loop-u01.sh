# The U01-AC-8 checks on the rendered prompts and the skills (source after loop-prelude.sh).
# u01chk <name> <command...>: PASS when the command succeeds.
u01chk() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
# u01_sentences <file>: the text one sentence per line (split at ". " and "; ").
u01_sentences() { tr '\n' ' ' <"$1" | sed 's/[.;] /&\n/g'; }
# u01_affirmed <file>: the sentences that carry no negation (never, not, no, none, without, n't).
u01_affirmed() { u01_sentences "$1" | grep -ivE "\b(never|not|no|none|without)\b|n't"; }
# u01_closes <file>: an affirmed sentence with a closing keyword followed by an issue number
# (the keyword, an optional colon, a space or backtick, then #).
u01_closes() { u01_affirmed "$1" | grep -qiE "\b(close[sd]?|fix(es|ed)?|resolve[sd]?):? *[\`\"']?#"; }
# u01_refs_resolves <file>: a sentence about the Resolves line that says Refs #N.
u01_refs_resolves() { u01_affirmed "$1" | grep -i 'Resolves' | grep -qF 'Refs #N'; }
# u01_answers_on_unit <file>: the Change 7 sentence, whole.
u01_answers_on_unit() { grep -qF "To answer: reply on this unit's issue (the loop posts the question there)." "$1"; }
# u01_names_status <file>: the prompt names the status issue or an ID prefix for answering.
u01_names_status() { grep -qiE "status issue|id prefix|prefix|starting with .?#[0-9A-Za-z@]" "$1"; }
# u01_selftest: each pattern must match its sample and miss its counter-sample.
u01_selftest() {
u01_s=$tmp/u01-sample; mkdir -p "$u01_s"
printf '%s\n' 'the PR body says "Fixes #N" for each issue on it, so GitHub closes them.' >"$u01_s/c1"
printf '%s\n' 'Put `Fixes #12` in the PR.' >"$u01_s/c2"
printf '%s\n' 'Never write Fixes #N; write Refs #N instead.' >"$u01_s/n1"
printf '%s\n' 'Write "issue #N" or "Refs #N", and no closing keyword.' >"$u01_s/n2"
printf '%s\n' 'reply on the status issue starting with `#46:`.' >"$u01_s/s1"
printf '%s\n' 'start the reply with the ID prefix.' >"$u01_s/s2"
printf '%s\n' 'reply on this unit issue.' >"$u01_s/s3"
printf '%s\n' 'If the node has a **Resolves:** line, the PR body says "Refs #N" for each issue on it.' >"$u01_s/r1"
printf '%s\n' 'If an issue is not resolved, write "Refs #N" instead.' >"$u01_s/r2"
printf '%s\n' 'Write "issue #N" or "Refs #N", and never quote a spec Resolves: line next to its number.' >"$u01_s/r3"
u01chk "U01-AC-8 (pattern check): a closing keyword before a number is found, also in backticks" sh -c "$(declare -f u01_sentences u01_affirmed u01_closes); u01_closes '$u01_s/c1' && u01_closes '$u01_s/c2'"
u01chk "U01-AC-8 (pattern check): a negated sentence and Refs #N are not taken for a closing keyword" sh -c "$(declare -f u01_sentences u01_affirmed u01_closes); ! u01_closes '$u01_s/n1' && ! u01_closes '$u01_s/n2'"
u01chk "U01-AC-8 (pattern check): the status issue and an ID prefix are found, a unit's issue is not" sh -c "$(declare -f u01_names_status); u01_names_status '$u01_s/s1' && u01_names_status '$u01_s/s2' && ! u01_names_status '$u01_s/s3'"
u01chk "U01-AC-8 (pattern check): Refs #N must be in a sentence about the Resolves line" sh -c "$(declare -f u01_sentences u01_affirmed u01_refs_resolves); u01_refs_resolves '$u01_s/r1' && ! u01_refs_resolves '$u01_s/r2' && ! u01_refs_resolves '$u01_s/r3'"
}
# u01_prompt_checks <kind> <rendered prompt file>
u01_prompt_checks() {
	local u01_n=$1 u01_f=$2
	u01chk "U01-AC-8: the rendered $u01_n prompt exists, filled in" sh -c "[ -s '$u01_f' ] && ! grep -qE '@[A-Z]+@' '$u01_f'"
	u01chk "U01-AC-8: the rendered $u01_n prompt ends a QUESTION.md with \"To answer: reply on this unit's issue (the loop posts the question there).\"" sh -c "$(declare -f u01_answers_on_unit); [ -s '$u01_f' ] && u01_answers_on_unit '$u01_f'"
	u01chk "U01-AC-8: the rendered $u01_n prompt names neither the status issue nor an ID prefix for answering" sh -c "$(declare -f u01_names_status); [ -s '$u01_f' ] && ! u01_names_status '$u01_f'"
}
# u01_pr_checks <kind> <rendered prompt file>
u01_pr_checks() {
	local u01_n=$1 u01_f=$2
	u01chk "U01-AC-8: the rendered $u01_n prompt has the PR body name the Resolves issues as \"Refs #N\"" sh -c "$(declare -f u01_sentences u01_affirmed u01_refs_resolves); [ -s '$u01_f' ] && u01_refs_resolves '$u01_f'"
	u01chk "U01-AC-8: the rendered $u01_n prompt has no instruction to write \"Fixes #N\" (or another closing keyword before an issue)" sh -c "$(declare -f u01_sentences u01_affirmed u01_closes); [ -s '$u01_f' ] && ! u01_closes '$u01_f'"
}
# u01_skill_checks: the triage and adopt skills
u01_skill_checks() {
	local u01_sk
	for u01_sk in triage adopt; do
		u01chk "U01-AC-8: the $u01_sk skill has no instruction to write a closing keyword before an issue" sh -c "$(declare -f u01_sentences u01_affirmed u01_closes); [ -s '$src/../plugin/skills/$u01_sk/SKILL.md' ] && ! u01_closes '$src/../plugin/skills/$u01_sk/SKILL.md'"
	done
}
