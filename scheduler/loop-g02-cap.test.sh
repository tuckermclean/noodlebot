#!/bin/bash
# G02: updates count toward SCHED_MAX against a spec-PR update listed after a node-PR update (233, 234). Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g02.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g02.sh"

# The state the main run is in when it comes to these cases: the throttle open (an allowed window), the PRs of the main part not wanting an update.
g02_rl 0.01 $(($(date +%s) + 7200))
g02_prs 201 MERGEABLE; g02_prs 205 MERGEABLE
sed -i 's/ [A-Z]*$/ MERGEABLE/' "$G02_GD/prs.tsv"
g02g fetch -q "$G02/remote.git" main && g02g reset -q --hard FETCH_HEAD
printf '  - {id: N20, name: tau, deps: []}\n  - {id: N21, name: upsilon, deps: []}\n  - {id: N22, name: chi, deps: []}\n' >>"$G02/work/docs/graph.yaml"
g02g commit -q -a -m "graph: N20, N21, N22" && g02g push -q "$G02/remote.git" main
for g02_i in node/N20-tau node/N21-upsilon node/N22-chi spec/s2 spec/s3; do
	g02g checkout -q -b "$g02_i" main && g02g commit -q --allow-empty -m "branch $g02_i" && g02g push -q "$G02/remote.git" "$g02_i"; g02g checkout -q main
done
# G02-AC-1 (third review, finding 2): updates count toward SCHED_MAX also against a spec-PR update listed after
# a node-PR update in the same tick. SCHED_MAX=1: 233 (node PR) starts and holds; 234 (spec PR) does not.
printf '233 node/N22-chi app/noodlebot true CONFLICTING\n234 spec/s3 app/noodlebot true CONFLICTING\n' >>"$G02_GD/prs.tsv"
touch "$G02_GD/hold.233" "$G02_GD/hold.234"
g02_loop 1
ok "G02-AC-1: with SCHED_MAX=1 the node-PR update (233) starts" waitf 10 g02_runsis 233 1
wait_ticks 3
ok "G02-AC-1: the spec-PR update (234) listed after it does not start beyond the cap" g02_runsis 234 0
rm -f "$G02_GD/hold.233"
ok "G02-AC-1: the spec-PR update (234) starts when the node-PR update has ended" waitf 10 g02_runsis 234 1
rm -f "$G02_GD/hold.234"
g02_prs 233 MERGEABLE; g02_prs 234 MERGEABLE
g02_stop

loop_end
