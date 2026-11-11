#!/bin/bash
# G03: owner feedback on a bot's node PR, follow-up PR and spec PR starts one session each; the rendered prompt. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "G03 setup: the first tick records the open PRs' feedback" g03_first
wait_ticks 2
ok "G03-AC-3: a tick with no new feedback starts nothing" test ! -s "$GD/claude.log"
# items that are not feedback: another user's comment, a thumbs-up, an approval, and the owner's comment on a human's PR
fbadd 11 conversation 111 'thanks' login=x
fbadd 11 conversation 112 ':+1:'
fbadd 11 review 113 '' state=APPROVED
fbadd 14 conversation 114 'please change this'
wait_ticks 3
ok "G03-AC-3: another user's comment, a thumbs-up, an approval and a comment on a human's PR start nothing" test ! -s "$GD/claude.log"

g03_hold fbnode.11; g03_hold fbnode.12; g03_hold fbspec.13
fbadd 11 conversation 121 'please rename the helper'
fbadd 11 line 122 'use a constant here' path=src/a.py line=7
fbadd 12 conversation 221 'the follow-up needs a docs note'
fbadd 13 review 321 'the criterion is vague' state=CHANGES_REQUESTED
ok "G03-AC-3: owner feedback on a node PR starts one node session" waitf 12 runsis fbnode.11 1
ok "G03-AC-3: its prompt is /noodlebot:node --feedback 11" grep -qF "fbnode 11 run 1 /noodlebot:node --feedback 11 |" "$GD/claude.log"
ok "G03-AC-3: it runs in the node's worktree worktrees/<name>/X01" grep -qF "| $wt6/X01 | " "$GD/claude.log"
ok "G03-AC-3: on the PR's branch node/X01-first, at its head" grep -qF "| node/X01-first | $(g03_tip node/X01-first)" "$GD/claude.log"
ok "G03-AC-3: FEEDBACK.md is in the node's state folder, with both items" sh -c "grep -qF '$(fburl 11 conversation 121)' '$state/node/X01/FEEDBACK.md' && grep -qF '$(fburl 11 line 122)' '$state/node/X01/FEEDBACK.md'"
ok "G03-AC-3: the session saw that FEEDBACK.md, naming the PR and its branch" sh -c "grep -q '^PR: 11' '$GD/fbseen.fbnode.11.1' && grep -q '^Branch: node/X01-first' '$GD/fbseen.fbnode.11.1' && grep -qF '$(fburl 11 conversation 121)' '$GD/fbseen.fbnode.11.1'"
ok "G03-AC-3: it is start 1 of 2 (starts file)" waitf 3 sh -c "[ \"\$(cat '$state/node/X01/starts' 2>/dev/null)\" = 1 ]"
ok "G03-AC-3: and one status-log event" waitf 3 g03_startedis 11 1 1
ok "G03-AC-3: owner feedback on a follow-up PR starts one session of its node" waitf 12 runsis fbnode.12 1
ok "G03-AC-3: its prompt is /noodlebot:node --feedback 12" grep -qF "fbnode 12 run 1 /noodlebot:node --feedback 12 |" "$GD/claude.log"
ok "G03-AC-3: it runs in the node's worktree X02, on the follow-up branch" grep -qF "| $wt6/X02 | node/X02-followup-1 | $(g03_tip node/X02-followup-1)" "$GD/claude.log"
ok "G03-AC-3: its FEEDBACK.md is in the node's state folder" grep -qF "$(fburl 12 conversation 221)" "$state/node/X02/FEEDBACK.md"
ok "G03-AC-3: it is start 1 of 2, one status-log event" waitf 3 g03_startedis 12 1 1
ok "G03-AC-3: owner feedback on a spec PR starts one triage session" waitf 12 runsis fbspec.13 1
ok "G03-AC-3: its prompt is /noodlebot:triage --feedback 13" grep -qF "fbspec 13 run 1 /noodlebot:triage --feedback 13 |" "$GD/claude.log"
ok "G03-AC-3: it runs in worktrees/<name>/pr-13 on the PR's branch spec/c1" grep -qF "| $wt6/pr-13 | spec/c1 | $(g03_tip spec/c1)" "$GD/claude.log"
ok "G03-AC-3: its FEEDBACK.md is in state/<name>/pr/13/" grep -qF "$(fburl 13 review 321)" "$state/pr/13/FEEDBACK.md"
ok "G03-AC-3: its state is in pr/13/: pid recorded, start 1 of 2" waitf 3 sh -c "test -s '$state/pr/13/session.pid' && test \"\$(cat '$state/pr/13/starts' 2>/dev/null)\" = 1"
ok "G03-AC-3: one status-log event" waitf 3 g03_startedis 13 1 1
wait_ticks 3
ok "G03-AC-3: each PR got one session, not more, while they run" sh -c "[ \"\$(cat '$GD/runs.fbnode.11' 2>/dev/null)\" = 1 ] && [ \"\$(cat '$GD/runs.fbnode.12' 2>/dev/null)\" = 1 ] && [ \"\$(cat '$GD/runs.fbspec.13' 2>/dev/null)\" = 1 ]"
ok "G03-AC-3: no other session started (no ready node, no update, no triage)" test "$(wc -l <"$GD/claude.log")" = 3

