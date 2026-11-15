#!/bin/sh
# Tests scheduler/pickup.py and report.py --pickup (S09, slice 2: S09-AC-1, S09-AC-3, S09-AC-4), over the fake forge.
#   sh scheduler/pickup.test.sh   (make test)
# The budget and the ceiling (S09-AC-5) are slice 3's: its cases are appended to this file. These cases keep the budget out
# of the way: no usage.json in the state root, PICKUP_RUNS=1000 in the environment.
#
# THE CONTRACT these tests fix (the fake forge is scheduler/testdata/forge/, the fixtures scheduler/testdata/pickup/):
#
# 1. report.py --pickup (a new flag; without it report.py is exactly as before and writes no DIR/pickup/ folder).
#    The owner comments report.py cannot place are not answered with "Not recorded as an answer: ...": each is written
#    to DIR/pickup/pending/<comment id>.json (once), one JSON object:
#      id (int), url, issue (int, the thread: the unit's home issue or the log issue), where ("home" | "log"),
#      created_at, author {login, is_bot, is_owner}, body (the comment's text), reply (the text report.py would have
#      posted, unsigned: the posted comment is reply + "\n\n" + the signature + "\n", as report.py signs).
#    Exactly these are left: on a home issue, "no question is waiting on this issue" and "more than one unit is waiting
#    ... (no matching prefix)"; on the log issue, an owner comment with no ID prefix when no node or several wait.
#    A prefix naming a unit that is not waiting (a placed case: "B02 has no question waiting on this issue", "Z99 is not
#    waiting on a question") keeps report.py's own reply; an answer report.py places is recorded as before.
#
# 2. python3 -I pickup.py --repo SPEC --state DIR --owner LOGIN [--clone DIR] [--worktrees DIR] [--version V]
#    [--signature S] <command>; SPEC is the forge (here fake:<folder>; nothing is taken from the shape of "owner/name");
#    DIR is state/<name>, its parent the state root; the open PRs are DIR/open-prs.tsv (feedback.py's format). Commands:
#      items          stdout: one JSON object {"items": [...], "questions": [...], "prs": [...], "units": [...]}, exit 0.
#                     An item: {"id": comment id, "url", "issue", "text": the comment's body}. The items are the pending
#                     files minus: a comment whose URL is on the record line of a unit's ANSWER.md or answered/*-ANSWER.md
#                     (feedback.py's answer_urls rule: a URL inside an answer's own text is no record), a comment whose
#                     URL is in a unit's FEEDBACK.md or answered/*-FEEDBACK.md (node/<ID>/ and pr/<N>/), a comment whose
#                     author is not the owner (login, is_owner, not a bot), and an id in DIR/pickup/handled (one comment
#                     id per line). questions: the open questions (their unit's ID appears in the entry); prs: the open
#                     bot PRs (the number appears in the entry); units: the units' IDs.
#      run            one tick's step: nothing printed and no run when there are no items; otherwise one run in
#                     DIR/pickup/<name>/ (name: a UTC timestamp with no ':' or space, unique) through the harness's
#                     small-model start (harness.py small-start <run dir> <run dir>/prompt.md; the prompt holds each
#                     item's text and URL and the open questions), then the apply below. stdout, one line:
#                     "pickup run <name>: items [<item url>...]; decisions [...]; cost $X". Exit code: apply's.
#      apply --run D  reads the run D (its items, saved when it started, and D/events.jsonl through the harness) and
#                     carries out its decisions; run on a run again does nothing twice. Exit 0 when every item got its
#                     reply; 1 when a post failed (retried by the next apply); 2 usage. apply reads nothing from an
#                     item's thread (the item is in the run): a thread the forge cannot find only fails the reply.
#    Output of a run: the last `result` event's text, whole, is a JSON list, one object per item:
#      {"item": <comment id or url>, "action": "answer"|"feedback"|"request"|"note", "unit": "<ID>" (answer),
#       "pr": N (feedback), "title": "..." (request), "reason": "one line"}.
#    Refused: a decision naming a unit with no open question (waiting: QUESTION.md without ANSWER.md), an unknown PR (not
#    an open bot PR of DIR/open-prs.tsv on node/<ID>-... or spec/...), an action outside the four: that decision only;
#    a run with any `tool` event, or whose text is not a JSON list, or has an item with no decision, or a decision of an
#    item that is not in the run: all its decisions. A refused item gets report.py's reply (its pending file's reply, signed),
#    one line on stderr "pickup.py: refused <item url>: <reason>", and is handled; nothing else changes.
#    Accepted, once per item however many applies (the item is recorded as done before its reply):
#      answer   node/<ID>/ANSWER.md written as report.py's record_answer writes it (the line "The owner's answer, posted by
#               <login> on GitHub at <time>: <URL>"), a +1 reaction on the comment, the milestone "**Stage:** answer
#               received, <clause>" on the unit's home issue with the URL;
#      feedback feedback.py ... add <PR> <item file> (feedback.test.sh): the item in node/<ID>/FEEDBACK.md or
#               pr/<N>/FEEDBACK.md, the unit's starts reset to 0;
#      request  one new issue, no label, whose title holds the decision's title and whose body quotes the comment and links
#               its URL;
#      note     nothing.
#    Then one reply on the item's thread (signed), the item's URL in it: answer: the unit's ID and `report.py --clause
#    <ID>`; feedback: "#<PR>" and the clause of the PR's unit (<ID>, or "PR #<N>" for a spec PR); request: the new issue
#    ("#<N>") and the word `noodlebot` (the label the owner adds); note: "nothing" (case does not matter). Then the id goes
#    into DIR/pickup/handled. A failed post leaves the id out; the next apply posts the reply without redoing the action.
#    No commit, push, PR, label change; nothing written outside DIR (the cwd, --clone and --worktrees stay as they are).
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
S9=$tmp/S09
AUX=$S9/aux
mkdir -p "$AUX"
tool() { python3 -I "$T/tool.py" "$@"; }

# mkworld <name>: a fake forge, a state folder and an empty clone, cwd and worktrees folder under $S9/<name>
mkworld() {
	mkdir -p "$S9/$1/cwd" "$S9/$1/wt" "$S9/$1/clone" "$S9/$1/data/state"
	cp -R "$T/forge" "$S9/$1/fk"
	cp -R "$T/state" "$S9/$1/data/state/fk"
	git -C "$S9/$1/clone" init -q 2>/dev/null
	git -C "$S9/$1/clone" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init 2>/dev/null
}
# use <name>: the world the functions below work on
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
script() { tool script "$AUX/script.events" "$@"; }   # script <result text> [tool]
nsmall() { n=$(grep -c '^small ' "$AUX/harness.log" 2>/dev/null); echo "${n:-0}"; }
all_handled() { for i in "$@"; do handled "$i" || return 1; done; }
all_logged() { err=$1; shift; test "$(tool logged "$err" "$FK" "$@")" = True; }
has_ref() { b=$(tool reply "$FK" "$1" "$2"); echo "$b" | grep -qE "#$3([^0-9]|\$)|issues/$3([^0-9]|\$)" && echo "$b" | grep -qF noodlebot; }
handled() { grep -qx "$1" "$ST/pickup/handled" 2>/dev/null; }
clause() { rp --clause "$1" 2>/dev/null; }
# the whole of a reply contains these words (a reply: the bot's comment on ISSUE that holds URL)
reply_has() { issue=$1; url=$2; shift 2; b=$(tool reply "$FK" "$issue" "$url"); [ -n "$b" ] || return 1
	for w in "$@"; do printf '%s' "$b" | grep -qiF -- "$w" || return 1; done; }
