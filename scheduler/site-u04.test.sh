#!/bin/sh
# Test of scheduler/site.py build, the node fields merge_ready and merge_why (U04-AC-3). A runtime root is built in a
# scratch folder from copies of scheduler/testdata/site/ (alpha's graph, its merged and open PR lists, one node in each
# other state) with more nodes added to the copy, each with an open PR (K01..K22), the merge records report.py writes in
# report.json, and live fake sessions.
#   sh scheduler/site-u04.test.sh   (make test)
#
# THE CONTRACT these checks fix (site.py build must give exactly this).
#   Each node object has "merge_ready" (boolean for state pr-open, else null) and "merge_why" (string or null), both
#   named in scheduler/site-schema.json as {"nullable": "boolean"} and {"nullable": "string"}.
#   Inputs for a pr-open node (an open-prs.tsv row "<N> node/<ID>-<name> <head> <bot> <mergeable>", head 40 hex):
#     report.json "merge"[<N as a string>] = {"head", "review_head", "verdict", "ci"} (as report.py writes it), the PR's
#     `mergeable`, <state>/pr/<N>/ (session.pid of a live session, QUESTION.md, ANSWER.md), <state>/node/<ID>/ (a live
#     session there makes the node "running", a QUESTION.md makes it "question": other states, both fields null).
#   merge_ready is true only when: no live session in pr/<N> (a live session in node/<ID> is the state running); no
#     QUESTION.md in pr/<N>; mergeable is not CONFLICTING; the record's "head" is the PR's head (else the record is
#     for another head: not reviewed, CI unknown); the PR's head starts with the record's review_head (7 or more hex,
#     case ignored; none: not the same); verdict is "approve"; ci is "passed". Otherwise false.
#   merge_why: for a ready node whose mergeable is neither MERGEABLE nor CONFLICTING (UNKNOWN, empty): a text containing
#     "has not said whether it merges cleanly"; for any other ready node null. For a node that is not ready, a
#     non-empty text, with these phrases for the reasons that hold (matched as substrings; a reason that does not
#     hold is not said, checked for the phrases of the other reasons):
#       QUESTION.md in pr/<N> without ANSWER.md   "open question"
#       QUESTION.md in pr/<N> with ANSWER.md      "answer waits for a session"
#       mergeable CONFLICTING                     "conflicts with its base"
#       head differs from the review's            the PR's head and the review's head, 7 characters each
#       no record / no review                     "no final review"
#       the review names no head                  "no head"
#       verdict is not approve                    the verdict as written (request_changes)
#       ci pending / failed / none (or the record is for another head)   "CI pending" / "CI failed" / "no CI result"
#     a live session in pr/<N>: any non-empty text.
#   Every text goes through site.py's text(): a path or a token in the report.json verdict is removed, as everywhere.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
fx=$src/testdata/site
. "$src/testdata/lib/fixture.sh"
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
pids=
cleanup() {
	for p in $pids; do kill "$p" 2>/dev/null; done
	chmod -R u+rwX "$tmp" 2>/dev/null
	rm -rf "$tmp"
}
trap cleanup EXIT
unset SCHED_HARNESS
root=$tmp/data HOME=$tmp/home
export HOME GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$tmp/bin" "$tmp/cwd" "$HOME/.config/noodlebot" "$root/state/alpha/node" "$root/state/alpha/pr" "$root/repos"
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$tmp/bin/run-session.sh"
sa=$root/state/alpha

# the state: copies of the site fixture, the cases added (setup writes $tmp/cases.json)
cp "$fx/alpha/graph.yaml" "$sa/graph.yaml"
echo public >"$sa/visibility"
echo acme/alpha >"$HOME/.config/noodlebot/repos"
python3 -I - "$sa" "$tmp/cases.json" "$fx" <<'PY'
import json, os, sys
sa, cases_file, fx = sys.argv[1:4]
H = lambda k, c="c": "%02x" % k + c * 38          # a 40-character head
OLD = lambda k: "%02x" % k + "0" * 38
cases = []
def case(i, **kw):
    kw.setdefault("mergeable", "MERGEABLE"); kw.setdefault("ready", False)
    kw["id"] = "K%02d" % i; kw["pr"] = 600 + i; kw["head"] = H(i)
    cases.append(kw)
