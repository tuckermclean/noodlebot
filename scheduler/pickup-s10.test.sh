#!/bin/sh
# Tests S10-AC-2: pickup.py removes the run folders it made once they are finished and old, over the fake forge and the
# fake harness:
#   sh scheduler/pickup-s10.test.sh   (make test)
#
# THE CONTRACT these cases fix (the node spec's Changes 2):
#   At each pickup step (one `pickup.py ... run`), after the replies that failed earlier are retried, a run folder
#   DIR/pickup/<run> is removed when every item of its items.json is done (decision carried out, reply posted) and its last
#   change is more than seven days old. The last change is the newest mtime of the folder and of every file in it. A run with
#   anything left to do is kept, whatever its age. The handled record (DIR/pickup/handled) and the budget record
#   ($NOODLEBOT_DATA/state/pickup.json) are not touched by the removal: a removed run's items are not picked up again (no new
#   run, no second reply) and its run still counts in its budget window (PICKUP_RUNS).
# Ages are made with touch -d on the folder and its files (no sleeping); nothing waits on a clock.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
for v in $(env | cut -d= -f1 | grep -E '^(SCHED_|FAKE_|PICKUP|NOODLEBOT_|USAGE_)'); do unset "$v"; done
unset GH_TOKEN
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
T=$src/testdata/pickup
R=$tmp/S10
ST=$R/state/w
FK=$R/fk
tool() { python3 -I "$T/tool.py" "$@"; }
mkdir -p "$R/state" "$R/cwd" "$R/wt" "$R/clone"
cp -R "$T/state" "$ST"; cp -R "$T/forge" "$FK"
mkdir -p "$ST/pickup/pending"

pk() {
	(cd "$R/cwd" && env NOODLEBOT_DATA="$R" SCHED_HARNESS=fake FAKE_HARNESS_SMALL_SCRIPT="$R/ev" FAKE_HARNESS_LOG="$R/h.log" PICKUP_RUNS=4 \
		python3 -I "$src/pickup.py" --repo "fake:$FK" --state "$ST" --owner owner --clone "$R/clone" \
		--worktrees "$R/wt" --version 9.9 --signature SIG-9 "$@")
}
# pend <id> <issue>: an owner comment id on <issue> becomes pending
pend() {
	python3 -I -c '
import json, sys
i, n = int(sys.argv[1]), int(sys.argv[2])
json.dump({"id": i, "url": "https://github.com/owner/repo/issues/%d#issuecomment-%d" % (n, i), "issue": n, "where": "home",
           "created_at": "2026-06-02T11:00:00Z", "author": {"login": "owner", "is_bot": False, "is_owner": True},
           "body": "pending %d" % i, "reply": "Not recorded as an answer: no question is waiting on this issue."},
          open(sys.argv[3], "w"))' "$1" "$2" "$ST/pickup/pending/$1.json"
}
# tick <id> <issue>: the item is pending, the session decides "note"; one step. RUN is the folder it made (if any)
tick() {
	pend "$1" "$2"
	tool script "$R/ev" "$(printf '[{"item": %s, "action": "note", "reason": "r"}]' "$1")"
	pk run >"$R/t.$1.out" 2>"$R/t.$1.err"; RC=$?
	RUN=$(sed -n 's/^pickup run \([^: ]*\):.*/\1/p' "$R/t.$1.out" | tail -n1)
}
nsmall() { n=$(grep -c '^small ' "$R/h.log" 2>/dev/null); echo "${n:-0}"; }
handled() { grep -qx "$1" "$ST/pickup/handled" 2>/dev/null; }
exists() { test -d "$ST/pickup/$1"; }
# age <run> <folder age> <files age>: the files' mtimes, then the folder's own (touching a file leaves the folder's mtime)
age() {
	find "$ST/pickup/$1" -type f -exec touch -d "$3" {} +
	touch -d "$2" "$ST/pickup/$1"
}
# replies <issue>: the bot's "Noted" replies on the issue; denied <issue>: its deterministic budget replies
replies() { tool count "$FK" "$1" "Noted ("; }
denied() { tool count "$FK" "$1" "Not recorded as an answer"; }
cp "$FK/issues.json" "$R/issues.all"

