# Shared by loop-R02*.test.sh (source after loop-prelude.sh): the R02-AC-1 checks on the prompts a loop renders.
# A prompt is the file the loop writes (state/.../unattended.md, or resume-prompt.md for a limit resume). Every rendered
# prompt must tell the session to reach the forge through NOODLEBOT_FORGE and hold no gh command, no github.com URL and no
# token command; it keeps the rules its template carries today: the questions rule (QUESTION.md), the closing-keyword
# rule, never merging or approving, and the signature. The fixture's forge links (feedback item URLs, the signature's
# commit link) are data: the fixtures here give them a host that is not GitHub, so no line of a prompt is exempt.
#
#   r02_sig <nb dir>        the signature line the loop under <nb dir> renders for @SIGNATURE@
#   r02_prompt <kind> <file> <rules>   one PASS/FAIL line per check; <rules> is a comma list of
#                           questions (the QUESTION.md rule), closing, merge, sig; "-" for none
#   r02_skill <kind> <file> <cmd>      the prompt names the harness's skill command <cmd> and no /noodlebot: command
# A prompt that was never rendered fails each of its checks on its own line.
r02_gh_re='(?<![\w./$\-])gh(?![\w\-])'   # a standalone word gh: scan3's rule in scheduler/agnostic.test.sh (the R02 block)
r02_sig() { sh "$1/scheduler/version.sh" --signature "$1" 2>/dev/null; }
r02_flat() { tr '\n' ' ' <"$1" | tr -s ' '; }
r02_check() { # <name> <file> <test command...>: PASS when the file is there and the command succeeds
	local name=$1 f=$2; shift 2
	if [ -s "$f" ] && "$@"; then pass "$name"; else fail "$name"; fi
}
r02_has() { grep -qF -- "$2" "$1"; }
r02_lacks() { ! grep -qF -- "$2" "$1"; }
r02_nogh() { ! grep -qP "$r02_gh_re" "$1"; }
r02_filled() { ! grep -qE '@[A-Z]+@' "$1"; }
r02_notoken() { ! grep -qE 'GH_TOKEN|GIT_TOKEN|config/noodlebot/token' "$1"; }
r02_closing() { r02_flat_re "$1" 'closing keyword' && grep -qF 'Refs #N' "$1"; }
r02_merge() { r02_flat_re "$1" 'never merge[^.]{0,60}approve|never approve[^.]{0,60}merge'; }
r02_flat_re() { r02_flat "$1" | grep -Eiq -- "$2"; }
r02_prompt() {
	local kind=$1 f=$2 rules=$3 sig r
	r02_check "R02-AC-1 ($kind): the prompt is rendered, with no @NAME@ left in it" "$f" r02_filled "$f"
	r02_check "R02-AC-1 ($kind): it tells the session to reach the forge through NOODLEBOT_FORGE" "$f" r02_has "$f" NOODLEBOT_FORGE
	r02_check "R02-AC-1 ($kind): it holds no gh command" "$f" r02_nogh "$f"
	r02_check "R02-AC-1 ($kind): it holds no github.com URL" "$f" r02_lacks "$f" github.com
	r02_check "R02-AC-1 ($kind): it holds no token command (GH_TOKEN, the token script): the forge CLI fetches credentials itself" "$f" r02_notoken "$f"
	for r in $(echo "$rules" | tr , ' '); do
		case $r in
		questions) r02_check "R02-AC-1 ($kind): it keeps the questions rule (QUESTION.md)" "$f" r02_has "$f" QUESTION.md ;;
		closing) r02_check "R02-AC-1 ($kind): it keeps the closing-keyword rule (a closing keyword, Refs #N)" "$f" r02_closing "$f" ;;
		merge) r02_check "R02-AC-1 ($kind): it keeps never merging or approving" "$f" r02_merge "$f" ;;
		sig) sig=$(r02_sig "${r02_nb:-$nb}")
			r02_check "R02-AC-1 ($kind): it keeps the signature (the rendered @SIGNATURE@ value: $sig)" "$f" r02_has "$f" "$sig" ;;
		esac
	done
}
r02_skill() { # <kind> <file> <command>
	local kind=$1 f=$2 cmd=$3
	r02_check "R02-AC-1 ($kind): its skill command is the harness's (skill-command gave '$cmd')" "$f" r02_has "$f" "$cmd"
	r02_check "R02-AC-1 ($kind): it holds no hard-coded /noodlebot: skill command" "$f" r02_lacks "$f" /noodlebot:
}
