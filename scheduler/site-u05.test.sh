#!/bin/sh
# Test of scheduler/site.py build, the frozen-line note in the merge_why of a ready node (U05-AC-4). A runtime root is built
# in a scratch folder from copies of scheduler/testdata/site/ (alpha's graph, its merged and open PR lists) with nodes added
# to the copy, each with an open PR (K01..K18 without K17) and the merge record report.py writes in report.json.
#   sh scheduler/site-u05.test.sh   (make test)
#
# THE CONTRACT these checks fix (site.py build must give exactly this).
#   merge_ready of every node is U04's. For a pr-open node that is ready, and whose merge record has a NUMBER in "frozen":
#     merge_why is "changes frozen test lines: needs your approval" while the PR's head (open-prs.tsv) does not start with
#     the record's "approved" (null, or absent, or another sha: it does not), and "frozen test line changes approved" once it
#     does; U04's note "the forge has not said whether it merges cleanly" follows after "; " when mergeable is neither
#     MERGEABLE nor CONFLICTING. A ready node whose "frozen" is "none", null or absent has U04's merge_why (null, or the note
#     alone); a node that is not ready has U04's reasons, with no frozen-line text; other states have null and null.
#   The repository file passes scheduler/site-schema.json.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
fx=$src/testdata/site
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
cleanup() {
	chmod -R u+rwX "$tmp" 2>/dev/null
	rm -rf "$tmp"
}
trap cleanup EXIT
unset SCHED_HARNESS
base=$tmp/U05
root=$base/data HOME=$base/home
export HOME GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$base/cwd" "$HOME/.config/noodlebot" "$root/state/alpha/node" "$root/state/alpha/pr" "$root/repos"
sa=$root/state/alpha

cp "$fx/alpha/graph.yaml" "$sa/graph.yaml"
echo public >"$sa/visibility"
echo acme/alpha >"$HOME/.config/noodlebot/repos"
python3 -I - "$sa" "$base/cases.json" <<'PY'
import json, os, sys
sa, cases_file = sys.argv[1:3]
H = lambda k, c="c": "%02x" % k + c * 38          # a 40-character head
OLD = lambda k: "%02x" % k + "0" * 38
cases = []
NOTE = "the forge has not said whether it merges cleanly"
NEEDS = "changes frozen test lines: needs your approval"
DONE = "frozen test line changes approved"
def case(i, **kw):
    kw.setdefault("mergeable", "MERGEABLE"); kw.setdefault("ready", True)
    kw["id"] = "K%02d" % i; kw["pr"] = 700 + i; kw["head"] = H(i)
    cases.append(kw)
def rec(i, **kw):
    r = {"head": H(i), "review_head": H(i)[:7], "verdict": "approve", "ci": "passed", "id": 9}
    r.update(kw)
    return r
case(1, rec=rec(1, frozen="none", approved=None), why=None)
case(2, rec=rec(2), why=None)                                                    # a record from before U05: no such keys
case(3, rec=rec(3, frozen=2, approved=None), why=NEEDS)
case(4, rec=rec(4, frozen=2, approved=H(4)), why=DONE)
case(5, rec=rec(5, frozen=12, approved=H(5)[:7]), why=DONE)
case(6, rec=rec(6, frozen=2, approved=OLD(6)[:7]), why=NEEDS)                    # an approval naming an earlier head
case(7, rec=rec(7, frozen=2, approved=None), mergeable="UNKNOWN", why=NEEDS + "; " + NOTE)
case(8, rec=rec(8, frozen=2, approved=H(8)[:7]), mergeable="", why=DONE + "; " + NOTE)
case(9, rec=rec(9, frozen="none", approved=H(9)), mergeable="UNKNOWN", why=NOTE)
case(10, rec=rec(10, frozen=2, approved=H(10), ci="failed"), ready=False, has=["CI failed"], hasnt=["frozen", "approval", "approved"])
case(11, rec=rec(11, frozen=2, approved=H(11)), mergeable="CONFLICTING", ready=False, has=["conflicts with its base"], hasnt=["frozen", "approval", "approved"])
case(12, rec=rec(12, frozen=2, approved=H(12), unread=True), ready=False, has=["could not be read"], hasnt=["frozen", "approval", "approved"])
case(13, rec=rec(13, frozen=2, approved=None), prq=True, ready=False, has=["open question"], hasnt=["frozen", "approval", "approved"])
case(14, rec=rec(14, frozen=2), why=NEEDS)                                       # no "approved" key
case(15, rec=rec(15, frozen=None, approved=H(15)), why=None)                     # an approval, but no frozen line in the review
case(16, rec=rec(16, frozen=2, approved=H(16), verdict="request_changes"), ready=False, has=["request_changes"], hasnt=["frozen", "approval", "approved"])
case(18, rec=rec(18, frozen=3, approved=None), nodeq=True, state="question", why=None)   # not pr-open: null and null
with open(sa + "/graph.yaml", "a") as g:
    for c in cases:
        g.write("  - {id: %s, track: now, name: pr-%s, deps: [], summary: \"open PR\"}\n" % (c["id"], c["id"].lower()))
