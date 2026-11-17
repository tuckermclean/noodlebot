#!/bin/sh
# Tests scheduler/report.py: the "Adopt <name>" home issue of the adoption units (A07-AC-2, report part).
#   sh scheduler/report-a07.test.sh   (make test)
# Own file because report.test.sh is already over the 30 s file budget. Assumptions (the node spec's Change 2 leaves the rest open):
#  - an adoption unit's state folder is state/adopt/<key> (key: scaffold, an area's name, plan) with QUESTION.md, ANSWER.md,
#    WAITING-PR; the loop logs "started adopt/<key> in ..., start N of 2" and "adopt/<key> ended (rc 0) with QUESTION.md";
#  - <name> is the repository's name (here "repo", from owner/repo and the basename of --worktrees);
#  - a unit's milestone names the unit's key; a merged PR is a line "<N> <branch>" in merged-prs.tsv and N in merged-prs.txt;
#  - the issue is closed by the runs after the plan PR (spec/adopt-plan, the plan unit's WAITING-PR) shows as merged.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
fakegh_lib=$src/testdata/lib
. "$fakegh_lib/report-fakegh.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
pyc_setup
. "$fakegh_lib/report-units.sh"
ustatus_init
s=$tmp/A07/state
mkdir -p "$s/adopt"
: >"$s/status.log"; : >"$s/merged-prs.tsv"; : >"$s/merged-prs.txt"; : >"$s/closed-prs.tsv"; : >"$s/closed-unmerged-prs.txt"
rm -f "$tmp/ufail"
urun "$s"; urun "$s"   # the seeding runs: nothing adoptive yet
adopts() { uq "len([i for i in db['issues'].values() if i['title'] == 'Adopt repo'])"; }
ahome() { uq "[i['number'] for i in db['issues'].values() if i['title'] == 'Adopt repo'][0]"; }
run3() { urun "$s"; urun "$s"; urun "$s"; }
ok "A07-AC-2: no Adopt issue before an adoption unit exists" test "$(adopts)" = 0

# the scaffold unit starts
mkdir -p "$s/adopt/scaffold"
ev "started adopt/scaffold in /wt, pid 1, start 1 of 2" "$s"
run3
ok "A07-AC-2: the first adoption unit creates one issue titled 'Adopt repo'" test "$(adopts)" = 1
h=$(ahome)
ok "A07-AC-2: the Adopt issue is labelled noodlebot-unit" test "$(uq "db['issues']['$h']['labels']")" = "['noodlebot-unit']"
ok "A07-AC-2: the scaffold's start is one comment on it, beginning with a Stage line and naming the unit" sh -c "[ \"\$1\" = 1 ] && [ \"\$2\" = 1 ]" _ "$(ucount "$h" '\A\*\*Stage:\*\*(?i:.*scaffold)')" "$(unum "$h")"

# the scaffold asks
printf 'Q1: which areas?\nscaffold-unique-q-line\n' >"$s/adopt/scaffold/QUESTION.md"
ev "adopt/scaffold ended (rc 0) with QUESTION.md" "$s"
run3
ok "A07-AC-2: the scaffold's QUESTION.md is one comment on the Adopt issue, over three runs" test "$(ucontains "$h" "$s/adopt/scaffold/QUESTION.md")" = 1
ok "A07-AC-2: the issue holds the start and the question, nothing else" test "$(unum "$h")" = 2
ok "A07-AC-2: still one Adopt issue" test "$(adopts)" = 1

# the owner answers on the Adopt issue
uowned "$h" "areas: use the list" https://x/a07-scaffold-ans
urun "$s"; urun "$s"
ok "A07-AC-2: an owner reply on the Adopt issue after the question is recorded as the scaffold's ANSWER.md" sh -c "grep -q 'areas: use the list' '$s/adopt/scaffold/ANSWER.md'"
ok "A07-AC-2: the reply is answered with a +1, as a unit's answer is" test "$(ureact https://x/a07-scaffold-ans)" = 1

