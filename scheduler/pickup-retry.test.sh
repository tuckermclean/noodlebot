#!/bin/sh
# Tests what pickup.py does over several applies (S09, slice 2 review: S09-AC-1, S09-AC-3), over the fake forge:
#   sh scheduler/pickup-retry.test.sh   (make test)
# It uses the fixtures and the approach of scheduler/pickup.test.sh (scheduler/testdata/pickup/), which stays under its budget.
#
# THE CONTRACT these cases add to the one in pickup.test.sh (and feedback.test.sh):
#
# F1. A session of the PR unit that is running owns its FEEDBACK.md. `feedback.py ... add N ITEMFILE` for an open bot PR whose
#     unit has a running session writes nothing (FEEDBACK.md and starts as they were, no unit folder made) and exits 3 ("busy",
#     one line on stderr, nothing on stdout). A session runs when node/<ID>/session.pid (a node's PR), pr/<N>/session.pid (a spec
#     PR's own session, or an update of a node's PR) exists, as the loop's fb_blocked takes it; the loop's other blocks (a
#     question open, FAILED, WAITING-PR) are not feedback.py's business: the item then waits in FEEDBACK.md for the loop.
#     In pickup.py a feedback decision whose add is busy is not finished: no reply, the item is not handled, nothing is logged
#     as refused, FEEDBACK.md and starts are as they were; the other items of the run are carried out and replied to as usual.
#     `apply` exits 1 while an item waits so. The next `apply --run D`, or the next `run` (which retries the unfinished runs
#     before it looks for new items), hands the item over once the session is gone (session.pid removed), replies exactly once
#     (the reply of a hand-over) and handles it. No new run is started for an item that waits.
# F2. report.py --pickup leaves to pickup an UNPREFIXED owner comment on the log issue (no node waiting, or several); a log-issue
#     comment with an ID prefix ("A01: ...") keeps report.py's own reply ("Not recorded as an answer: no node is waiting ...")
#     when no node waits, and gets no pending file.
# F4. An accepted decision whose step fails for good ends as a refusal. A failure is permanent when feedback.py add exits 1 (the
#     PR is no longer an open bot PR of open-prs.tsv, the item file unreadable); busy (exit 3) is not, nor is any other error
#     (an exception, a forge call failing): those are retried by the next apply. A permanent failure: the item's pending reply
#     (report.py's deterministic reply, signed) is posted once, one line "pickup.py: refused <item url>: <reason>" is on stderr,
#     the item is handled, nothing else changes (no FEEDBACK.md, starts as they were); it is not retried again.
# F5. An answer is recorded once. (a) +1 failing after the reply was posted: the next apply retries only the +1: no second reply,
#     ANSWER.md not written again (same bytes, same mtime), no second milestone. (b) A replayed decision (the run's record of its
#     steps lost, `state.json` removed) does not record the answer again: when the unit's ANSWER.md already holds the comment's
#     URL on report.py's record line the answer counts as recorded, it is not refused for the unit having no question open
#     any more, ANSWER.md is not written again, no second milestone; the reply is posted unless the item is in
#     DIR/pickup/handled, and then the replay does nothing at all (no second reply, nothing logged as refused).
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
okx() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }   # okx <name> <shell expression>
T=$src/testdata/pickup
S9=$tmp/S09
AUX=$S9/aux
mkdir -p "$AUX"
tool() { python3 -I "$T/tool.py" "$@"; }