rows, merge = [], {}
for c in cases:
    rows.append("%d node/%s-pr-%s %s false %s\n" % (c["pr"], c["id"], c["id"].lower(), c["head"], c["mergeable"]))
    merge[str(c["pr"])] = c["rec"]
    os.makedirs("%s/pr/%d" % (sa, c["pr"]), exist_ok=True)
    open("%s/pr/%d/node" % (sa, c["pr"]), "w").write(c["id"] + "\n")
    os.makedirs("%s/node/%s" % (sa, c["id"]), exist_ok=True)
    if c.get("prq"): open("%s/pr/%d/QUESTION.md" % (sa, c["pr"]), "w").write("Q1: which way?\n")
    if c.get("nodeq"): open("%s/node/%s/QUESTION.md" % (sa, c["id"]), "w").write("Q: node question\n")
open(sa + "/open-prs.tsv", "w").writelines(rows + ["51 spec/new-thing 0123abc true MERGEABLE\n"])
open(sa + "/open-prs.txt", "w").write("".join(r.split()[1] + "\n" for r in rows))
open(sa + "/merged-prs.tsv", "w").write("38 node/M01-merged-thing-old\n41 node/M01-merged-thing\n")
open(sa + "/merged-prs.txt", "w").write("38\n41\n")
open(sa + "/subjects.txt", "w").write("M02 second-merged: do it (#44)\nM01 merged-thing: the old one (#38)\n")
json.dump({"issue": 7, "merge": merge}, open(sa + "/report.json", "w"))
def mark(n, f, t): os.makedirs("%s/node/%s" % (sa, n), exist_ok=True); open("%s/node/%s/%s" % (sa, n, f), "w").write(t + "\n")
mark("F01", "FAILED", "gave up"); mark("Q02", "QUESTION.md", "Which one?"); mark("A01", "QUESTION.md", "Answered?")
mark("A01", "ANSWER.md", "yes"); mark("S01", "WAITING-PR", "51")
json.dump(cases, open(cases_file, "w"))
PY

(cd "$base/cwd" && python3 -I "$src/site.py" build --data-root "$root" --repos "$HOME/.config/noodlebot/repos" --out "$base/out" --now 1700001000 >"$base/build.log" 2>&1 </dev/null)
echo $? >"$base/rc"

python3 -I - "$base" "$src" <<'PY'
import json, sys
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
check("U05-AC-4 build exits 0 on the root with the cases", lambda: open(tmp + "/rc").read().strip() == "0")
cases = json.load(open(tmp + "/cases.json"))
repo = lambda: json.load(open(tmp + "/out/repo.acme.alpha.json", encoding="utf-8"))
node = lambda i: next(n for n in repo()["nodes"] if n["id"] == i)
for c in cases:
    i, ex = c["id"], c.get("state", "pr-open")
    tag = "U05-AC-4 (%s)" % i
    if ex != "pr-open":
        check("%s state %s, frozen 3: merge_ready and merge_why are null" % (tag, ex),
              lambda i=i, ex=ex: (node(i)["state"], node(i)["merge_ready"], node(i)["merge_why"]) == (ex, None, None))
        continue
    check("%s is pr-open and merge_ready is %s (U04's)" % (tag, str(c["ready"]).lower()),
          lambda i=i, c=c: node(i)["state"] == "pr-open" and node(i)["merge_ready"] is c["ready"])
    if c["ready"]:
        check("%s merge_why is %r" % (tag, c["why"]), lambda i=i, c=c: node(i)["merge_why"] == c["why"])
        continue
    check("%s not ready: merge_why is a non-empty string naming %s" % (tag, c["has"][0]),
          lambda i=i, c=c: isinstance(node(i)["merge_why"], str) and all(p in node(i)["merge_why"] for p in c["has"]))
    check("%s not ready: merge_why has no frozen-line text" % tag,
          lambda i=i, c=c: isinstance(node(i)["merge_why"], str) and not [p for p in c["hasnt"] if p in node(i)["merge_why"]])
for i, st in (("M01", "merged"), ("F01", "failed"), ("Q02", "question"), ("A01", "answered"), ("S01", "waiting-pr")):
    check("U05-AC-4 (%s) state %s: merge_ready and merge_why are null" % (i, st),
          lambda i=i, st=st: (node(i)["state"], node(i)["merge_ready"], node(i)["merge_why"]) == (st, None, None))
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
def valid():
    r = validate(json.load(open(src + "/site-schema.json"))["files"]["repo"], repo())
    if r is not True: raise AssertionError("; ".join(r[:3]))
    return True
check("U05-AC-4 the repository file passes site-schema.json", valid)
sys.exit(1 if fails else 0)
PY
exit $?