reply_has_exact() { issue=$1; url=$2; shift 2; b=$(tool reply "$FK" "$issue" "$url"); [ -n "$b" ] || return 1
	for w in "$@"; do printf '%s' "$b" | grep -qF -- "$w" || return 1; done; }
ids_of() { tool json "$1" "' '.join(sorted(str(i['id']) for i in d['items']))"; }
# needrun <n> cmd...: cmd, but only once at least n pickup runs have started (a missing pickup.py must not pass a "nothing changed" check)
needrun() { n=$1; shift; [ "$(nsmall)" -ge "$n" ] || return 1; "$@"; }
# not_listed <regex of ids>: pickup.py items printed a list (items.json parsed) and none of these ids is in it
not_listed() { l=$(ids_of "$AUX/items.json"); [ "$l" != ERROR ] && [ -n "$l" ] && ! echo " $l " | grep -qE " ($1) "; }
sorted_ids() { printf '%s\n' "$@" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }

ok "S09: scheduler/pickup.py exists" test -f "$src/pickup.py"

# =================================================================================================================
echo "== S09-AC-1: what report.py leaves to the pickup step, and pickup.py items"
mkworld I; use I
rp >/dev/null 2>&1; rp >/dev/null 2>&1                     # the questions of A01 B02 C03 D04 E05 are posted
printf '# Answer to C03 QUESTION.md\n\nThe owner'"'"'s answer, posted by owner on GitHub at 2026-06-01T11:00:00Z: https://github.com/owner/repo/issues/13#issuecomment-9001\n\nfine, see https://github.com/owner/repo/issues/13#issuecomment-9009 for why\n' >"$ST/node/C03/ANSWER.md"
L=$(tool logissue "$FK")
i1=$(tool addc "$FK" 13 owner 1 0 "an owner comment where no question is open")
i2=$(tool addc "$FK" 14 owner 1 0 "an owner comment where two units wait")
i3=$(tool addc "$FK" "$L" owner 1 0 "an owner comment on the log issue with no prefix")
p1=$(tool addc "$FK" 11 owner 1 0 "B02: a prefix naming a unit that is not waiting here")
p2=$(tool addc "$FK" "$L" owner 1 0 "Z99: a prefix naming a unit that is not waiting")
a1=$(tool addc "$FK" 12 owner 1 0 "a plain answer to B02")
o1=$(tool addc "$FK" 13 mallory 0 0 "someone else's comment")
b1=$(tool addc "$FK" 13 "noodlebot[bot]" 0 1 "the bot's own comment")
cp -Rp "$W" "$S9/Ictl"
use Ictl; rp >/dev/null 2>&1; rcctl=$?; use I
rp --pickup >"$AUX/rp.out" 2>"$AUX/rp.err"; rc=$?
CK=$S9/Ictl/fk
ok "S09-AC-1: report.py --pickup runs (exit 0 or 3 for a recorded answer)" sh -c '[ "$1" = 0 ] || [ "$1" = 3 ]' _ "$rc"
ok "S09-AC-1: report.py without --pickup (the control) replies to every one of them as before" test "$(tool notrec "$CK" | wc -l)" = 5
ok "S09-AC-1: report.py without --pickup writes no pickup folder" test ! -e "$S9/Ictl/data/state/fk/pickup"
pend=$(ls "$ST/pickup/pending" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')
ok "S09-AC-1: --pickup leaves exactly three pending comments (no question open, two waiting, unprefixed log comment)" \
	test "$pend" = "$(printf '%s\n' "$i1.json" "$i2.json" "$i3.json" | LC_ALL=C sort | tr '\n' ' ')"
ok "S09-AC-1: --pickup posts no 'Not recorded' reply to the three (the placed cases keep theirs: one on 11, one on the log)" \
	test "$(tool notrec "$FK" | wc -l)" = 2 -a "$(tool notrec "$FK" "11" "$L:Z99" | wc -l)" = 0
ok "S09-AC-1: the placed replies are report.py's own (same texts as without --pickup)" \
	test "$(tool notrec "$FK" | sort)" = "$(tool notrec "$CK" "13" "14" "$L:more than one node" | sort)"
ok "S09-AC-1: a plain answer to the one open question is still recorded (B02 ANSWER.md, one +1)" \
	test -s "$ST/node/B02/ANSWER.md" -a "$(tool react "$FK" "$a1")" = 1
pf=$ST/pickup/pending/$i1.json
ok "S09-AC-1: a pending file holds id, url, issue, where, author and the comment's text" test "$(tool json "$pf" \
	"d['id'] == $i1 and d['url'] == '$(tool url "$FK" "$i1")' and d['issue'] == 13 and d['where'] == 'home' and d['author']['login'] == 'owner' and d['body'] == 'an owner comment where no question is open'")" = True
ok "S09-AC-1: a log-issue pending file says where: log, issue $L" test "$(tool json "$ST/pickup/pending/$i3.json" "d['where'] == 'log' and d['issue'] == $L")" = True
ok "S09-AC-1: the pending reply is the exact text report.py posts without --pickup (home, no question open)" \
	test "$(tool samereply "$pf" "$CK" 13 "Not recorded")" = True
ok "S09-AC-1: the pending reply is the exact text report.py posts without --pickup (home, two units waiting)" \
	test "$(tool samereply "$ST/pickup/pending/$i2.json" "$CK" 14 "Not recorded")" = True
ok "S09-AC-1: the pending reply is the exact text report.py posts without --pickup (log issue)" \
	test "$(tool samereply "$ST/pickup/pending/$i3.json" "$CK" "$L" "more than one node")" = True

# what pickup.py must not list: written by hand in the pending format (ids 9001.. of comments that report.py cannot have left)
mkdir -p "$ST/pickup/pending" "$ST/node/C03/answered" "$ST/pr/26/answered"
pend9() { # pend9 <id> <login> <is_owner> <is_bot>
	python3 -I -c '
import json, sys
i, login, owner, bot = int(sys.argv[1]), sys.argv[2], sys.argv[3] == "1", sys.argv[4] == "1"
json.dump({"id": i, "url": "https://github.com/owner/repo/issues/13#issuecomment-%d" % i, "issue": 13, "where": "home", "created_at": "2026-06-02T11:00:00Z",
           "author": {"login": login, "is_bot": bot, "is_owner": owner}, "body": "pending %d" % i,
           "reply": "Not recorded as an answer: no question is waiting on this issue."}, open(sys.argv[5], "w"))' \
		"$1" "$2" "$3" "$4" "$ST/pickup/pending/$1.json"
}
for n in 9001 9002 9003 9004 9007 9008 9009; do pend9 "$n" owner 1 0; done
pend9 9005 mallory 0 0; pend9 9006 "noodlebot[bot]" 0 1
printf "The owner's answer, posted by owner on GitHub at 2026-06-01T10:00:00Z: https://github.com/owner/repo/issues/13#issuecomment-9002\n" >"$ST/node/C03/answered/20260601T000000Z-ANSWER.md"
printf '# Feedback\n\nPR: 20\nBranch: node/F06-thing\n\nkind: conversation\nid: 9003\nurl: https://github.com/owner/repo/issues/13#issuecomment-9003\nauthor: owner\ntime: 2026-06-01T10:00:00Z\nbody: x\n' >"$ST/node/F06/FEEDBACK.md"
printf '# Feedback\n\nPR: 26\nBranch: spec/triage-5-thing\n\nkind: conversation\nid: 9004\nurl: https://github.com/owner/repo/issues/13#issuecomment-9004\nauthor: owner\ntime: 2026-06-01T10:00:00Z\nbody: x\n' >"$ST/pr/26/answered/20260601T000000Z-FEEDBACK.md"
echo 9007 >"$ST/pickup/handled"
pk items >"$AUX/items.json" 2>"$AUX/items.err"; rc=$?
ok "S09-AC-1: pickup.py items exits 0 and prints one JSON object with items, questions, prs, units" test "$rc" = 0 -a "$(tool json "$AUX/items.json" "sorted(d) == ['items', 'prs', 'questions', 'units']")" = True
ok "S09-AC-1: items lists the three comments report.py left, and a clean pending file, and a URL that is only in an answer's text" \
	test "$(ids_of "$AUX/items.json")" = "$(sorted_ids "$i1" "$i2" "$i3" 9008 9009)"
ok "S09-AC-1: not listed: recorded as an answer (ANSWER.md; answered/*-ANSWER.md), as feedback (FEEDBACK.md; answered/*-FEEDBACK.md)" \
	not_listed '9001|9002|9003|9004'
ok "S09-AC-1: not listed: another user's comment, the bot's own, an item already handled" \
	not_listed "9005|9006|9007|$o1|$b1"
ok "S09-AC-1: an item holds its id, url, issue and text" test "$(tool json "$AUX/items.json" "[i for i in d['items'] if i['id'] == $i2][0] == {'id': $i2, 'url': '$(tool url "$FK" "$i2")', 'issue': 14, 'text': 'an owner comment where two units wait'}" | head -c 4)" = True
ok "S09-AC-1: items carries the open questions (A01 D04 E05; not the answered B02 or C03)" \
	test "$(tool json "$AUX/items.json" "[u for u in ('A01', 'D04', 'E05') if u in json.dumps(d['questions'])] == ['A01', 'D04', 'E05'] and 'B02' not in json.dumps(d['questions']) and 'C03' not in json.dumps(d['questions'])")" = True
ok "S09-AC-1: items carries the open bot PRs (20 and 26, not the human's 21) and the units (A01 C03 F06)" \
	test "$(tool json "$AUX/items.json" "'20' in json.dumps(d['prs']) and '26' in json.dumps(d['prs']) and '21' not in json.dumps(d['prs']) and all(u in json.dumps(d['units']) for u in ('A01', 'C03', 'F06'))")" = True

# =================================================================================================================
echo "== S09-AC-3, S09-AC-4: the decisions carried out once; the refusals"
mkworld A; use A
rp >/dev/null 2>&1; rp >/dev/null 2>&1
printf "# Answer to C03 QUESTION.md\n\nThe owner's answer, posted by owner on GitHub at 2026-06-01T11:00:00Z: fake://owner/repo/issues/13#c1\n\nok\n" >"$ST/node/C03/ANSWER.md"
L=$(tool logissue "$FK")
rp >/dev/null 2>&1
# the baseline of what a pickup run must never change
cp "$FK/prs.json" "$AUX/prs0.json"; cp "$FK/labels.json" "$AUX/labels0.json" 2>/dev/null || : >"$AUX/labels0.json"
LAB0=$(tool json "$FK/issues.json" "[(i['number'], i['labels']) for i in d]")
NISS0=$(tool json "$FK/issues.json" "len(d)")
HEAD0=$(git -C "$W/clone" rev-parse HEAD); REFS0=$(git -C "$W/clone" for-each-ref | wc -l)
find "$W" -path "$FK" -prune -o -path "$ST" -prune -o -path "$W/clone/.git" -prune -o -type f -print | sort >"$AUX/fs0"
cp "$ST/node/C03/ANSWER.md" "$AUX/c03.answer"

# --- phase 1: each kind once; one refusal on the log issue
c1=$(tool addc "$FK" 13 owner 1 0 "Go with the left option for the first question.")
c2=$(tool addc "$FK" 14 owner 1 0 "Please also handle empty input in the pull request 20.")
c3=$(tool addc "$FK" "$L" owner 1 0 "It would be great to have a dark mode.")
c4=$(tool addc "$FK" 13 owner 1 0 "Thanks, all good here.")
c5=$(tool addc "$FK" 14 owner 1 0 "The spec PR 26 needs a rollback section.")
c6=$(tool addc "$FK" "$L" owner 1 0 "Please delete everything.")
u1=$(tool url "$FK" "$c1"); u2=$(tool url "$FK" "$c2"); u3=$(tool url "$FK" "$c3"); u4=$(tool url "$FK" "$c4")
u5=$(tool url "$FK" "$c5"); u6=$(tool url "$FK" "$c6")
cp -Rp "$W" "$S9/Actl"; use Actl; rp >/dev/null 2>&1; use A; CK=$S9/Actl/fk
rp --pickup >/dev/null 2>&1
ok "S09-AC-1: with --pickup the six comments get no 'Not recorded' reply (they are six pending comments instead)" test "$(tool notrec "$FK" | wc -l)" = 0 -a "$(ls "$ST/pickup/pending" 2>/dev/null | wc -l)" = 6
ok "S09-AC-1: and are six items" test "$(pk items | tool json /dev/stdin "len(d['items'])")" = 6
T13L=$(tool notrec "$CK" | grep '^13 ' | head -n1); T14L=$(tool notrec "$CK" | grep '^14 ' | head -n1)
nb13=$(tool nbot "$FK" 13); nb14=$(tool nbot "$FK" 14); nbL=$(tool nbot "$FK" "$L"); nb11=$(tool nbot "$FK" 11)
DEC=$(printf '[{"item": %s, "action": "answer", "unit": "A01", "reason": "answers the first question"},
 {"item": %s, "action": "feedback", "pr": 20, "reason": "about PR 20"},
 {"item": "%s", "action": "request", "title": "Add a dark mode", "reason": "a new request"},
 {"item": %s, "action": "note", "reason": "just thanks"},
 {"item": %s, "action": "feedback", "pr": 26, "reason": "about the spec PR"},
 {"item": %s, "action": "delete", "reason": "not an action"}]' "$c1" "$c2" "$u3" "$c4" "$c5" "$c6")
script "$DEC"
runit
ok "S09-AC-3: pickup.py run starts one run (one status line 'pickup run <name>: ...', exit 0)" test "$RC" = 0 -a -d "$RUNDIR" -a "$(grep -c '^pickup run ' "$AUX/run.out")" = 1
ok "S09-AC-3: the run went through the harness's small start once, and started no session" test "$(nsmall)" = 1 -a "$(grep -c '^start ' "$AUX/harness.log")" = 0
ok "S09-AC-3: the status line names every item by its URL" sh -c 'for u in "$@"; do grep -qF "$u" '"$AUX/run.out"' || exit 1; done' _ "$u1" "$u2" "$u3" "$u4" "$u5" "$u6"
ok "S09-AC-3: the prompt (prompt.md in the run) holds each comment's text and the open questions" sh -c 'for t in "left option" "empty input" "dark mode" "all good" "rollback" "delete everything" A01 D04; do grep -qF "$t" "$1/prompt.md" || exit 1; done' _ "$RUNDIR"
ok "S09-AC-3: an answer: ANSWER.md of A01 holds the comment's URL on report.py's record line, and the answer" \
	sh -c 'grep -q "^The owner'"'"'s answer, posted by owner on GitHub at [^ ]*: $1\$" "$2" && grep -qF "Go with the left option for the first question." "$2"' _ "$u1" "$ST/node/A01/ANSWER.md"
ok "S09-AC-3: an answer: one +1 on the comment, and no other reaction" test "$(tool react "$FK" "$c1")" = 1 -a "$(tool nreact "$FK")" = 1
ok "S09-AC-3: an answer: the answer-received milestone on A01's home issue (11), once, with the URL" \
	test "$(tool count "$FK" 11 "$u1")" = 1 -a "$(tool count "$FK" 11 "answer received")" = 1 -a "$(tool nbot "$FK" 11)" = $((nb11 + 1))
ok "S09-AC-3: feedback: node/F06/FEEDBACK.md holds the item as feedback.py writes it (PR, branch, kind, id, url, author, body)" \
	sh -c 'f=$1; grep -qxF "# Feedback" "$f" && grep -qxF "PR: 20" "$f" && grep -qxF "Branch: node/F06-thing" "$f" && grep -qxF "kind: conversation" "$f" && grep -qxF "id: $2" "$f" && grep -qxF "url: $3" "$f" && grep -qxF "author: owner" "$f" && grep -qF "body: Please also handle empty input in the pull request 20." "$f"' _ "$ST/node/F06/FEEDBACK.md" "$c2" "$u2"
ok "S09-AC-3: feedback: a spec PR's item is in pr/26/FEEDBACK.md (PR 26, branch spec/triage-5-thing)" \
	sh -c 'f=$1; grep -qxF "PR: 26" "$f" && grep -qxF "Branch: spec/triage-5-thing" "$f" && grep -qxF "url: $2" "$f"' _ "$ST/pr/26/FEEDBACK.md" "$u5"
ok "S09-AC-3: feedback: the unit's start count is reset (2 -> 0), so the loop starts its session" test "$(cat "$ST/node/F06/starts" 2>/dev/null)" = 0
nr=$(tool titled "$FK" "dark mode" | head -n1)
ok "S09-AC-3: a request: exactly one new issue, titled from the decision" test "$(tool titled "$FK" "dark mode" | wc -l)" = 1 -a "$(tool json "$FK/issues.json" "len(d)")" = $((NISS0 + 1))
ok "S09-AC-3: a request: with no label" test "$(tool issue "$FK" "${nr:-0}" labels)" = '[]'
ok "S09-AC-3: a request: the body quotes the comment and links its URL" sh -c 'b=$(python3 -I "$1" issue "$2" "$3" body); echo "$b" | grep -qF "It would be great to have a dark mode." && echo "$b" | grep -qF "$4"' _ "$T/tool.py" "$FK" "${nr:-0}" "$u3"
ok "S09-AC-3: a note: nothing changes (its URL is in no file of the state outside pickup/, no reaction, no issue)" needrun 1 \
	sh -c '[ -z "$(grep -rlF "$1" "$2" --exclude-dir=pickup 2>/dev/null)" ]' _ "$u4" "$ST"
ok "S09-AC-3: an answer's reply: on the thread, the unit, U03's clause (report.py --clause A01), signed" reply_has 13 "$u1" "A01" "$(clause A01)" "SIG-9"
ok "S09-AC-3: a feedback reply: the PR (#20) and the PR unit's clause" reply_has 14 "$u2" "#20" "$(clause F06)"
ok "S09-AC-3: a spec-PR feedback reply: the PR (#26) and the clause of 'PR #26'" reply_has 14 "$u5" "#26" "$(clause 'PR #26')"
ok "S09-AC-3: a request's reply: the new issue and the noodlebot label the owner adds" has_ref "$L" "$u3" "$nr"
ok "S09-AC-3: a note's reply says nothing was changed" reply_has 13 "$u4" "nothing"
ok "S09-AC-3: each item got exactly one reply (bot comments added: 13 +2, 14 +2, log +2)" \
	test "$(tool nbot "$FK" 13)" = $((nb13 + 2)) -a "$(tool nbot "$FK" 14)" = $((nb14 + 2)) -a "$(tool nbot "$FK" "$L")" = $((nbL + 2))
for k in 1:13 2:14 3:$L 4:13 5:14; do n=${k%%:*}; th=${k##*:}; eval "u=\$u$n"
	ok "S09-AC-3: the reply to comment $n is on its thread, once" test "$(tool count "$FK" "$th" "$u")" = 1; done
ok "S09-AC-4: an action outside the four is refused: report.py's reply (the same text as without --pickup), no other effect" \
	test "$(tool notrec "$FK")" = "$(tool notrec "$CK" 13 13 14 14 "$L")"
ok "S09-AC-4: and the refusal is logged (a 'refused' line naming the item on stderr), not for the accepted ones" \
	sh -c 'grep -i refused "$1" | grep -qF "$2" && ! grep -i refused "$1" | grep -qF "$3"' _ "$AUX/run.err" "$u6" "$u1"
ok "S09-AC-3: every item is in the handled record" all_handled "$c1" "$c2" "$c3" "$c4" "$c5" "$c6"
snap() { tool snap "$FK" "$ST" "$L" "$c1" "$c2" "$c3" "$c4" "$c5" "$c6"; }   # what must stay the same over more applies
snap >"$AUX/snap1"
pk apply --run "$RUNDIR" >/dev/null 2>"$AUX/apply2.err"; rc2=$?
rp --pickup >/dev/null 2>&1
pk apply --run "$RUNDIR" >/dev/null 2>&1; rc3=$?
runit
rp --pickup >/dev/null 2>&1
snap >"$AUX/snap2"
ok "S09-AC-3: applying the same run again (twice, between report.py --pickup runs) exits 0" test "$rc2" = 0 -a "$rc3" = 0
ok "S09-AC-3: over three applies and a further tick: nothing done or posted twice (reactions, replies, issues, files, handled)" sh -c 'cmp -s "$1" "$2" && grep -qx "react $3 1" "$1" && grep -q "^issues " "$1"' _ "$AUX/snap1" "$AUX/snap2" "$c1"
ok "S09-AC-3: the further tick (no items left) starts no run and prints nothing" test -z "$RUN" -a ! -s "$AUX/run.out" -a "$RC" = 0 -a "$(nsmall)" = 1

# --- phase 2: refusals of single decisions, in a run with an accepted one
cp "$ST/node/F06/FEEDBACK.md" "$AUX/f06.fb"; cp "$ST/pr/26/FEEDBACK.md" "$AUX/pr26.fb"
d1=$(tool addc "$FK" 13 owner 1 0 "refuse: answer for C03, no question open")
d2=$(tool addc "$FK" 14 owner 1 0 "refuse: answer for an unknown unit")
d3=$(tool addc "$FK" 13 owner 1 0 "refuse: feedback for an unknown PR")
d4=$(tool addc "$FK" 14 owner 1 0 "refuse: feedback for a human's PR")
d5=$(tool addc "$FK" 13 owner 1 0 "refuse: feedback for a bot PR on a branch that is neither node/ nor spec/")
d6=$(tool addc "$FK" 13 owner 1 0 "refuse: the action merge")
d7=$(tool addc "$FK" 14 owner 1 0 "accepted: a note next to refusals")
rp --pickup >/dev/null 2>&1
nb13=$(tool nbot "$FK" 13); nb14=$(tool nbot "$FK" 14); nr0=$(tool nreact "$FK")
script "$(printf '[{"item": %s, "action": "answer", "unit": "C03", "reason": "r"}, {"item": %s, "action": "answer", "unit": "Z99", "reason": "r"},
 {"item": %s, "action": "feedback", "pr": 99, "reason": "r"}, {"item": %s, "action": "feedback", "pr": 21, "reason": "r"},
 {"item": %s, "action": "feedback", "pr": 27, "reason": "r"}, {"item": %s, "action": "merge", "pr": 20, "reason": "r"},
 {"item": %s, "action": "note", "reason": "r"}]' "$d1" "$d2" "$d3" "$d4" "$d5" "$d6" "$d7")"
runit; ur() { tool url "$FK" "$1"; }
ok "S09-AC-4: the run with refused decisions exits 0" test "$RC" = 0 -a -d "$RUNDIR"
ok "S09-AC-4: refused: a unit with no open question (C03: ANSWER.md untouched, no +1)" needrun 2 cmp -s "$AUX/c03.answer" "$ST/node/C03/ANSWER.md"
ok "S09-AC-4: refused: an unknown unit, an unknown PR, a human's PR, a PR on another branch: no state folder, no FEEDBACK.md written" \
	sh -c '[ ! -e "$1/node/Z99" ] && [ ! -e "$1/pr/99" ] && [ ! -e "$1/pr/21" ] && [ ! -e "$1/pr/27" ] && [ ! -e "$1/node/G07" ] && cmp -s "$2" "$1/node/F06/FEEDBACK.md" && cmp -s "$3" "$1/pr/26/FEEDBACK.md"' _ "$ST" "$AUX/f06.fb" "$AUX/pr26.fb"
ok "S09-AC-4: refused decisions: no reaction, no new issue" test "$(tool nreact "$FK")" = "$nr0" -a "$(tool json "$FK/issues.json" "len(d)")" = $((NISS0 + 1))
ok "S09-AC-4: each refused comment got report.py's reply (13: 4 x, 14: 2 x, the same texts as report.py without --pickup)" \
	test "$(tool notrec "$FK" | grep -c "^13 $(printf '%s' "$T13L" | cut -d' ' -f2- | sed 's/[][\.*^$/]/\\&/g')\$")" = 4 \
	-a "$(tool notrec "$FK" | grep -c "^14 $(printf '%s' "$T14L" | cut -d' ' -f2- | sed 's/[][\.*^$/]/\\&/g')\$")" = 2
ok "S09-AC-4: and the accepted note got its own reply (13: +4, 14: +3 comments)" test "$(tool nbot "$FK" 13)" = $((nb13 + 4)) -a "$(tool nbot "$FK" 14)" = $((nb14 + 3))
ok "S09-AC-4: the accepted note's reply says nothing changed" reply_has 14 "$(ur "$d7")" nothing
ok "S09-AC-4: every refusal is logged on stderr with the item's URL" all_logged "$AUX/run.err" "$d1" "$d2" "$d3" "$d4" "$d5" "$d6"
ok "S09-AC-4: the accepted note is not logged as refused" needrun 2 sh -c '! grep -i refused "$1" | grep -qF "$2"' _ "$AUX/run.err" "$(ur "$d7")"
ok "S09-AC-4: all seven are handled" all_handled "$d1" "$d2" "$d3" "$d4" "$d5" "$d6" "$d7"
pk apply --run "$RUNDIR" >/dev/null 2>&1
ok "S09-AC-4: applying the run again posts no second reply" test "$(tool nbot "$FK" 13)" = $((nb13 + 4)) -a "$(tool nbot "$FK" 14)" = $((nb14 + 3))

# --- phases 3 and 4: a run that used a tool, malformed outputs: all decisions refused
REF13=4   # the refused replies on thread 13 so far (the first refusal phase left four)
all_refused() { # all_refused <label> <ids...>: the state after a run whose decisions (valid ones among them) were all refused
	label=$1; shift
	REF13=$((REF13 + $#))
	ok "S09-AC-4: $label: B02 was not answered (no ANSWER.md, no new +1), nothing was created" \
		test ! -e "$ST/node/B02/ANSWER.md" -a "$(tool nreact "$FK")" = "$nr0" -a "$(tool json "$FK/issues.json" "len(d)")" = $((NISS0 + 1))
	ok "S09-AC-4: $label: every item got report.py's reply (thread 13)" test "$(tool notrec "$FK" | grep -c '^13 ')" = "$REF13"
	ok "S09-AC-4: $label: every refusal is logged" all_logged "$AUX/run.err" "$@"
	ok "S09-AC-4: $label: every item is handled" all_handled "$@"
}
e1=$(tool addc "$FK" 13 owner 1 0 "tool run: answer B02")
e2=$(tool addc "$FK" 13 owner 1 0 "tool run: a note")
rp --pickup >/dev/null 2>&1
script "$(printf '[{"item": %s, "action": "answer", "unit": "B02", "reason": "r"}, {"item": %s, "action": "note", "reason": "r"}]' "$e1" "$e2")" tool
runit
ok "S09-AC-4: a run that used a tool (a tool event in its events.jsonl) runs and exits 0" test "$RC" = 0 -a -d "$RUNDIR" -a "$(grep -c '"type": *"tool"' "$RUNDIR/events.jsonl")" = 1
all_refused "a run that used a tool" "$e1" "$e2"
ok "S09-AC-4: a run that used a tool: not even the note was carried out (no 'nothing' reply, only the deterministic ones)" needrun 3 test "$(tool count "$FK" 13 "$(ur "$e2")")" = 0

f1=$(tool addc "$FK" 13 owner 1 0 "prose run: one")
f2=$(tool addc "$FK" 13 owner 1 0 "prose run: two")
rp --pickup >/dev/null 2>&1
script "I could not decide what to do with these comments, sorry."
runit
all_refused "output that is not JSON" "$f1" "$f2"
g1=$(tool addc "$FK" 13 owner 1 0 "object run: one")
g2=$(tool addc "$FK" 13 owner 1 0 "object run: two")
rp --pickup >/dev/null 2>&1
script "$(printf '{"decisions": [{"item": %s, "action": "answer", "unit": "B02", "reason": "r"}, {"item": %s, "action": "note", "reason": "r"}]}' "$g1" "$g2")"
runit
all_refused "output that is a JSON object, not a list" "$g1" "$g2"
h1=$(tool addc "$FK" 13 owner 1 0 "missing run: one")
h2=$(tool addc "$FK" 13 owner 1 0 "missing run: two")
rp --pickup >/dev/null 2>&1
script "$(printf '[{"item": %s, "action": "answer", "unit": "B02", "reason": "r"}]' "$h1")"
runit
all_refused "a list with no decision for one item" "$h1" "$h2"
k1=$(tool addc "$FK" 13 owner 1 0 "unknown-item run: one")
k2=$(tool addc "$FK" 13 owner 1 0 "unknown-item run: two")
rp --pickup >/dev/null 2>&1
script "$(printf '[{"item": %s, "action": "answer", "unit": "B02", "reason": "r"}, {"item": %s, "action": "note", "reason": "r"}, {"item": 99999, "action": "note", "reason": "r"}]' "$k1" "$k2")"
runit
all_refused "a list with a decision for an item that is not in the run" "$k1" "$k2"

# --- phase 5: a failed reply is retried by the next apply, the action is not repeated
m1=$(tool addc "$FK" 13 owner 1 0 "retry: answer B02")
m2=$(tool addc "$FK" 13 owner 1 0 "retry: a request")
m3=$(tool addc "$FK" 13 owner 1 0 "retry: feedback on PR 20")
rp --pickup >/dev/null 2>&1
um1=$(ur "$m1"); um2=$(ur "$m2"); um3=$(ur "$m3")
script "$(printf '[{"item": %s, "action": "answer", "unit": "B02", "reason": "r"}, {"item": %s, "action": "request", "title": "Another request", "reason": "r"}, {"item": %s, "action": "feedback", "pr": 20, "reason": "r"}]' "$m1" "$m2" "$m3")"
n13=$(tool nbot "$FK" 13)
tool rmissue "$FK" 13           # the forge cannot find the thread: only the replies fail
runit
ok "S09-AC-3: a run whose replies cannot be posted exits 1" test "$RC" = 1 -a -d "$RUNDIR"
ok "S09-AC-3: the actions were carried out (ANSWER.md of B02, one +1, one issue, the item in F06's FEEDBACK.md)" \
	sh -c 'grep -qF "$1" "$2" && [ "$3" = 1 ] && [ "$4" = 1 ] && [ "$(grep -c "^url: $5\$" "$6")" = 1 ]' _ "$um1" "$ST/node/B02/ANSWER.md" "$(tool react "$FK" "$m1")" "$(tool titled "$FK" "Another request" | wc -l)" "$um3" "$ST/node/F06/FEEDBACK.md"
ok "S09-AC-3: no reply was posted (thread 13 as it was), the run having started" sh -c '[ "$1" = "$2" ] && [ -d "$3" ]' _ "$(tool nbot "$FK" 13)" "$n13" "$RUNDIR"
ok "S09-AC-3: none of the three is handled yet" needrun 8 sh -c '! grep -qxE "$1|$2|$3" "$4" 2>/dev/null' _ "$m1" "$m2" "$m3" "$ST/pickup/handled"
tool putissue "$FK" 13
pk apply --run "$RUNDIR" >/dev/null 2>"$AUX/retry.err"; rc=$?
ok "S09-AC-3: the next apply posts the replies (exit 0): one each, on the thread" test "$rc" = 0 -a "$(tool count "$FK" 13 "$um1")" = 1 -a "$(tool count "$FK" 13 "$um2")" = 1 -a "$(tool count "$FK" 13 "$um3")" = 1
ok "S09-AC-3: and did not repeat an action (one +1, one issue, one item in FEEDBACK.md, one milestone on issue 12)" \
	sh -c '[ "$1" = 1 ] && [ "$2" = 1 ] && [ "$(grep -c "^url: $3\$" "$4")" = 1 ] && [ "$5" = 1 ]' _ "$(tool react "$FK" "$m1")" "$(tool titled "$FK" "Another request" | wc -l)" "$um3" "$ST/node/F06/FEEDBACK.md" "$(tool count "$FK" 12 "$um1")"
ok "S09-AC-3: the three are handled now" all_handled "$m1" "$m2" "$m3"
n13=$(tool nbot "$FK" 13)
pk apply --run "$RUNDIR" >/dev/null 2>&1; runit
ok "S09-AC-3: a further apply and a further tick post nothing, and start no run" test "$(tool nbot "$FK" 13)" = "$n13" -a -z "$RUN" -a "$(tool count "$FK" 13 "$um1")" = 1

# --- what no pickup run may do (S09-AC-4)
ok "S09-AC-4: no PR was opened or changed (prs.json as it was)" needrun 8 cmp -s "$AUX/prs0.json" "$FK/prs.json"
ok "S09-AC-4: no label was changed on any issue that was there, and the new issues carry none" needrun 8 \
	test "$(tool json "$FK/issues.json" "sorted((i['number'], i['labels']) for i in d if i['number'] in [n for n, _ in $LAB0]) == sorted($LAB0) and all(i['labels'] == [] for i in d if i['number'] not in [n for n, _ in $LAB0] and not i['title'].startswith('noodlebot log'))")" = True
ok "S09-AC-4: no label was created or removed" needrun 8 test "$(cat "$AUX/labels0.json")" = "$(cat "$FK/labels.json" 2>/dev/null)"
ok "S09-AC-4: no commit, branch or push (the clone's HEAD and refs, no repository in the forge)" needrun 8 test "$(git -C "$W/clone" rev-parse HEAD)" = "$HEAD0" -a "$(git -C "$W/clone" for-each-ref | wc -l)" = "$REFS0" -a ! -e "$FK/repo.git" -a -z "$(git -C "$W/clone" status --porcelain)"
find "$W" -path "$FK" -prune -o -path "$ST" -prune -o -path "$W/clone/.git" -prune -o -type f -print | sort >"$AUX/fs1"
ok "S09-AC-4: nothing was written outside the state folder (cwd, worktrees, clone, state root: the same files)" needrun 8 cmp -s "$AUX/fs0" "$AUX/fs1"
ok "S09-AC-4: no session was started (the fake harness saw no start or resume, only small starts)" test "$(grep -cE '^(start|resume) ' "$AUX/harness.log")" = 0 -a "$(nsmall)" -ge 8

# =================================================================================================================
# S09-AC-5 (slice 3): the budget, the ceiling, the shared record. THE CONTRACT these cases fix:
#
# 3. The budget record is $ROOT/pickup.json, ROOT = $NOODLEBOT_DATA/state (the loop gives pickup.py its NOODLEBOT_DATA; in
#    these cases it is the parent of --state, as in every runtime root), read and written under flock (a lock file beside it);
#    all loops of the machine, whatever their repository, share it. WITHOUT NOODLEBOT_DATA pickup.py has no root: it keeps no
#    record and reads no usage.json (no budget, no ceiling): the cases above ran so, and nothing may be written beside the
#    state folder then (the line "nothing was written outside the state folder" of S09-AC-4 pins it). The cases below read
#    nothing from the record's contents: only the runs that start (the fake harness's `small` calls) and what pickup.py prints.
#    `pickup.py run`, with items, asks before it starts a run; it starts one only when all of this holds:
#      - no window of $ROOT/usage.json (usage.py's file: {"windows": {"five_hour": {"resetsAt": epoch, "utilization": 0..1,
#        "status": "allowed"|"allowed_warning"|"rejected"}, "seven_day": {...}}, "hold": bool, "reason": text}) whose
#        resetsAt is still in the future has status "rejected" (a window "rejecting requests"; "allowed_warning" is not a
#        rejection, either window), and none of them has utilization at or above the ceiling;
#      - fewer than PICKUP_RUNS runs started in the current window (PICKUP_RUNS: a positive integer, default 12).
#    The ceiling, PICKUP_CEILING (default 90%): "90%" or "90" (a number above 1) are percent, "0.9" (a number up to 1) a fraction.
#    "At" the ceiling is over it: utilization 0.90 stops with the default. A window past its reset (resetsAt <= now) counts
#    for nothing (a stale rejection or a stale 99% does not stop a run). "hold" and "reason" of usage.json (the pace holds) and
#    the windows' projections are never read: a pace hold alone does not stop a run. No usage.json: no limit but the budget.
#    The window of the budget is the "five_hour" window of usage.json, identified by its resetsAt (a different resetsAt is
#    a new window and a count of 0); without it, the 5 hours from the first run counted (not tested: the file's contents are
#    not part of this contract). Taking a run (the count) is one step under the lock: any number of loops asking at once
#    start at most PICKUP_RUNS runs in all.
#    With items and no run allowed, nothing starts and each item gets report.py's deterministic reply (its pending file's
#    reply, signed), exactly as a refused item does (one reply each, the items handled, none retried); the refusal reason is
#    on stderr. The FIRST such tick of a window (the first time the budget or a window said no, whatever the reason; recorded in
#    pickup.json) prints one line on stdout, which the loop says in its status log, and no later tick of that window prints
#    anything: "pickup: no run: <reason>", the reason holding the word "budget" (PICKUP_RUNS runs started), "ceiling"
#    (a window at or above the ceiling) or "rejecting" (a window rejecting requests), lower or upper case. A new window says
#    again. Ticks with no items print nothing and do not count.
S5=$S9/B5
mkdir -p "$S5"
# b5world <root> <name>: a state folder state/<name> under $S5/<root>/ (the root's other states are its other "loops"), its fake forge
b5world() {
	mkdir -p "$S5/$1/state" "$S5/$1/cwd-$2" "$S5/$1/wt" "$S5/$1/clone"
	cp -R "$T/state" "$S5/$1/state/$2"; cp -R "$T/forge" "$S5/$1/fk-$2"
	mkdir -p "$S5/$1/state/$2/pickup/pending"
}
# b5pk <root> <name> <args...>: pickup.py as the loop runs it, over that state; the settings are the words of $B5ENV
b5pk() {
	r=$1; n=$2; shift 2
	(cd "$S5/$r/cwd-$n" && env NOODLEBOT_DATA="$S5/$r" SCHED_HARNESS=fake FAKE_HARNESS_SMALL_SCRIPT="$S5/$r/ev-$n" FAKE_HARNESS_LOG="$S5/$r/h.log" $B5ENV \
		python3 -I "$src/pickup.py" --repo "fake:$S5/$r/fk-$n" --state "$S5/$r/state/$n" --owner owner --clone "$S5/$r/clone" \
		--worktrees "$S5/$r/wt" --version 9.9 --signature SIG-9 "$@")
}
# b5tick <root> <name> <id>: one owner comment (id) becomes pending and the pickup session would answer it with a note; one tick
# (pickup.py run); its stdout is $S5/<root>/<name>.<id>.out, its stderr $S5/<root>/<name>.<id>.err
b5tick() {
	ST=$S5/$1/state/$2; pend9 "$3" owner 1 0
	tool script "$S5/$1/ev-$2" "$(printf '[{"item": %s, "action": "note", "reason": "r"}]' "$3")"
	b5pk "$1" "$2" run >"$S5/$1/$2.$3.out" 2>"$S5/$1/$2.$3.err"
}
# b5usage <root> <five util> <five status> <seven util> <seven status> <five reset in s> <hold: true|false>
b5usage() {
	python3 -I - "$S5/$1/state/usage.json" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
import json, sys, time
p, fu, fs, su, ss, off, hold = sys.argv[1:8]
now = int(time.time())
json.dump({"windows": {"five_hour": {"resetsAt": now + int(off), "utilization": float(fu), "status": fs},
                       "seven_day": {"resetsAt": now + 6 * 86400, "utilization": float(su), "status": ss}},
           "hold": hold == "true", "reason": "5-hour window projected to reach 95% before it resets (limit 90%)" if hold == "true" else ""},
          open(p, "w"))
PY
}
b5small() { n=$(grep -c '^small ' "$S5/$1/h.log" 2>/dev/null); echo "${n:-0}"; }
b5handled() { grep -qx "$3" "$S5/$1/state/$2/pickup/handled" 2>/dev/null; }
b5said() { n=$(grep -ci '^pickup: no run' "$S5/$1/$2.$3.out" 2>/dev/null); echo "${n:-0}"; }   # lines said by that tick
b5replies() { tool count "$S5/$1/fk-$2" 13 "Not recorded as an answer"; }
# case5 <tag> <settings> <five util> <five status> <seven util> <seven status> <five reset in s> <hold>: one world, one tick
case5() {
	( B5ENV=$2; b5world "c$1" w; [ "$3" = none ] || b5usage "c$1" "$3" "$4" "$5" "$6" "$7" "$8"; b5tick "c$1" w 9101 ) &
}
# the table: tag, settings, five util, status, seven util, status, reset in, hold
case5 pace "PICKUP_RUNS=5" 0.5 allowed 0.8 allowed 3600 true
case5 d91 "" 0.91 allowed 0.1 allowed 3600 false
case5 d90 "" 0.90 allowed 0.1 allowed 3600 false
case5 d89 "" 0.89 allowed 0.1 allowed 3600 false
case5 sev "" 0.2 allowed 0.95 allowed 3600 false
case5 p50hi "PICKUP_CEILING=50" 0.55 allowed 0.1 allowed 3600 false
case5 p50lo "PICKUP_CEILING=50" 0.45 allowed 0.1 allowed 3600 false
case5 pc50hi "PICKUP_CEILING=50%" 0.55 allowed 0.1 allowed 3600 false
case5 f50hi "PICKUP_CEILING=0.5" 0.55 allowed 0.1 allowed 3600 false
case5 f50lo "PICKUP_CEILING=0.5" 0.45 allowed 0.1 allowed 3600 false
case5 rej5 "" 0.2 rejected 0.1 allowed 3600 false
case5 rej7 "" 0.2 allowed 0.1 rejected 3600 false
case5 warn7 "" 0.2 allowed 0.5 allowed_warning 3600 false
case5 stalerej "" 0.99 rejected 0.1 allowed -60 false
case5 nousage "" none
# the window and the budget in one state: PICKUP_RUNS=2, a window, a new window, the ceiling in the new window
(
	B5ENV="PICKUP_RUNS=2"; b5world W w; b5usage W 0.2 allowed 0.1 allowed 3600 true
	for i in 9101 9102 9103 9104; do b5tick W w $i; done
	b5usage W 0.2 allowed 0.1 allowed 21600 true; b5tick W w 9105          # the five-hour window reset: a new one, count 0
	b5usage W 0.95 allowed 0.1 allowed 21600 false; b5tick W w 9106; b5tick W w 9107   # the ceiling in the new window
) &
# the default budget (12 runs): thirteen ticks in one window
(
	B5ENV=""; b5world D w; b5usage D 0.2 allowed 0.1 allowed 3600 false
	for i in 9101 9102 9103 9104 9105 9106 9107 9108 9109 9110 9111 9112 9113; do b5tick D w $i; done
) &
# twelve loops at once share one record: twelve states under one root, PICKUP_RUNS=5, all ticking at the same time
(
	B5ENV="PICKUP_RUNS=5"; for n in 1 2 3 4 5 6 7 8 9 10 11 12; do b5world P "s$n"; done; b5usage P 0.2 allowed 0.1 allowed 3600 false
	for n in 1 2 3 4 5 6 7 8 9 10 11 12; do b5tick P "s$n" 9101 & done; wait
) &
# ... and six more times two at once, one run allowed in each root
(
	B5ENV="PICKUP_RUNS=1"
	for k in 1 2 3 4 5 6; do b5world "Q$k" a; b5world "Q$k" b; b5usage "Q$k" 0.2 allowed 0.1 allowed 3600 false; done
	for k in 1 2 3 4 5 6; do b5tick "Q$k" a 9101 & b5tick "Q$k" b 9101 & done; wait
) &
wait

run5() { [ "$(b5small "c$1")" = 1 ] && b5handled "c$1" w 9101; }
stop5() { # stop5 <tag> <word>: no run, the item handled and given report.py's reply once, one line said naming the reason
	[ "$(b5small "c$1")" = 0 ] && b5handled "c$1" w 9101 && [ "$(b5replies "c$1" w)" = 1 ] && [ "$(b5said "c$1" w 9101)" = 1 ] &&
		grep -qi "^pickup: no run.*$2" "$S5/c$1/w.9101.out"
}
ok "S09-AC-5: a pace hold alone (hold true with a pace reason, windows allowed and below the ceiling) does not stop a run" run5 pace
ok "S09-AC-5: no usage.json at all: the run starts" run5 nousage
ok "S09-AC-5: a window at 91% stops with the default ceiling (90%): no run, the item gets the deterministic reply, one line says so" stop5 d91 ceiling
ok "S09-AC-5: a window at 90%: at the ceiling is over it" stop5 d90 ceiling
ok "S09-AC-5: a window at 89% starts a run (default ceiling 90%)" run5 d89
ok "S09-AC-5: the ceiling is any window's: the seven-day window at 95% stops a run" stop5 sev ceiling
ok "S09-AC-5: PICKUP_CEILING=50 (percent): a window at 55% stops" stop5 p50hi ceiling
ok "S09-AC-5: PICKUP_CEILING=50 (percent): a window at 45% does not" run5 p50lo
ok "S09-AC-5: PICKUP_CEILING=50% (percent): a window at 55% stops" stop5 pc50hi ceiling
ok "S09-AC-5: PICKUP_CEILING=0.5 (a fraction): a window at 55% stops" stop5 f50hi ceiling
ok "S09-AC-5: PICKUP_CEILING=0.5 (a fraction): a window at 45% does not" run5 f50lo
ok "S09-AC-5: a five-hour window rejecting requests (at 20%) stops a run" stop5 rej5 rejecting
ok "S09-AC-5: a seven-day window rejecting requests stops a run" stop5 rej7 rejecting
ok "S09-AC-5: a seven-day window that is only allowed_warning (at 50%) does not stop a run" run5 warn7
ok "S09-AC-5: a window past its reset counts for nothing (a stale rejection at 99%): the run starts" run5 stalerej
# W: PICKUP_RUNS=2: 9101 9102 run, 9103 9104 do not; the window resets: 9105 runs; the ceiling in the new window: 9106 9107 do not
ok "S09-AC-5: PICKUP_RUNS=2: 3 runs in all (two in the first window, one in the next), no more" test "$(b5small W)" = 3
ok "S09-AC-5: the third and fourth ticks of the first window start no run: their items are handled, with report.py's reply" \
	sh -c 'for i in 9103 9104; do grep -qx $i "$1" || exit 1; done; [ "$(grep -c . "$2")" = 3 ]' _ "$S5/W/state/w/pickup/handled" "$S5/W/h.log"
ok "S09-AC-5: ... four deterministic replies in all (9103, 9104, and the ceiling's 9106, 9107), one each" test "$(b5replies W w)" = 4
ok "S09-AC-5: every item of W is handled (nothing retried)" sh -c 'for i in 9101 9102 9103 9104 9105 9106 9107; do grep -qx $i "$1" || exit 1; done; [ "$(grep -c . "$1")" = 7 ]' _ "$S5/W/state/w/pickup/handled"
ok "S09-AC-5: the first such tick of the first window says so (budget), the next one says nothing" \
	test "$(b5said W w 9103)" = 1 -a "$(b5said W w 9104)" = 0 -a "$(grep -ci 'budget' "$S5/W/w.9103.out")" = 1
ok "S09-AC-5: the run of the new window (9105) says nothing" test "$(b5said W w 9105)" = 0 -a "$(b5small W)" = 3
ok "S09-AC-5: the first such tick of the new window says so (ceiling) though one was said in the old one; the next says nothing" \
	test "$(b5said W w 9106)" = 1 -a "$(b5said W w 9107)" = 0 -a "$(grep -ci 'ceiling' "$S5/W/w.9106.out")" = 1
ok "S09-AC-5: PICKUP_RUNS unset: 12 runs in a window, the thirteenth tick starts none (gets the reply, one line says so)" \
	sh -c '[ "$1" = 12 ] && [ "$2" = 1 ] && [ "$3" = 1 ]' _ "$(b5small D)" "$(b5replies D w)" "$(b5said D w 9113)"
ok "S09-AC-5: twelve loops sharing one record at once, PICKUP_RUNS=5: exactly 5 runs in all, never more" test "$(b5small P)" = 5
ok "S09-AC-5: ... the other seven items got the deterministic reply, all twelve are handled" \
	sh -c 't=0; h=0; for n in 1 2 3 4 5 6 7 8 9 10 11 12; do c=$(python3 -I "$1" count "$2/P/fk-s$n" 13 "Not recorded as an answer"); t=$((t + c)); grep -qx 9101 "$2/P/state/s$n/pickup/handled" && h=$((h + 1)); done; [ "$t" = 7 ] && [ "$h" = 12 ]' _ "$T/tool.py" "$S5"
ok "S09-AC-5: six times two loops at once, PICKUP_RUNS=1: one run in each root, never two" \
	sh -c 'for k in 1 2 3 4 5 6; do [ "$(grep -c "^small " "$1/Q$k/h.log" 2>/dev/null)" = 1 ] || exit 1; done' _ "$S5"
ok "S09-AC-5: ... and the other loop of each root got the deterministic reply, both handled" \
	sh -c 'for k in 1 2 3 4 5 6; do a=$(python3 -I "$1" count "$2/Q$k/fk-a" 13 "Not recorded as an answer"); b=$(python3 -I "$1" count "$2/Q$k/fk-b" 13 "Not recorded as an answer"); [ $((a + b)) = 1 ] || exit 1; grep -qx 9101 "$2/Q$k/state/a/pickup/handled" && grep -qx 9101 "$2/Q$k/state/b/pickup/handled" || exit 1; done' _ "$T/tool.py" "$S5"
ok "S09-AC-5: a budget record is written beside the states, not inside them (the state root's pickup.json)" test -s "$S5/P/state/pickup.json" -a -s "$S5/W/state/pickup.json"
ok "S09-AC-5: no session was started by any of these ticks (no start or resume call)" sh -c '! cat "$1"/*/h.log 2>/dev/null | grep -qE "^(start|resume) "' _ "$S5"

[ "$fails" -eq 0 ] || { echo "FAIL: $fails check(s) failed"; exit 1; }
echo "all passed"