# AC-6: the rendered prompts
prompt_checks() { # <id.run> <PR> <branch> <worktree> <FEEDBACK.md path> <command> <item URL>...
	local f=$GD/sys.$1 pr=$2 br=$3 wt=$4 fb=$5 cmd=$6 u; shift 6
	ok "G03-AC-6 ($1): the prompt was rendered and keeps no placeholder" sh -c "[ -s '$f' ] && ! grep -qE '@[A-Z]+@' '$f'"
	ok "G03-AC-6 ($1): names the PR" grep -qE "PR #?$pr([^0-9]|\$)" "$f"
	ok "G03-AC-6 ($1): names its branch" grep -qF "$br" "$f"
	ok "G03-AC-6 ($1): names the worktree" grep -qF "$wt" "$f"
	ok "G03-AC-6 ($1): names FEEDBACK.md and its path" grep -qF "$fb" "$f"
	for u in "$@"; do ok "G03-AC-6 ($1): names the item $u" grep -qF "$u" "$f"; done
	ok "G03-AC-6 ($1): names the skill command to follow" grep -qF "$cmd" "$f"
	ok "G03-AC-6 ($1): every point gets a reply on the PR" grep -qiE 'repl(y|ies)' "$f"
	ok "G03-AC-6 ($1): line threads that were fixed are resolved" grep -qiE 'resolv[a-z]* .*thread|thread.*resolv' "$f"
	ok "G03-AC-6 ($1): keeps the rule for questions (QUESTION.md)" grep -qF 'QUESTION.md' "$f"
	ok "G03-AC-6 ($1): keeps the GitHub access rule (a fresh App token per command, never printed)" sh -c "grep -qF 'GH_TOKEN=\$(~/.config/noodlebot/token o/up)' '$f' && grep -qF 'Never print, echo or log a token' '$f'"
	ok "G03-AC-6 ($1): keeps the closing-keyword rule" grep -qiE 'closing keyword' "$f"
	ok "G03-AC-6 ($1): and writes no closing keyword before a number itself" sh -c "! grep -qiE '(clos(e|es|ed)|fix(es|ed)?|resolv(e|es|ed)):? +#[0-9]' '$f'"
	ok "G03-AC-6 ($1): keeps the rule to never merge or approve" grep -qF 'Never merge, approve, push to main' "$f"
	ok "G03-AC-6 ($1): keeps the signature" grep -qF '— n00dl3b0t' "$f"
}
prompt_checks fbnode.11.1 11 node/X01-first "$wt6/X01" "$state/node/X01/FEEDBACK.md" "/noodlebot:node --feedback 11" "$(fburl 11 conversation 121)" "$(fburl 11 line 122)"
prompt_checks fbspec.13.1 13 spec/c1 "$wt6/pr-13" "$state/pr/13/FEEDBACK.md" "/noodlebot:triage --feedback 13" "$(fburl 13 review 321)"

g03_stop
loop_end
