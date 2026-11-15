#!/bin/bash
# R02-AC-1 (the prompts the loop writes for a spec or PR session): the triage, update, node-update and feedback prompts
# (node feedback, spec feedback) of a loop on the fake harness, over G03's fixture (testdata/lib/loop-g03.sh: remote
# $tmp/remote6.git, a local path, no GitHub remote; the fake gh gives the PRs, issue and feedback). Each rendered prompt
# tells the session to reach the forge through NOODLEBOT_FORGE, holds no gh command and no github.com URL, and keeps the rules.
# The skill command in the triage, update and node-update prompts is the fake harness's skill-command output.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"
. "$src/testdata/lib/loop-R02.sh"
r02_nb=$tmp/nb6

# the fixture's feedback items get a host that is not GitHub; the loop runs the fake harness (its sessions end at once)
sed -i 's|https://github.com/|https://forge.example/|' "$GD/fbadd.py"
mkdir -p "$r02_nb/scheduler/testdata/harness"
cp "$src/testdata/harness/fake.py" "$r02_nb/scheduler/testdata/harness/fake.py"
printf '15 spec/late app/noodlebot true MERGEABLE\n' >>"$GD/prs.tsv"
NOODLEBOT_DATA=$data6 PATH=$tmp/bin6:$PATH SCHED_HARNESS=fake FAKE_HARNESS_LOG=$tmp/R02-harness.log SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$r02_nb/scheduler/loop.sh" o/up >>"$tmp/R02-loop.out" 2>&1 &
pids+=("$!"); lp6=$!
ok "R02 setup: the first tick records the open PRs' feedback" g03_first

p_tri=$state/issue/46/unattended.md p_upd=$state/pr/15/unattended.md p_nup=$state/pr/12/unattended.md
p_fbn=$state/node/X01/unattended.md p_fbs=$state/pr/13/unattended.md
# the loop writes a prompt in place: it is whole when its last line, the signature, is there
there() { grep -q n00dl3b0t "$1" 2>/dev/null; }
# One slot: a triage or an update at a time, and no spec feedback while a triage runs. So in two steps: the triage of #46 (once: the
# fake gh's issue list is emptied when its prompt is there), the node-PR update of PR 12 and the node feedback of PR 11 first;
# then the update of the spec PR 15 and the spec feedback of PR 13.
echo '[{"number": 46}]' >"$GD/issues.json"
sed -i 's/^12 \(.*\) MERGEABLE$/12 \1 CONFLICTING/' "$GD/prs.tsv"
fbadd 11 conversation 121 'please rename the helper'
fbadd 11 line 122 'use a constant here' path=src/a.py line=7
wait_until 30 there "$p_tri" && echo '[]' >"$GD/issues.json"
wait_until 30 there "$p_nup"; wait_until 30 there "$p_fbn"
sed -i 's/^15 \(.*\) MERGEABLE$/15 \1 CONFLICTING/' "$GD/prs.tsv"
fbadd 13 review 321 'the criterion is vague' state=CHANGES_REQUESTED
wait_until 30 there "$p_upd"; wait_until 30 there "$p_fbs"
# the files the loop writes are final: take copies before the loop ends
for f in tri upd nup fbn fbs; do eval "cp \"\$p_$f\" \"$tmp/R02-$f.md\" 2>/dev/null"; done
touch "$HOME/STOP-up"

r02_prompt triage "$tmp/R02-tri.md" questions,closing,merge,sig
r02_prompt update "$tmp/R02-upd.md" closing,merge,sig
r02_prompt node-update "$tmp/R02-nup.md" questions,closing,merge,sig
r02_prompt "node feedback" "$tmp/R02-fbn.md" questions,closing,merge,sig
r02_prompt "spec feedback" "$tmp/R02-fbs.md" questions,closing,merge,sig
# R02 change 2: the skill commands in the templates come from the harness's skill_command
sk() { SCHED_HARNESS=fake python3 -I -B "$src/harness.py" skill-command "$@"; }
r02_skill triage "$tmp/R02-tri.md" "$(sk triage 46)"
r02_skill update "$tmp/R02-upd.md" "$(sk triage '--update 15')"
r02_skill node-update "$tmp/R02-nup.md" "$(sk node '--update 12')"
# review 1: the feedback prompts carry the harness's skill command too (PR 11 is the node's, PR 13 the spec PR's)
r02_skill "node feedback" "$tmp/R02-fbn.md" "$(sk node '--feedback 11')"
r02_skill "spec feedback" "$tmp/R02-fbs.md" "$(sk triage '--feedback 13')"
loop_end