echo "== S10-AC-2: four runs: three finished (items on issue 13), one whose reply cannot be posted (issue 14 is gone)"
tick 9101 13; r1=$RUN; rc1=$RC
tick 9102 13; r2=$RUN
tick 9103 13; r3=$RUN
tool rmissue "$FK" 14
tick 9104 14; r4=$RUN; rc4=$RC
ok "S10-AC-2: (setup) four runs started, each in its own folder" \
	sh -c '[ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] && [ -n "$4" ] && [ -d "$5/$1" ] && [ -d "$5/$2" ] && [ -d "$5/$3" ] && [ -d "$5/$4" ] && [ "$6" = 4 ]' \
		_ "$r1" "$r2" "$r3" "$r4" "$ST/pickup" "$(nsmall)"
ok "S10-AC-2: (setup) the first three finished (exit 0, handled, replied once), the fourth did not (exit 1, not handled)" \
	sh -c '[ "$1" = 0 ] && [ "$2" = 1 ] && grep -qx 9101 "$3" && grep -qx 9102 "$3" && grep -qx 9103 "$3" && ! grep -qx 9104 "$3" && [ "$4" = 3 ]' \
		_ "$rc1" "$rc4" "$ST/pickup/handled" "$(replies 13)"
cp "$ST/pickup/handled" "$R/handled.0"; cp "$R/state/pickup.json" "$R/pickup.json.0" 2>/dev/null
ok "S10-AC-2: (setup) the budget record exists" test -s "$R/pickup.json.0"

# r1: finished, everything 8 days old.  r2: folder and files 8 days old but one file changed 3 days ago.
# r3: files 9 days old but the folder itself changed 6 days ago.  r4: reply to retry, everything 9 days old.
age "$r1" "8 days ago" "8 days ago"
age "$r2" "8 days ago" "8 days ago"; touch -d "3 days ago" "$ST/pickup/$r2/session.stderr"
age "$r3" "6 days ago" "9 days ago"
age "$r4" "9 days ago" "9 days ago"
pk run >"$R/step1.out" 2>"$R/step1.err"; rc=$?
ok "S10-AC-2: the step (no new items) exits 0 and prints nothing" test "$rc" = 0 -a ! -s "$R/step1.out"
ok "S10-AC-2: a finished run whose last change is 8 days old is removed at the next step" test ! -e "$ST/pickup/$r1"
ok "S10-AC-2: a finished run, old folder, one file changed 3 days ago, is kept" exists "$r2"
ok "S10-AC-2: a finished run, old files, the folder itself changed 6 days ago, is kept" exists "$r3"
ok "S10-AC-2: a run with a reply still to retry is kept, 9 days old" exists "$r4"
ok "S10-AC-2: the other runs' files are all still there (only whole folders go)" \
	test -s "$ST/pickup/$r2/items.json" -a -s "$ST/pickup/$r2/state.json" -a -s "$ST/pickup/$r3/items.json" -a -s "$ST/pickup/$r4/state.json"
ok "S10-AC-2: the handled record and the budget record are as they were" \
	sh -c 'cmp -s "$1" "$2" && cmp -s "$3" "$4"' _ "$R/handled.0" "$ST/pickup/handled" "$R/pickup.json.0" "$R/state/pickup.json"

echo "== S10-AC-2: a removed run's items are not picked up again; its run still counts in the budget window"
pend 9101 13
n0=$(nsmall); rp0=$(replies 13)
pk run >"$R/step2.out" 2>"$R/step2.err"
ok "S10-AC-2: the removed run's item, pending again, starts no run and gets no second reply" \
	test "$(nsmall)" = "$n0" -a "$(replies 13)" = "$rp0" -a ! -s "$R/step2.out"
