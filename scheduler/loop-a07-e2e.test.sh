#!/bin/bash
# A07-AC-6 (end to end): with the fake forge, a repository with no graph goes through the first PR (scaffold), two area PRs
# and the plan PR to a graph without `adoption` that check-regime.py and check-coverage.py pass. The fake claude acts as
# each adoption session would (testdata/lib/loop-a07-e2e.sh), the test merges each PR as the owner would. (The part of
# A07-AC-6 about an origin/main that does not resolve is loop-a07-origin.test.sh.)
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-a07.sh"
. "$src/testdata/lib/loop-a07-e2e.sh"

a07_fork a07
a07e_seed a07
a07_run a07
pr_open() { python3 -c 'import json,sys; sys.exit(0 if any(p["number"]==int(sys.argv[2]) and p["state"]=="open" for p in json.load(open(sys.argv[1]+"/prs.json"))) else 1)' "$G04/fk/a07" "$1"; }
pr_merged() { python3 -c 'import json,sys; sys.exit(0 if any(p["number"]==int(sys.argv[2]) and p["state"]=="merged" for p in json.load(open(sys.argv[1]+"/prs.json"))) else 1)' "$G04/fk/a07" "$1"; }
alone() { # the session log alternates start/end: no two sessions at once
	awk '$1 == "start" { if (open) bad = 1; open = 1 } $1 == "end" { if (!open) bad = 1; open = 0 } END { exit (bad || open) }' "$A07/e2e.log"
}
step() { # <key> <pr> <label>
	need "A07-AC-6: $3: the session runs, opens PR #$2 and ends with WAITING-PR" 20 a07_waiting "$1"
	chk "A07-AC-6: $3: PR #$2 is open" pr_open "$2"
	chk "A07-AC-6: $3: the PR's branch is on the fake forge" git -C "$G04/fk/a07/repo.git" rev-parse -q --verify "refs/heads/$4" >/dev/null
	chk "A07-AC-6: $3: the PR merges (as the owner would)" a07e_merge a07 "$1" "$2"
	chk "A07-AC-6: $3: the PR is marked merged" pr_merged "$2"
}
step scaffold 21 "scaffold (the first PR)" spec/adopt
need "A07-AC-6: after the first PR merged, the first area's session starts" 20 a07_logged '^wrap run 1 '
step wrap 22 "area one (wrap)" spec/adopt-wrap
need "A07-AC-6: after the first area's PR merged, the second area's session starts" 20 a07_logged '^tests run 1 '
step tests 23 "area two (tests)" spec/adopt-tests
need "A07-AC-6: after the second area's PR merged, the plan session starts" 20 a07_logged '^plan run 1 '
step plan 24 "plan" spec/adopt-plan
ticks 4
chk "A07-AC-6: one session per unit in order scaffold, area one, area two, plan" test "$(cut -d' ' -f1 "$A07/claude.log" | paste -sd, -)" = scaffold,wrap,tests,plan
chk "A07-AC-6: the sessions' own log has start and end of each unit in that order" test "$(paste -sd, - <"$A07/e2e.log")" = "start scaffold,end scaffold,start wrap,end wrap,start tests,end tests,start plan,end plan"
chk "A07-AC-6: never two sessions at once" alone
chk "A07-AC-6: each session worked in its own worktree on its unit's branch" sh -c "awk -F' [|] ' '{print \$3}' '$A07/claude.log' | paste -sd, - | grep -qx 'spec/adopt,spec/adopt-wrap,spec/adopt-tests,spec/adopt-plan'"
chk "A07-AC-6: no adoption session starts after the plan PR merged (the loop ticked on)" test "$(grep -c . "$A07/claude.log")" = 4
chk "A07-AC-6: no unit is held by FAILED" test -z "$(ls "$st"/adopt/*/FAILED 2>/dev/null)"
a07_stop
# the final main
fin=$A07/final
git clone -q "$G04/fk/a07/repo.git" "$fin" 2>/dev/null
chk "A07-AC-6: origin/main's docs/graph.yaml has no adoption" test -s "$fin/docs/graph.yaml" -a "$(grep -c '^adoption:' "$fin/docs/graph.yaml")" = 0
chk "A07-AC-6: origin/main's graph has the imported nodes of both areas" sh -c "grep -qE 'id: W01' '$fin/docs/graph.yaml' && grep -qE 'id: W03' '$fin/docs/graph.yaml'"
rep=$(python3 -I "$src/../plugin/skills/node/check-regime.py" --root "$fin" 2>&1)
chk "A07-AC-6: check-regime.py reports PROBLEMS 0 on a clone of the final main" sh -c "printf '%s\n' '$rep' | tail -n 1 | grep -qx 'PROBLEMS 0'"
rep=$(python3 -I "$src/../plugin/skills/node/check-coverage.py" --root "$fin" 2>&1)
chk "A07-AC-6: check-coverage.py reports PROBLEMS 0 on a clone of the final main" sh -c "printf '%s\n' '$rep' | tail -n 1 | grep -qx 'PROBLEMS 0'"
loop_end
