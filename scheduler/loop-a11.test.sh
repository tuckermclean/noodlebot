#!/bin/bash
# A11-AC-1, A11-AC-2: the update and feedback prompts of a spec/adopt* PR name the scaffold unit's answered/ folder (by its
# absolute path); those of a spec/triage-* PR and the feedback prompt of a node PR do not; no rendered prompt holds a
# leftover @...@ placeholder. One loop (fixture: testdata/lib/loop-g03.sh) runs the five sessions side by side:
#   PR 15 spec/adopt-wrap   adoption's PR, conflicts with main    update   (the fake claude: id other.15, /noodlebot:adopt --update)
#   PR 16 spec/adopt        adoption's PR, owner feedback         feedback (id other.16)
#   PR 17 spec/triage-a     triage's PR, conflicts with main      update   (id update.17)
#   PR 18 spec/triage-b     triage's PR, owner feedback           feedback (id fbspec.18)
#   PR 11 node/X01-first    node PR, owner feedback               feedback (id fbnode.11)
# The prompt of each session is state/up/pr/<N>/ (node: node/X01/) unattended.md; a session is awaited by its run count.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

g01branch spec/adopt-wrap "${g01base}  - {id: X03, name: n3, deps: []}\n"
g01branch spec/adopt "${g01base}  - {id: X04, name: n4, deps: []}\n"
g01branch spec/triage-a "${g01base}  - {id: X05, name: n5, deps: []}\n"
g01branch spec/triage-b "${g01base}  - {id: X06, name: n6, deps: []}\n"
cat >>"$GD/prs.tsv" <<'EOT'
15 spec/adopt-wrap app/noodlebot true CONFLICTING
16 spec/adopt app/noodlebot true MERGEABLE
17 spec/triage-a app/noodlebot true CONFLICTING
18 spec/triage-b app/noodlebot true MERGEABLE
EOT
echo "$state/pr/16" >"$GD/udir.16"; echo "$state/pr/18" >"$GD/udir.18"
# the scaffold unit's folder of answers (kept by the loop while the adoption runs)
sc=$state/adopt/scaffold/answered
mkdir -p "$sc" && echo "Q1: which? A1: a" >"$sc/20261101T000000Z-QUESTION.md"
nm=adopt/scaffold/answered   # a prompt that names the folder holds this, absolute or not

# names <prompt>: it names the scaffold's answered/ folder by its absolute path, on a line that speaks of the owner's answers
names() { grep -F -- "$sc" "$1" | grep -qi 'answer'; }
# nonames <prompt>: it exists and says nothing of the folder
nonames() { [ -s "$1" ] && ! grep -qF -- "$nm" "$1"; }
noleft() { [ -s "$1" ] && ! grep -qE '@[A-Z_]+@' "$1"; }

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "A11 setup: the first tick records the open PRs' feedback" g03_first
fbadd 16 conversation 121 'adoption point'
fbadd 18 conversation 122 'triage point'
fbadd 11 conversation 123 'node point'
ok "A11 setup: the update session of PR 15 (spec/adopt-wrap) starts" waitf 20 runsis other.15 1
ok "A11 setup: the feedback session of PR 16 (spec/adopt) starts" waitf 20 runsis other.16 1
ok "A11 setup: the update session of PR 17 (spec/triage-a) starts" waitf 20 runsis update.17 1
ok "A11 setup: the feedback session of PR 18 (spec/triage-b) starts" waitf 20 runsis fbspec.18 1
ok "A11 setup: the feedback session of node X01 (PR 11) starts" waitf 20 runsis fbnode.11 1
g03_stop

u15=$state/pr/15/unattended.md u16=$state/pr/16/unattended.md u17=$state/pr/17/unattended.md
u18=$state/pr/18/unattended.md u11=$state/node/X01/unattended.md
ok "A11-AC-1: the update prompt of a spec/adopt* PR (PR 15) is the update template's" grep -qF 'started this session to update' "$u15"
ok "A11-AC-1: the update prompt of a spec/adopt* PR names the scaffold's answered/ folder by its absolute path" names "$u15"
ok "A11-AC-1: the feedback prompt of a spec/adopt* PR (PR 16) is the feedback template's" grep -qF "to act on the owner's feedback" "$u16"
ok "A11-AC-1: the feedback prompt of a spec/adopt* PR names the scaffold's answered/ folder by its absolute path" names "$u16"
ok "A11-AC-2: the update prompt of a spec/triage-* PR (PR 17) does not name the folder" nonames "$u17"
ok "A11-AC-2: the feedback prompt of a spec/triage-* PR (PR 18) does not name the folder" nonames "$u18"
ok "A11-AC-2: the feedback prompt of a node PR (PR 11) does not name the folder" nonames "$u11"
ok "A11-AC-2: no leftover @...@ in the adopt update prompt" noleft "$u15"
ok "A11-AC-2: no leftover @...@ in the adopt feedback prompt" noleft "$u16"
ok "A11-AC-2: no leftover @...@ in the triage update prompt" noleft "$u17"
ok "A11-AC-2: no leftover @...@ in the triage feedback prompt" noleft "$u18"
ok "A11-AC-2: no leftover @...@ in the node feedback prompt" noleft "$u11"
loop_end