ok "S10-AC-2: ... it is still in the handled record, which is as it was" handled 9101
rm -f "$ST/pickup/pending/9101.json"
tick 9105 13
ok "S10-AC-2: the removed run still counts: four runs (PICKUP_RUNS=4) started in the window, so a fifth item starts no run" \
	test "$(nsmall)" = 4 -a -z "$RUN" -a "$RC" = 0
ok "S10-AC-2: ... it gets the deterministic reply, is handled, and the budget line is printed" \
	sh -c 'grep -qi "^pickup: no run.*budget" "$1" && grep -qx 9105 "$2"' _ "$R/t.9105.out" "$ST/pickup/handled"
ok "S10-AC-2: ... the runs kept stay kept" sh -c '[ -d "$1/$2" ] && [ -d "$1/$3" ] && [ -d "$1/$4" ]' _ "$ST/pickup" "$r2" "$r3" "$r4"

echo "== S10-AC-2: a run with a reply to retry: kept whatever its age, removed once the reply is posted and 7 days have passed"
cp "$R/issues.all" "$FK/issues.json"
pk run >"$R/step3.out" 2>"$R/step3.err"
ok "S10-AC-2: the reply is posted at the next step (once), the item is handled" \
	sh -c '[ "$1" = 1 ] && grep -qx 9104 "$2"' _ "$(replies 14)" "$ST/pickup/handled"
ok "S10-AC-2: the run, retried just now (a change today), is kept" exists "$r4"
age "$r4" "8 days ago" "8 days ago"
pk run >"$R/step4.out" 2>"$R/step4.err"
ok "S10-AC-2: once its reply is posted and its last change is 8 days old, the run is removed" test ! -e "$ST/pickup/$r4"
ok "S10-AC-2: ... the reply was not posted twice, the item stays handled" \
	sh -c '[ "$1" = 1 ] && grep -qx 9104 "$2"' _ "$(replies 14)" "$ST/pickup/handled"
ok "S10-AC-2: ... the run kept for its young file and the run kept for its young folder are still kept" \
	test -d "$ST/pickup/$r2" -a -d "$ST/pickup/$r3"
age "$r2" "8 days ago" "8 days ago"; age "$r3" "8 days ago" "8 days ago"
pk run >"$R/step5.out" 2>"$R/step5.err"
ok "S10-AC-2: both go once nothing in them is younger than 7 days" test ! -e "$ST/pickup/$r2" -a ! -e "$ST/pickup/$r3"
ok "S10-AC-2: no run started after the setup's four, no second reply anywhere" \
	test "$(nsmall)" = 4 -a "$(replies 13)" = "$rp0" -a "$(denied 13)" = 1


echo "== S10-AC-2: a run whose items.json cannot be read is not known to be finished, so it is kept"
for kind in bad notlist; do
	d=$ST/pickup/S10-unreadable-$kind
	mkdir -p "$d"
	echo '{"9201": {"done": true}}' >"$d/state.json"
	echo 'x' >"$d/prompt.md"
	if [ "$kind" = bad ]; then printf '[{"id": 9201, "bo' >"$d/items.json"; else echo '{}' >"$d/items.json"; fi
	find "$d" -type f -exec touch -d "9 days ago" {} +
	touch -d "9 days ago" "$d"
done
pk run >"$R/step6.out" 2>"$R/step6.err"
ok "S10-AC-2: a 9-day-old run whose items.json is truncated JSON is kept" \
	test -s "$ST/pickup/S10-unreadable-bad/items.json" -a -s "$ST/pickup/S10-unreadable-bad/state.json"
ok "S10-AC-2: a 9-day-old run whose items.json is valid JSON but not a list is kept" \
	test -s "$ST/pickup/S10-unreadable-notlist/items.json" -a -s "$ST/pickup/S10-unreadable-notlist/state.json"
[ "$fails" -eq 0 ] || { echo "FAIL: $fails check(s) failed"; exit 1; }
echo "all passed"