# the scaffold resumes and its PR is merged; the first area starts
rm -f "$s/adopt/scaffold/QUESTION.md" "$s/adopt/scaffold/ANSWER.md"; mkdir "$s/adopt/scaffold/answered"
echo 11 >"$s/adopt/scaffold/WAITING-PR"; echo "11 spec/adopt" >>"$s/merged-prs.tsv"; echo 11 >>"$s/merged-prs.txt"
mkdir -p "$s/adopt/wrap"
ev "started adopt/wrap in /wt, pid 2, start 1 of 2" "$s"
run3
ok "A07-AC-2: a later unit reuses the issue: still one Adopt issue" test "$(adopts)" = 1
ok "A07-AC-2: the area's start is a comment on the same issue, naming the unit" test "$(ucount "$h" '\A\*\*Stage:\*\*(?i:.*wrap)')" -ge 1
ok "A07-AC-2: the issue is still open after the scaffold PR merged (the adoption runs on)" test "$(ustateof "$h")" = open

# the area asks; the reply answers the area and not the scaffold
printf 'Q1: split wrap?\nwrap-unique-q-line\n' >"$s/adopt/wrap/QUESTION.md"
ev "adopt/wrap ended (rc 0) with QUESTION.md" "$s"
run3
ok "A07-AC-2: the area's QUESTION.md is one comment on the Adopt issue" test "$(ucontains "$h" "$s/adopt/wrap/QUESTION.md")" = 1
ok "A07-AC-2: no ANSWER.md for the area before an owner reply" test ! -e "$s/adopt/wrap/ANSWER.md"
ucomment "$h" "wrap: split in two" 2026-02-03T00:00:00Z owner OWNER User https://x/a07-wrap-ans
urun "$s"; urun "$s"
ok "A07-AC-2: the owner reply after the area's question is recorded as the area's ANSWER.md" sh -c "grep -q 'wrap: split in two' '$s/adopt/wrap/ANSWER.md'"
ok "A07-AC-2: it is not recorded for another unit (the scaffold has no ANSWER.md)" test ! -e "$s/adopt/scaffold/ANSWER.md"
ok "A07-AC-2: still one Adopt issue after the answers" test "$(adopts)" = 1

# the area's PR merges, then the plan unit runs
rm -f "$s/adopt/wrap/QUESTION.md" "$s/adopt/wrap/ANSWER.md"; mkdir "$s/adopt/wrap/answered"
echo 12 >"$s/adopt/wrap/WAITING-PR"; echo "12 spec/adopt-wrap" >>"$s/merged-prs.tsv"; echo 12 >>"$s/merged-prs.txt"
mkdir -p "$s/adopt/plan"
ev "started adopt/plan in /wt, pid 3, start 1 of 2" "$s"
echo 13 >"$s/adopt/plan/WAITING-PR"
run3
ok "A07-AC-2: the plan's start is a comment on the same issue, naming the unit" test "$(ucount "$h" '\A\*\*Stage:\*\*(?i:.*plan)')" -ge 1
ok "A07-AC-2: the issue is not closed after an area PR merged, with the plan PR open" test "$(ustateof "$h")" = open

# the plan PR merges
echo "13 spec/adopt-plan" >>"$s/merged-prs.tsv"; echo 13 >>"$s/merged-prs.txt"
run3
ok "A07-AC-2: the Adopt issue is closed once the plan PR is merged" test "$(ustateof "$h")" = closed
ok "A07-AC-2: and there is still only one Adopt issue" test "$(adopts)" = 1