def rec(i, review="same", verdict="approve", ci="passed", head=None):
    h = head or H(i)
    return {"head": h, "review_head": H(i)[:7] if review == "same" else review, "verdict": verdict, "ci": ci}
NOT = ["open question", "answer waits for a session", "conflicts with its base", "no final review", "no head",
       "request_changes", "CI pending", "CI failed", "no CI result"]
def only(*keep): return [p for p in NOT if p not in keep]
case(1, ready=True, rec=rec(1), why=None)
case(2, ready=True, rec=rec(2), mergeable="UNKNOWN", why="has not said whether it merges cleanly")
case(3, ready=True, rec=rec(3), mergeable="", why="has not said whether it merges cleanly")
case(4, ready=True, rec=rec(4, review=H(4)), why=None)
case(5, rec=rec(5), session="pr", why="")
case(6, rec=rec(6), prq="q", has=["open question"], hasnt=only("open question"))
case(7, rec=rec(7), prq="qa", has=["answer waits for a session"], hasnt=only("answer waits for a session"))
case(8, rec=rec(8), mergeable="CONFLICTING", has=["conflicts with its base"], hasnt=only("conflicts with its base"))
# the #104 sequence: an approving review at an older commit, two commits pushed since, CI passed on the old head
case(9, rec=rec(9, review=OLD(9)[:7], head=OLD(9)), has=[])
case(10, rec=rec(10, review=OLD(10)[:7], head=H(10)), has=[H(10)[:7], OLD(10)[:7]], hasnt=["no final review", "no head"])
case(11, rec=rec(11, head=OLD(11)), has=[])          # a record for another head, naming the PR's head in its review
case(12, rec=None, has=["no final review"], hasnt=only("no final review", "no CI result"))   # no record: CI has no result either
case(13, rec=rec(13, review=None), has=["no head"], hasnt=only("no head"))
case(14, rec=rec(14, verdict="request_changes"), has=["request_changes"], hasnt=only("request_changes"))
case(15, rec=rec(15, ci="pending"), has=["CI pending"], hasnt=only("CI pending"))
case(16, rec=rec(16, ci="failed"), has=["CI failed"], hasnt=only("CI failed"))
case(17, rec=rec(17, ci="none"), has=["no CI result"], hasnt=only("no CI result"))
case(18, rec=rec(18, verdict="marker<script>alert(1)</script> ghp_Abc123def456Ghi789Jkl012Mno345Pqr678 /home/debian/secret/x.log"),
     has=["marker<script>"], hasnt=["ghp_Abc123", "/home/debian/secret"])
case(19, rec=rec(19), session="node", state="running")         # a session in node/<ID>: running, not pr-open
case(20, rec=rec(20), nodeq=True, state="question")            # QUESTION.md in node/<ID>
case(21, rec=rec(21), mergeable="CONFLICTING", has=["conflicts with its base"])
case(22, rec=rec(22, ci="pending"), prq="q", has=["open question", "CI pending"])
with open(sa + "/graph.yaml", "a") as g:
    for c in cases:
        g.write("  - {id: %s, track: now, name: pr-%s, deps: [], summary: \"open PR\"}\n" % (c["id"], c["id"].lower()))
rows, merge = [], {}
for c in cases:
    rows.append("%d node/%s-pr-%s %s false %s\n" % (c["pr"], c["id"], c["id"].lower(), c["head"], c["mergeable"]))
    if c.get("rec"): merge[str(c["pr"])] = c["rec"]
    os.makedirs("%s/pr/%d" % (sa, c["pr"]), exist_ok=True)
    open("%s/pr/%d/node" % (sa, c["pr"]), "w").write(c["id"] + "\n")
    os.makedirs("%s/node/%s" % (sa, c["id"]), exist_ok=True)
    if c.get("prq"): open("%s/pr/%d/QUESTION.md" % (sa, c["pr"]), "w").write("Q1: which way?\n")
    if c.get("prq") == "qa": open("%s/pr/%d/ANSWER.md" % (sa, c["pr"]), "w").write("left\n")
    if c.get("nodeq"): open("%s/node/%s/QUESTION.md" % (sa, c["id"]), "w").write("Q: node question\n")