mkworld() {
	mkdir -p "$S9/$1/cwd" "$S9/$1/wt" "$S9/$1/clone" "$S9/$1/data/state"
	cp -R "$T/forge" "$S9/$1/fk"
	cp -R "$T/state" "$S9/$1/data/state/fk"
	git -C "$S9/$1/clone" init -q 2>/dev/null
	git -C "$S9/$1/clone" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init 2>/dev/null
}
use() { W=$S9/$1; FK=$W/fk; ST=$W/data/state/fk; export W FK ST; }
rp() {
	NOODLEBOT_NOW=2026-06-01T12:00:00 python3 -I "$src/report.py" --repo "fake:$FK" --state "$ST" --owner owner \
		--worktrees "$W/wt" --clone "$W/clone" --version 9.9 --signature SIG-9 "$@"
}
pk() {
	(cd "$W/cwd" && SCHED_HARNESS=fake FAKE_HARNESS_SMALL_SCRIPT=$AUX/script.events FAKE_HARNESS_LOG=$AUX/harness.log \
		PICKUP_RUNS=1000 python3 -I "$src/pickup.py" --repo "fake:$FK" --state "$ST" --owner owner --clone "$W/clone" \
		--worktrees "$W/wt" --version 9.9 --signature SIG-9 "$@")
}
# runit: pickup.py run; RC, RUN (the run's name), RUNDIR, stdout in $AUX/run.out, stderr in $AUX/run.err
runit() {
	pk run >"$AUX/run.out" 2>"$AUX/run.err"; RC=$?
	RUN=$(sed -n 's/^pickup run \([^: ]*\):.*/\1/p' "$AUX/run.out" | tail -n1)
	RUNDIR=$ST/pickup/${RUN:-none-}
}
script() { tool script "$AUX/script.events" "$@"; }
nsmall() { n=$(grep -c '^small ' "$AUX/harness.log" 2>/dev/null); echo "${n:-0}"; }
handled() { grep -qx "$1" "$ST/pickup/handled" 2>/dev/null; }
clause() { rp --clause "$1" 2>/dev/null; }
reply_has() { issue=$1; url=$2; shift 2; b=$(tool reply "$FK" "$issue" "$url"); [ -n "$b" ] || return 1
	for w in "$@"; do printf '%s' "$b" | grep -qiF -- "$w" || return 1; done; }