# S4 review 1 (F1): the plan PR merges after report.json was lost; the Adopt issue is still closed, once
s2=$tmp/A07/state-lost
mkdir -p "$s2/adopt"
: >"$s2/status.log"
urun "$s2"; urun "$s2"
mkdir -p "$s2/adopt/plan"
ev "started adopt/plan in /wt, pid 5, start 1 of 2" "$s2"
urun "$s2"; urun "$s2"
echo 31 >"$s2/adopt/plan/WAITING-PR"
urun "$s2"
h2=$(cut -d' ' -f1 "$s2/adopt/plan/issue" 2>/dev/null)
ok "A07-AC-2: the plan unit's start wrote its issue file (precondition of the lost-report.json cases)" test -n "$h2"
rm -f "$s2/report.json"
echo "31 spec/adopt-plan" >>"$s/merged-prs.tsv"; echo 31 >>"$s/merged-prs.txt"
echo "31 spec/adopt-plan" >>"$s2/merged-prs.tsv"; echo 31 >>"$s2/merged-prs.txt"
run3_2() { urun "$s2"; urun "$s2"; urun "$s2"; }
run3_2
ok "A07-AC-2: the Adopt issue is closed within 3 runs of the plan PR's merge although report.json was lost after the plan unit started" test "$(ustateof "${h2:-0}")" = closed
ok "A07-AC-2: and exactly one closing comment was posted" test "$(ucount "${h2:-0}" 'closing this issue')" = 1
rm -f "$s2/report.json"
run3_2
ok "A07-AC-2: a report.json lost after the issue was closed posts no second closing comment" test "$(ucount "${h2:-0}" 'closing this issue')" -le 1
ok "A07-AC-2: and the issue stays closed" test "$(ustateof "${h2:-0}")" = closed

# S4 review 1 (F4): a WAITING-PR first seen already merged gets no "waits for you to merge" milestone
s3=$tmp/A07/state-merged
mkdir -p "$s3/adopt"
: >"$s3/status.log"; : >"$s3/merged-prs.tsv"; : >"$s3/merged-prs.txt"
urun "$s3"; urun "$s3"
mkdir -p "$s3/adopt/wrapx"
ev "started adopt/wrapx in /wt, pid 6, start 1 of 2" "$s3"
urun "$s3"; urun "$s3"
h3=$(cut -d' ' -f1 "$s3/adopt/wrapx/issue" 2>/dev/null)
echo 32 >"$s3/adopt/wrapx/WAITING-PR"; echo "32 spec/adopt-wrapx" >>"$s3/merged-prs.tsv"; echo 32 >>"$s3/merged-prs.txt"
for i in 1 2 3; do urun "$s3"; done
ok "A07-AC-2: an adoption PR first seen already merged gets no 'waits for you to merge' comment" test "$(ucount "${h3:-0}" '(?i)waits? for you')" = 0
ok "A07-AC-2: and its merge is posted once" test "$(ucount "${h3:-0}" '(?i)#32.*merged|merged.*#32')" = 1

# F4 (open PR): the waiting milestone once
s4=$tmp/A07/state-open
mkdir -p "$s4/adopt"
: >"$s4/status.log"; : >"$s4/merged-prs.tsv"; : >"$s4/merged-prs.txt"
urun "$s4"; urun "$s4"
mkdir -p "$s4/adopt/wrapy"
ev "started adopt/wrapy in /wt, pid 7, start 1 of 2" "$s4"
urun "$s4"; urun "$s4"
h4=$(cut -d' ' -f1 "$s4/adopt/wrapy/issue" 2>/dev/null)
echo 33 >"$s4/adopt/wrapy/WAITING-PR"
for i in 1 2 3; do urun "$s4"; done
ok "A07-AC-2: an adoption PR that is open gets the waiting milestone exactly once over three runs" test "$(ucount "${h4:-0}" '(?i)#33.*waits? for you')" = 1

# F3: the status issue does not say an adoption unit waiting on its PR resumes
st=$(uq "[i['body'] for i in db['issues'].values() if 'noodlebot-status' in i['labels']][0]")
adline=$(printf '%s\n' "$st" | grep 'adopt/wrapy' | grep -i 'merge')
ok "A07-AC-2: the status issue lists the adoption unit waiting on its PR (precondition)" test -n "$adline"
ok "A07-AC-2: and does not say that it resumes after the merge (the next unit starts)" sh -c "! printf '%s' \"\$1\" | grep -qi resum" _ "$adline"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails check(s) failed"; exit 1; fi
echo "PASS: all report-a07 checks"