open(sa + "/open-prs.tsv", "w").writelines(rows + ["51 spec/new-thing 0123abc true MERGEABLE\n"])
open(sa + "/open-prs.txt", "w").write("".join(r.split()[1] + "\n" for r in rows))
open(sa + "/merged-prs.tsv", "w").write("38 node/M01-merged-thing-old\n41 node/M01-merged-thing\n")
open(sa + "/merged-prs.txt", "w").write("38\n41\n")
open(sa + "/subjects.txt", "w").write("M02 second-merged: do it (#44)\nM01 merged-thing: the old one (#38)\n")
json.dump({"issue": 7, "merge": merge}, open(sa + "/report.json", "w"))
# the fixture's other states: running R01, failed F01, question Q02, answered A01, waiting-pr S01, ready Y01, waiting Z01
def mark(n, f, t): os.makedirs("%s/node/%s" % (sa, n), exist_ok=True); open("%s/node/%s/%s" % (sa, n, f), "w").write(t + "\n")
mark("F01", "FAILED", "gave up"); mark("Q02", "QUESTION.md", "Which one?"); mark("A01", "QUESTION.md", "Answered?")
mark("A01", "ANSWER.md", "yes"); mark("S01", "WAITING-PR", "51"); mark("R01", "starts", "1")
json.dump(cases, open(cases_file, "w"))
PY

# live sessions: R01 and K19 in node/<ID>, K05's PR in pr/<N>; a cmdline that loop.sh's alive() pattern matches
sess() { # <state folder> <key>
	fixture_start sh "$tmp/bin/run-session.sh" o/alpha "$2" >/dev/null 2>&1 </dev/null &
	pids="$pids $!"
	echo $! >"$1/session.pid"
}
sess "$sa/node/R01" R01
sess "$sa/node/K19" K19
sess "$sa/pr/605" 605
for p in $pids; do
	i=0
	until case $(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null) in *run-session.sh*) true ;; *) false ;; esac || [ $i -ge 500 ]; do
		sleep 0.02
		i=$((i + 1))
	done
done

(cd "$tmp/cwd" && python3 -I "$src/site.py" build --data-root "$root" --repos "$HOME/.config/noodlebot/repos" --out "$tmp/out" --now 1700001000 >"$tmp/build.log" 2>&1 </dev/null)
echo $? >"$tmp/rc"

python3 -I - "$tmp" "$src" <<'PY'
import json, os, sys
tmp, src = sys.argv[1:3]
fails = 0
def check(name, fn):
    global fails
    try:
        ok, why = fn(), ""
    except Exception as e:  # a missing file or key is a failed check, never a crash
        ok, why = False, " (%s: %s)" % (type(e).__name__, str(e)[:160])
    if ok: print("PASS: " + name)
    else:
        fails += 1; print("FAIL: " + name + why)