ids_of() { tool json "$1" "' '.join(sorted(str(i['id']) for i in d['items']))"; }
all_logged() { err=$1; shift; test "$(tool logged "$err" "$FK" "$@")" = True; }
# cmt_rm <id> <file> / cmt_put <file>: take a comment out of the fake forge's comments (its thread stays) and put it back
cmt_rm() { python3 -I -c '
import json, sys
fk, i, out = sys.argv[1:4]
p = fk + "/comments.json"
d = json.load(open(p))
saved = []
for k, l in d.items():
    for c in list(l):
        if c["id"] == int(i):
            saved.append([k, c]); l.remove(c)
json.dump(saved, open(out, "w")); json.dump(d, open(p, "w"))' "$FK" "$1" "$2"; }
cmt_put() { python3 -I -c '
import json, sys
fk, saved = sys.argv[1:3]
p = fk + "/comments.json"
d = json.load(open(p))
for k, c in json.load(open(saved)):
    d[k].append(c); d[k].sort(key=lambda c: c["id"])
json.dump(d, open(p, "w"))' "$FK" "$1"; }
mt() { stat -c '%y %s' "$1" 2>/dev/null; }

# =================================================================================================================
echo "== F2: a prefixed log-issue comment is report.py's, an unprefixed one is pickup's"
mkworld R; use R
rp >/dev/null 2>&1; rp >/dev/null 2>&1
for u in A01 B02 C03 D04 E05; do
	printf "# Answer to %s QUESTION.md\n\nThe owner's answer, posted by owner on GitHub at 2026-06-01T11:00:00Z: fake://owner/repo/issues/1#c1\n" "$u" >"$ST/node/$u/ANSWER.md"
done
L=$(tool logissue "$FK")
f1=$(tool addc "$FK" "$L" owner 1 0 "A01: a prefixed comment while no node waits")
f2=$(tool addc "$FK" "$L" owner 1 0 "an unprefixed comment while no node waits")
cp -Rp "$W" "$S9/Rctl"; use Rctl; rp >/dev/null 2>&1; use R; CK=$S9/Rctl/fk
rp --pickup >/dev/null 2>&1; rc=$?
ok "S09-AC-1: (the control, report.py without --pickup, replies to both log-issue comments, no node waiting)" test "$(tool notrec "$CK" | grep -c "^$L ")" = 2
ok "S09-AC-1: report.py --pickup runs" test "$rc" = 0
ok "S09-AC-1: the unprefixed comment is the only pending one (no pending file for the prefixed comment)" \
	test "$(ls "$ST/pickup/pending" 2>/dev/null | tr '\n' ' ')" = "$f2.json "
ok "S09-AC-1: the prefixed comment keeps report.py's own reply (the same text as without --pickup), the unprefixed one gets none" \
	test "$(tool notrec "$FK" | grep -c "^$L ")" = 1 -a "$(tool notrec "$FK")" = "$(tool notrec "$CK" "$L:no node is waiting")"
pk items >"$AUX/items.json" 2>/dev/null
ok "S09-AC-1: items lists only the unprefixed comment" test "$(ids_of "$AUX/items.json")" = "$f2"

# =================================================================================================================
echo "== F1: feedback for a PR whose unit's session runs waits for the session to end"
mkworld X; use X
rp >/dev/null 2>&1; rp >/dev/null 2>&1
printf "# Answer to C03 QUESTION.md\n\nThe owner's answer, posted by owner on GitHub at 2026-06-01T11:00:00Z: fake://owner/repo/issues/13#c1\n" >"$ST/node/C03/ANSWER.md"
rp >/dev/null 2>&1
L=$(tool logissue "$FK")
x1=$(tool addc "$FK" 14 owner 1 0 "busy: feedback for PR 20 (node session running)")
x2=$(tool addc "$FK" 14 owner 1 0 "busy: feedback for PR 26 (its own session running)")
x3=$(tool addc "$FK" 13 owner 1 0 "busy: a note next to them")
rp --pickup >/dev/null 2>&1
ux1=$(tool url "$FK" "$x1"); ux2=$(tool url "$FK" "$x2"); ux3=$(tool url "$FK" "$x3")
mkdir -p "$ST/pr/26"; echo 4242 >"$ST/node/F06/session.pid"; echo 4243 >"$ST/pr/26/session.pid"
script "$(printf '[{"item": %s, "action": "feedback", "pr": 20, "reason": "r"}, {"item": %s, "action": "feedback", "pr": 26, "reason": "r"}, {"item": %s, "action": "note", "reason": "r"}]' "$x1" "$x2" "$x3")"
runit
ok "S09-AC-3: a run with feedback for PRs whose sessions run: runs once, exits 1 (two items wait)" test "$RC" = 1 -a -d "$RUNDIR" -a "$(nsmall)" = 1
ok "S09-AC-3: busy: node/F06/FEEDBACK.md is not written, its starts stay 2 (the session's counter)" test ! -e "$ST/node/F06/FEEDBACK.md" -a "$(cat "$ST/node/F06/starts")" = 2
ok "S09-AC-3: busy: pr/26/ has no FEEDBACK.md and no starts (only the session's pid)" test ! -e "$ST/pr/26/FEEDBACK.md" -a ! -e "$ST/pr/26/starts"
ok "S09-AC-3: busy: no reply to either item, neither is handled" \
	sh -c '[ "$(python3 -I "$1" count "$2" 14 "$3")" = 0 ] && [ "$(python3 -I "$1" count "$2" 14 "$4")" = 0 ] && [ "$(python3 -I "$1" nbot "$2" 14)" = "$5" ] && ! grep -qxE "$6|$7" "$8" 2>/dev/null' \
		_ "$T/tool.py" "$FK" "$ux1" "$ux2" "$(tool nbot "$FK" 14)" "$x1" "$x2" "$ST/pickup/handled"
ok "S09-AC-3: busy: a wait is not a refusal (nothing logged as refused for them)" test -d "$RUNDIR" -a "$(grep -ci refused "$AUX/run.err")" = 0
ok "S09-AC-3: the note of the same run was carried out and replied to once, and is handled" \
	sh -c '[ "$(python3 -I "$1" count "$2" 13 "$3")" = 1 ] && grep -qx "$4" "$5"' _ "$T/tool.py" "$FK" "$ux3" "$x3" "$ST/pickup/handled"
runit
ok "S09-AC-3: another tick while the sessions run: no new run, still no FEEDBACK.md, no reply" \
	test -z "$RUN" -a "$(nsmall)" = 1 -a ! -e "$ST/node/F06/FEEDBACK.md" -a ! -e "$ST/pr/26/FEEDBACK.md" -a "$(tool count "$FK" 14 "$ux1")" = 0
RUNX=$(ls -d "$ST"/pickup/2* | head -n1)
rm -f "$ST/node/F06/session.pid" "$ST/pr/26/session.pid"
pk apply --run "$RUNX" >/dev/null 2>"$AUX/x.err"; rc=$?
ok "S09-AC-3: the sessions gone, the next apply exits 0" test "$rc" = 0
ok "S09-AC-3: ... the items are in FEEDBACK.md (once each) and the starts are reset to 0" \
	sh -c '[ "$(grep -c "^url: $1\$" "$3")" = 1 ] && [ "$(grep -c "^url: $2\$" "$4")" = 1 ] && [ "$(cat "$5")" = 0 ]' _ "$ux1" "$ux2" "$ST/node/F06/FEEDBACK.md" "$ST/pr/26/FEEDBACK.md" "$ST/node/F06/starts"
ok "S09-AC-3: ... one reply each, with the PR and the clause" reply_has 14 "$ux1" "#20" "$(clause F06)"
ok "S09-AC-3: ... (the spec PR's too)" reply_has 14 "$ux2" "#26" "$(clause 'PR #26')"
ok "S09-AC-3: ... exactly one each" test "$(tool count "$FK" 14 "$ux1")" = 1 -a "$(tool count "$FK" 14 "$ux2")" = 1
ok "S09-AC-3: ... and both are handled" sh -c 'grep -qx "$1" "$3" && grep -qx "$2" "$3"' _ "$x1" "$x2" "$ST/pickup/handled"
cp "$ST/node/F06/FEEDBACK.md" "$AUX/f06.fb1"
pk apply --run "$RUNX" >/dev/null 2>&1
okx "S09-AC-3: a further apply does nothing twice (replies, FEEDBACK.md)" '[ "$(tool count "$FK" 14 "$ux1")" = 1 ] && [ "$(tool count "$FK" 14 "$ux2")" = 1 ] && cmp -s "$AUX/f06.fb1" "$ST/node/F06/FEEDBACK.md"'

# a second item for PR 20, while an update session of the same PR (pr/20/) runs; the next tick (no new items) hands it over
x4=$(tool addc "$FK" 14 owner 1 0 "busy: feedback for PR 20 (its update session running)")
rp --pickup >/dev/null 2>&1; ux4=$(tool url "$FK" "$x4")
mkdir -p "$ST/pr/20"; echo 4244 >"$ST/pr/20/session.pid"; echo 1 >"$ST/node/F06/starts"
script "$(printf '[{"item": %s, "action": "feedback", "pr": 20, "reason": "r"}]' "$x4")"
runit
okx "S09-AC-3: feedback for a node's PR while its update session (pr/20/session.pid) runs: FEEDBACK.md and starts as they were, no reply, not handled" \
	'[ -d "$RUNDIR" ] && [ -n "$RUN" ] && cmp -s "$AUX/f06.fb1" "$ST/node/F06/FEEDBACK.md" && [ "$(cat "$ST/node/F06/starts")" = 1 ] && [ "$(tool count "$FK" 14 "$ux4")" = 0 ] && ! handled "$x4"'
rm -f "$ST/pr/20/session.pid"
pk run >"$AUX/run2.out" 2>"$AUX/run2.err"; rc=$?
ok "S09-AC-3: the next tick (no new items, no new run) retries it: handed over once, starts 0, one reply, handled" \
	sh -c '[ "$1" = 0 ] && [ ! -s "$2" ] && [ "$(grep -c "^url: $3\$" "$4")" = 1 ] && [ "$(cat "$5")" = 0 ] && [ "$(python3 -I "$6" count "$7" 14 "$3")" = 1 ] && grep -qx "$8" "$9"' \
		_ "$rc" "$AUX/run2.out" "$ux4" "$ST/node/F06/FEEDBACK.md" "$ST/node/F06/starts" "$T/tool.py" "$FK" "$x4" "$ST/pickup/handled"
ok "S09-AC-3: ... and the earlier items of FEEDBACK.md are still there once" test "$(grep -c "^url: $ux1\$" "$ST/node/F06/FEEDBACK.md")" = 1 -a "$(grep -c '^kind: ' "$ST/node/F06/FEEDBACK.md")" = 2

# =================================================================================================================
echo "== F4: an accepted decision whose step fails for good ends as a refusal"
mkworld Y; use Y
rp >/dev/null 2>&1; rp >/dev/null 2>&1
y1=$(tool addc "$FK" 14 owner 1 0 "closed: feedback for PR 20, which closes while its session runs")
cp -Rp "$W" "$S9/Yctl"; use Yctl; rp >/dev/null 2>&1; use Y; CK=$S9/Yctl/fk
rp --pickup >/dev/null 2>&1; uy1=$(tool url "$FK" "$y1")
echo 4242 >"$ST/node/F06/session.pid"
script "$(printf '[{"item": %s, "action": "feedback", "pr": 20, "reason": "r"}]' "$y1")"
runit
okx "S09-AC-3: (the first run: PR 20 is open, its session runs: the item waits, no reply)" '[ -d "$RUNDIR" ] && [ "$(tool nbot "$FK" 14)" = "$(tool nbot "$CK" 14)" ] && ! handled "$y1"'
grep -v '^20 ' "$ST/open-prs.tsv" >"$ST/open-prs.new" && mv "$ST/open-prs.new" "$ST/open-prs.tsv"
rm -f "$ST/node/F06/session.pid"
pk apply --run "$RUNDIR" >/dev/null 2>"$AUX/y.err"; rc=$?
ok "S09-AC-4: the retry, PR 20 gone from open-prs.tsv: the item's deterministic reply is posted once (report.py's text), it exits 0" \
	test "$rc" = 0 -a "$(tool notrec "$FK" | grep -c '^14 ')" = 1 -a "$(tool notrec "$FK")" = "$(tool notrec "$CK" 14)"
ok "S09-AC-4: ... the refusal is logged on stderr with the item's URL" all_logged "$AUX/y.err" "$y1"
ok "S09-AC-4: ... the item is handled" handled "$y1"
ok "S09-AC-4: ... nothing was handed over (no FEEDBACK.md, starts as they were)" test ! -e "$ST/node/F06/FEEDBACK.md" -a "$(cat "$ST/node/F06/starts")" = 2
pk apply --run "$RUNDIR" >/dev/null 2>"$AUX/y2.err"; rc=$?
runit
ok "S09-AC-4: not retried again: a further apply and tick post nothing, log nothing, start no run" \
	test "$rc" = 0 -a "$(tool nbot "$FK" 14)" = "$(( $(tool nbot "$CK" 14) + 1 ))" -a "$(grep -ci refused "$AUX/y2.err")" = 0 -a -z "$RUN" -a "$(nsmall)" = 1 -a ! -s "$AUX/run.out"

# =================================================================================================================
echo "== F5: an answer is recorded once"
mkworld Z; use Z
rp >/dev/null 2>&1; rp >/dev/null 2>&1
printf "# Answer to C03 QUESTION.md\n\nThe owner's answer, posted by owner on GitHub at 2026-06-01T11:00:00Z: fake://owner/repo/issues/13#c1\n" >"$ST/node/C03/ANSWER.md"
rp >/dev/null 2>&1
z1=$(tool addc "$FK" 13 owner 1 0 "retry: the +1 fails after the reply")
z0=$(tool addc "$FK" 14 mallory 0 0 "a later comment, so that the next ids are not z1's")
rp --pickup >/dev/null 2>&1; uz1=$(tool url "$FK" "$z1")
script "$(printf '[{"item": %s, "action": "answer", "unit": "A01", "reason": "r"}]' "$z1")"
cmt_rm "$z1" "$AUX/z1.saved"      # the comment is gone from the forge: the +1 fails, the reply (a new comment) does not
runit
ok "S09-AC-3: a +1 that fails: the run exits 1, A01's answer is recorded once and the reply posted once" \
	test "$RC" = 1 -a "$(tool react "$FK" "$z1")" = 0 -a "$(tool count "$FK" 13 "$uz1")" = 1 -a "$(grep -c "$uz1" "$ST/node/A01/ANSWER.md")" = 1
okx "S09-AC-3: ... and the item is not handled yet" '[ -d "$RUNDIR" ] && ! handled "$z1"'
cp "$ST/node/A01/ANSWER.md" "$AUX/a01.ans"; m0=$(mt "$ST/node/A01/ANSWER.md"); n13=$(tool nbot "$FK" 13)
nm0=$(tool count "$FK" 11 "answer received"); nn11=$(tool nbot "$FK" 11)
cmt_put "$AUX/z1.saved"
pk apply --run "$RUNDIR" >/dev/null 2>&1; rc=$?
okx "S09-AC-3: the next apply retries the +1 (exit 0, one +1, handled)" '[ "$rc" = 0 ] && [ "$(tool react "$FK" "$z1")" = 1 ] && [ "$(tool nreact "$FK")" = 1 ] && handled "$z1"'
ok "S09-AC-3: ... and posts no second reply (thread 13 has the comments it had, one with the URL)" test "$(tool nbot "$FK" 13)" = "$n13" -a "$(tool count "$FK" 13 "$uz1")" = 1
ok "S09-AC-3: ... and does not write ANSWER.md again (same content, same mtime)" \
	sh -c 'cmp -s "$1" "$2" && [ "$3" = "$4" ]' _ "$AUX/a01.ans" "$ST/node/A01/ANSWER.md" "$(mt "$ST/node/A01/ANSWER.md")" "$m0"
ok "S09-AC-3: ... no second milestone (issue 11 as it was)" test "$(tool count "$FK" 11 "answer received")" = "$nm0" -a "$(tool nbot "$FK" 11)" = "$nn11"

# (b) the replay of a decision whose answer is recorded: the run's record of its steps is lost
snapz() { echo "$(tool nbot "$FK" 13) $(tool nbot "$FK" 11) $(tool nreact "$FK") $(tool count "$FK" 13 "Not recorded") $(mt "$ST/node/A01/ANSWER.md")"; }
rm -f "$RUNDIR/state.json"; s0=$(snapz)
pk apply --run "$RUNDIR" >/dev/null 2>"$AUX/z.err"; rc=$?
ok "S09-AC-3: a handled item: replaying the run (its state.json removed) posts nothing, reacts to nothing, writes nothing" \
	test "$(snapz)" = "$s0" -a "$(tool count "$FK" 13 "Not recorded")" = 0
ok "S09-AC-3: ... logs no refusal, exits 0, ANSWER.md as it was" \
	sh -c '[ "$1" = 0 ] && [ "$(grep -ci refused "$2")" = 0 ] && cmp -s "$3" "$4"' _ "$rc" "$AUX/z.err" "$AUX/a01.ans" "$ST/node/A01/ANSWER.md"

z2=$(tool addc "$FK" 14 owner 1 0 "retry: the reply fails, the state is lost")
rp --pickup >/dev/null 2>&1; uz2=$(tool url "$FK" "$z2")
script "$(printf '[{"item": %s, "action": "answer", "unit": "B02", "reason": "r"}]' "$z2")"
tool rmissue "$FK" 14
runit
ok "S09-AC-3: an answer whose reply cannot be posted: recorded (B02's ANSWER.md), +1 put, exit 1" \
	test "$RC" = 1 -a -d "$RUNDIR" -a "$(grep -c "$uz2" "$ST/node/B02/ANSWER.md")" = 1 -a "$(tool react "$FK" "$z2")" = 1
tool putissue "$FK" 14
cp "$ST/node/B02/ANSWER.md" "$AUX/b02.ans"; m1=$(mt "$ST/node/B02/ANSWER.md"); nmb=$(tool count "$FK" 12 "$uz2"); nb14=$(tool nbot "$FK" 14)
rm -f "$RUNDIR/state.json"
pk apply --run "$RUNDIR" >/dev/null 2>"$AUX/z2.err"; rc=$?
ok "S09-AC-3: the decision replayed after ANSWER.md was recorded: not recorded again (same bytes, same mtime, no answered/ copy)" \
	sh -c 'cmp -s "$1" "$2" && [ "$3" = "$4" ] && [ ! -e "$5" ]' _ "$AUX/b02.ans" "$ST/node/B02/ANSWER.md" "$(mt "$ST/node/B02/ANSWER.md")" "$m1" "$ST/node/B02/answered"
ok "S09-AC-3: ... no second milestone (B02's issue 12 holds the URL once)" test "$nmb" = 1 -a "$(tool count "$FK" 12 "$uz2")" = 1
ok "S09-AC-3: ... not refused for the unit having no question open any more (no 'Not recorded' reply, nothing logged as refused)" \
	test "$(tool count "$FK" 14 "Not recorded")" = 0 -a "$(grep -ci refused "$AUX/z2.err")" = 0
okx "S09-AC-3: ... the reply is posted once (on thread 14, with the URL), the item is handled, exit 0" \
	'[ "$rc" = 0 ] && [ "$(tool count "$FK" 14 "$uz2")" = 1 ] && [ "$(tool nbot "$FK" 14)" = "$((nb14 + 1))" ] && handled "$z2"'

[ "$fails" -eq 0 ] || { echo "FAIL: $fails check(s) failed"; exit 1; }
echo "all passed"