check("U04-AC-3 build exits 0 on the root with the cases", lambda: open(tmp + "/rc").read().strip() == "0")
cases = json.load(open(tmp + "/cases.json"))
repo = lambda: json.load(open(tmp + "/out/repo.acme.alpha.json", encoding="utf-8"))
node = lambda i: next(n for n in repo()["nodes"] if n["id"] == i)
for c in cases:
    i, ex = c["id"], c.get("state", "pr-open")
    tag = "U04-AC-3 (%s)" % i
    if ex != "pr-open":
        check("%s state %s: merge_ready and merge_why are null" % (tag, ex),
              lambda i=i, ex=ex: (node(i)["state"], node(i)["merge_ready"], node(i)["merge_why"]) == (ex, None, None))
        continue
    check("%s is pr-open and merge_ready is %s" % (tag, str(c["ready"]).lower()),
          lambda i=i, c=c: node(i)["state"] == "pr-open" and node(i)["merge_ready"] is c["ready"])
    if c["ready"]:
        if c["why"] is None:
            check("%s ready on MERGEABLE: merge_why is null" % tag, lambda i=i: node(i)["merge_why"] is None)
        else:
            check("%s ready, mergeable %r: merge_why says the forge has not said whether it merges cleanly" % (tag, c["mergeable"]),
                  lambda i=i, c=c: c["why"] in node(i)["merge_why"])
        continue
    check("%s not ready: merge_why is a non-empty string" % tag,
          lambda i=i: isinstance(node(i)["merge_why"], str) and node(i)["merge_why"].strip() != "")
    for p in c.get("has", []):
        check("%s merge_why names %r" % (tag, p.split("<")[0][:40]), lambda i=i, p=p: p in node(i)["merge_why"])
    if c.get("hasnt"):
        check("%s merge_why does not say a reason that does not hold (%s)" % (tag, ", ".join(c["hasnt"][:3]) + ", ..."),
              lambda i=i, c=c: node(i)["merge_why"] != "" and not [p for p in c["hasnt"] if p in node(i)["merge_why"]])
check("U04-AC-3 the not-ready texts hold none of the ready note (the forge has not said ...)",
      lambda: all("has not said whether" not in (node(c["id"])["merge_why"] or "x") for c in cases if c.get("state", "pr-open") == "pr-open" and not c["ready"] and c["mergeable"] == "MERGEABLE"))
# nodes of the other states of the fixture
for i, st in (("M01", "merged"), ("R01", "running"), ("F01", "failed"), ("Q02", "question"), ("A01", "answered"),
              ("S01", "waiting-pr"), ("Y01", "ready"), ("Z01", "waiting")):
    check("U04-AC-3 (%s) state %s: merge_ready and merge_why are null" % (i, st),
          lambda i=i, st=st: (node(i)["state"], node(i)["merge_ready"], node(i)["merge_why"]) == (st, None, None))
check("U04-AC-3 every node of the repository file has both keys", lambda: all("merge_ready" in n and "merge_why" in n for n in repo()["nodes"]))
# the schema
def validate(t, v, path="$"):
    if t == "string": return isinstance(v, str) or [path + " not a string"]
    if t == "integer": return (isinstance(v, int) and not isinstance(v, bool)) or [path + " not an integer"]
    if t == "number": return (isinstance(v, (int, float)) and not isinstance(v, bool)) or [path + " not a number"]
    if t == "boolean": return isinstance(v, bool) or [path + " not a boolean"]
    if isinstance(t, dict) and "nullable" in t: return True if v is None else validate(t["nullable"], v, path)
    if isinstance(t, dict) and "array" in t:
        if not isinstance(v, list): return [path + " not an array"]
        e = []
        for k, x in enumerate(v):
            r = validate(t["array"], x, "%s[%d]" % (path, k))
            if r is not True: e += r
        return e or True
    if isinstance(t, dict) and "object" in t:
        if not isinstance(v, dict): return [path + " not an object"]
        e = [path + " keys differ: " + ",".join(sorted(set(v) ^ set(t["object"])))] if set(v) != set(t["object"]) else []
        for k, kt in t["object"].items():
            if k in v:
                r = validate(kt, v[k], path + "." + k)
                if r is not True: e += r
        return e or True
    return [path + " unknown type in schema"]
schema = lambda: json.load(open(src + "/site-schema.json"))["files"]["repo"]
nodeschema = lambda: schema()["object"]["nodes"]["array"]["object"]
check("U04-AC-3 site-schema.json has merge_ready as a nullable boolean", lambda: nodeschema()["merge_ready"] == {"nullable": "boolean"})
check("U04-AC-3 site-schema.json has merge_why as a nullable string", lambda: nodeschema()["merge_why"] == {"nullable": "string"})
def valid():
    r = validate(schema(), repo())
    if r is not True: raise AssertionError("; ".join(r[:3]))
    return True
check("U04-AC-3 the repository file passes site-schema.json", valid)
sys.exit(1 if fails else 0)
PY
exit $?
