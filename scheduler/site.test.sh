#!/bin/sh
# Test of scheduler/site.py build (W01 site-data): a runtime root and a HOME built under a temporary
# directory from scheduler/testdata/site/ (two public repositories, a private one, one without a
# visibility record), with fake tokens and absolute paths planted, fake live processes, a fake gh.
#   sh scheduler/site.test.sh   (make test)
#
# Key names the test expects (scheduler/site-schema.json must name exactly these; format: version 1,
# files {repo, throttle, activity}; T = "string" | "integer" | "number" | "boolean" |
# {"object": {key: T}} | {"array": T} | {"nullable": T}):
#   repo.<owner>.<name>.json: repo, name, running, stop, nodes[], open_prs[], spec_prs[]
#     node: id name track deps unlocks summary size(nullable) has_spec criteria[{id,text}] starts state
#           pr(nullable int) started(nullable int) text(nullable) url(nullable) mergeable(nullable)
#           waiting_for[string]
#     open_prs[]: number branch mergeable bot;  spec_prs[]: number branch added[{id name track deps
#           summary}] changed[{id name track deps summary; unchanged = null}] removed[id]
#   throttle.json: windows[{name utilization resets_at status}] updated held reason(nullable)
#           history[{t u}]
#   activity.json: events[{time repo text}] triage[{repo number url state text(nullable)
#           spec_pr(nullable)}] deploy{version(nullable) previous(nullable) rejected[] events[{time repo text}]}
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
fx=$src/testdata/site
tmp=$(mktemp -d)
pids=
cleanup() {
	for p in $pids; do kill "$p" 2>/dev/null; done
	pkill -f "$tmp/bin/run-session.sh" 2>/dev/null
	chmod -R u+rwX "$tmp" 2>/dev/null
	rm -rf "$tmp"
}
trap cleanup EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

root=$tmp/data HOME=$tmp/home
res=$tmp/res
export HOME GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
NOODLEBOT_DATA=$root; export NOODLEBOT_DATA
mkdir -p "$res" "$tmp/bin" "$tmp/cwd" "$HOME/.config/noodlebot" "$root/state" "$root/repos" "$root/deploy"
GHB=A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8
ANB=Zy9X8w7V6u5T4s3R2q1P0oN9m8L7k6J5
GH=ghp_$GHB
ANT=sk-ant-api03-$ANB
HEX40=0123456789abcdef0123456789abcdef01234567
B64=QUFBQUJCQkNDQ0REREVFRUZGRkdHR0hISElJSUpKSktL

# fakes: gh and the other network tools record any call; a live session is a process whose cmdline
# matches loop.sh's alive() pattern.
for c in gh curl wget; do
	printf '#!/bin/sh\necho "%s $*" >>"%s/calls.log"\nexit 1\n' "$c" "$tmp" >"$tmp/bin/$c"
	chmod +x "$tmp/bin/$c"
done
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$tmp/bin/run-session.sh"
PATH=$tmp/bin:$PATH

g() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}" 2>/dev/null; }
# mk_clone <name> <graph> [<spec graph>]: a clone with origin/main (graph, node specs) and a spec branch.
mk_clone() {
	o=$tmp/origin-$1
	git init -q -b main "$o"
	mkdir -p "$o/docs" "$o/nodes"
	cp "$2" "$o/docs/graph.yaml"
	[ ! -d "$fx/$1/nodes" ] || cp "$fx/$1"/nodes/*.md "$o/nodes/"
	git -C "$o" add -A
	git -C "$o" -c user.name=t -c user.email=t@t commit -q -m "init"
	if [ -n "${3:-}" ]; then
		git -C "$o" checkout -q -b spec/new-thing
		cp "$3" "$o/docs/graph.yaml"
		git -C "$o" -c user.name=t -c user.email=t@t commit -q -am "spec"
		git -C "$o" checkout -q main
	fi
	git clone -q "$o" "$root/repos/$1" 2>/dev/null
}
mk_clone alpha "$fx/alpha/graph.yaml" "$fx/alpha/spec-graph.yaml"
mk_clone bravo "$fx/bravo/graph.yaml"
mk_clone hidden "$fx/bravo/graph.yaml"

# state of the loops
sa=$root/state/alpha sb=$root/state/bravo sh_=$root/state/hidden sn=$root/state/novis
mkdir -p "$sa/node" "$sa/issue" "$sb/node" "$sh_/node" "$sh_/issue" "$sn/node"
echo public >"$sa/visibility"; printf public >"$sb/visibility"; echo private >"$sh_/visibility"
cp "$fx/alpha/graph.yaml" "$sa/graph.yaml"; cp "$fx/bravo/graph.yaml" "$sb/graph.yaml"; cp "$fx/bravo/graph.yaml" "$sh_/graph.yaml"
printf '38 node/M01-merged-thing-old\n41 node/M01-merged-thing\n' >"$sa/merged-prs.tsv"
printf '38\n41\n' >"$sa/merged-prs.txt"
printf '51 spec/new-thing 0123abc true MERGEABLE\n52 node/P01-pr-open-thing 4567def false CONFLICTING\n' >"$sa/open-prs.tsv"
cut -d' ' -f2 "$sa/open-prs.tsv" >"$sa/open-prs.txt"
printf 'M02 second-merged: do it (#44)\nunrelated: thing (#99)\nM01 merged-thing: the old one (#38)\n' >"$sa/subjects.txt"
: >"$sb/merged-prs.tsv"; : >"$sb/merged-prs.txt"; : >"$sb/open-prs.tsv"; : >"$sb/open-prs.txt"; : >"$sb/subjects.txt"
printf '77 node/H99-secret-pr 89abcde true MERGEABLE\n' >"$sh_/open-prs.tsv"
: >"$sh_/merged-prs.tsv"; : >"$sh_/subjects.txt"
printf '{"issue": 7}\n' >"$sa/report.json"
echo v1.0-7-gabc1234 >"$sb/version"; echo v9.9.9-hidden >"$sh_/version"
printf 'abc123def456\nsecond line is ignored\n' >"$root/deploy/previous"
printf '0badc0de1234\n5eed5eed5678\n' >"$root/deploy/rejected"
mkdir -p "$sh_/issue/99"; echo "BETA-SECRET triage question" >"$sh_/issue/99/QUESTION.md"
printf '2026-11-01T10:09:00Z BETA-SECRET hidden event\n2026-11-01T10:09:01Z deployed h1..h2 (version BETA-SECRET)\n' >"$sh_/status.log"

# nodes
mark() { mkdir -p "$sa/node/$1"; [ -z "${3:-}" ] || printf '%s\n' "$3" >"$sa/node/$1/$2"; }
mark M01 FAILED "stale failure of a merged node"; echo 2 >"$sa/node/M01/starts"
mark R01 starts; echo 1 >"$sa/node/R01/starts"
mark F01 FAILED "gave up after $GH in $root/state/alpha/x.log"; echo 2 >"$sa/node/F01/starts"
printf 'second line of FAILED\n' >>"$sa/node/F01/FAILED"
mark Q01 QUESTION.md "Use $ANT for $HOME/x? see https://example.com/a/b/c"; echo "12 home issue" >"$sa/node/Q01/issue"
printf 'SECOND-LINE-MARKER\n' >>"$sa/node/Q01/QUESTION.md"; echo 1 >"$sa/node/Q01/starts"
mark Q02 QUESTION.md "Which one?"
mark A01 QUESTION.md "Answered?"; mark A01 ANSWER.md "yes"
mark S01 WAITING-PR 51
mark P01 starts
mkdir -p "$sa/node/Y01"
# triage folders
ti() { mkdir -p "$sa/issue/$1"; [ -z "${3:-}" ] || printf '%s\n' "$3" >"$sa/issue/$1/$2"; }
ti 21 FAILED "running wins over this"; ti 22 FAILED "triage failed $GH at /srv/x/y"; ti 22 QUESTION.md "failed wins over this"
ti 23 QUESTION.md "Triage asks $ANT?"; ti 24 QUESTION.md "q"; ti 24 ANSWER.md "a"; ti 25 starts; ti 26 WAITING-PR 51
# logs
python3 -I - "$root" "$HOME" "$GH" "$ANT" "$HEX40" "$B64" "$sa/status.log" "$sb/status.log" "$root/state/usage.json" <<'EOF'
import json, sys
root, home, gh, ant, hex40, b64, alog, blog, ufile = sys.argv[1:10]
def ts(i): return "2026-11-01T10:%02d:%02dZ" % (i // 60, i % 60)
out = []
for i in range(1, 131):
    k = i % 3
    if 2 <= i <= 13:
        t = ["deployed c%d..d%d (version v0.%d)" % (i, i, i), "not deployed: make test failed on d%d" % i,
             "rolled back d%d..c%d (version v0.%d)" % (i, i, i)][k]
    else:
        t = ("open=[A01 B01] merged-prs=[M01]; " if i % 2 else "") + "event number %d" % i
    if i == 126: t = "event number 126 home %s/.config/x" % home
    if i == 127: t = "event number 127 blob %s end" % b64
    if i == 128: t = "event number 128 commit %s ok" % hex40
    if i == 129: t = "open=[A01 B01] merged-prs=[M01]; " + "word1, " * 60
    if i == 130: t = "event number 130 token %s and %s at %s/state/alpha/x.log see https://github.com/acme/alpha/pull/5 and /usr/bin/foo" % (gh, ant, root)
    out.append("%s %s" % (ts(i), t))
open(alog, "w").write("\n".join(out) + "\n")
open(blog, "w").write("%s bravo tie\n%s bravo old\n%s bravo newest\n" % (ts(130), ts(5), "2026-11-01T10:02:20Z"))
json.dump({"updated": 1700000950, "projectedX": 1,
           "windows": {"five_hour": {"resetsAt": 1700005000, "utilization": 0.62, "status": "allowed"},
                       "seven_day": {"resetsAt": 1700400000, "utilization": 0.31, "status": "allowed_warning"}},
           "samples5h": [[1699990000 + 60 * i, round(i / 200, 3), 1700005000] for i in range(130)]}, open(ufile, "w"))
EOF
# planted secrets in the files the build must never read; made unreadable below
mkdir -p "$sa/issue/21"
for f in "$sa/node/R01/session.jsonl" "$sa/node/R01/session.stderr" "$sa/node/R01/unattended.md" "$sa/node/R01/env" \
		"$sa/issue/21/session.jsonl" "$sa/issue/21/session.stderr" "$sa/env" "$HOME/.config/noodlebot/env" "$HOME/.config/noodlebot/token"; do
	printf '{"text": "%s %s %s/x %s"}\n' "$GH" "$ANT" "$HOME" "SESSION-SECRET" >"$f"
done
cp "$fx/repos" "$HOME/.config/noodlebot/repos"
touch "$HOME/STOP-bravo"
# live sessions (a node and a triage), a loop's lock held
setsid sh "$tmp/bin/run-session.sh" o/alpha R01 >/dev/null 2>&1 </dev/null & pids="$pids $!"; echo $! >"$sa/node/R01/session.pid"
setsid sh "$tmp/bin/run-session.sh" o/alpha 21 >/dev/null 2>&1 </dev/null & pids="$pids $!"; echo $! >"$sa/issue/21/session.pid"
touch -d @1700000100 "$sa/node/R01/session.pid"
setsid sh -c 'exec 9>"$1"; flock -n 9 && exec sleep 600' x "$sa/loop.lock" >/dev/null 2>&1 </dev/null & pids="$pids $!"
sleep 0.5
chmod 000 "$sa/node/R01/session.jsonl" "$sa/node/R01/session.stderr" "$sa/node/R01/unattended.md" "$sa/node/R01/env" \
	"$sa/issue/21/session.jsonl" "$sa/issue/21/session.stderr" "$sa/env" "$HOME/.config/noodlebot/env" "$HOME/.config/noodlebot/token"

# builds: out1/out2 the same state (throttle hold), out3 throttle open and a short history, out4 no --throttle
mkdir -p "$tmp/out1" "$tmp/out2" "$tmp/out3" "$tmp/out4"; echo stale >"$tmp/out1/stale.json"
HOLD='hold: 5-hour window projected 95% before the reset'
snap() { find "$tmp" -mindepth 1 \( -path "$tmp/out*" -o -path "$res" \) -prune -o -printf '%p %y %m %s %T@\n' 2>/dev/null | sort; }
snap >"$res/before"
build() { # <out> <rc file> [args]
	o=$1 rcf=$2; shift 2
	(cd "$tmp/cwd" && python3 -I "$src/site.py" build --data-root "$root" --repos "$HOME/.config/noodlebot/repos" --out "$o" --now 1700001000 "$@" >"$res/$(basename "$o").log" 2>&1 </dev/null)
	echo $? >"$rcf"
}
build "$tmp/out1" "$res/rc1" --throttle "$HOLD"
build "$tmp/out2" "$res/rc2" --throttle "$HOLD"
snap >"$res/after"
python3 -I - "$root/state/usage.json" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["samples5h"] = d["samples5h"][:5]; json.dump(d, open(p, "w"))
EOF
snap >"$res/before3"
build "$tmp/out3" "$res/rc3" --throttle "open: usage is fine"
build "$tmp/out4" "$res/rc4"
snap >"$res/after3"
# out5: full 40-character commit hashes in the deploy record (cut to 12 characters before the filter)
H1=0123456789abcdef0123456789abcdef01234567 H2=fedcba9876543210fedcba9876543210fedcba98 H3=a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
mkdir -p "$tmp/out5"
printf '%s\n' "$H1" >"$root/deploy/previous"
printf '%s\n%s\n' "$H2" "$H3" >"$root/deploy/rejected"
build "$tmp/out5" "$res/rc5"
# out6: an open spec/* PR whose branch is not in the clone (fork, or opened after the last fetch)
printf '53 spec/not-fetched 0abc123 true MERGEABLE\n' >>"$sa/open-prs.tsv"
printf 'spec/not-fetched\n' >>"$sa/open-prs.txt"
mkdir -p "$tmp/out6"
build "$tmp/out6" "$res/rc6" --throttle "$HOLD"
# out7: usage.json holding NaN and Infinity tokens
python3 -I - "$root/state/usage.json" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('"utilization": 0.62', '"utilization": NaN', 1)
s = s.replace(', 0.005,', ', Infinity,', 1)
open(p, "w").write(s)
EOF
mkdir -p "$tmp/out7"
build "$tmp/out7" "$res/rc7" --throttle "$HOLD"
echo "$tmp" >"$res/tmp"

cat >"$res/check.py" <<'EOF'
import json, os, re, sys
src, tmp, root, home, gh, ant = sys.argv[1:7]
ghb, anb = gh[4:], ant[len("sk-ant-api03-"):]
res = tmp + "/res"
out = [tmp + "/out%d" % i for i in (1, 2, 3, 4)]
fails = 0
def check(name, fn):
    global fails
    try:
        ok = fn()
        why = "" if ok else ""
    except Exception as e:  # a missing file or key is a failed check, never a crash
        ok, why = False, " (%s: %s)" % (type(e).__name__, str(e)[:120])
    if ok: print("PASS: " + name)
    else:
        fails += 1; print("FAIL: " + name + why)
def J(d, f): return json.load(open(os.path.join(d, f), encoding="utf-8"))
def rc(i): return open("%s/rc%d" % (res, i)).read().strip()
def node(d, repo, i):
    return next(n for n in J(d, "repo.acme.%s.json" % repo)["nodes"] if n["id"] == i)
def strings(x):
    if isinstance(x, str): yield x
    elif isinstance(x, dict):
        for v in x.values(): yield from strings(v)
    elif isinstance(x, list):
        for v in x: yield from strings(v)
def allbytes(d):
    return b"".join(open(os.path.join(d, f), "rb").read() for f in sorted(os.listdir(d)))

# ---- W01-AC-1
files = ["activity.json", "repo.acme.alpha.json", "repo.acme.bravo.json", "throttle.json"]
check("W01-AC-1 build exits 0 on the fixture", lambda: rc(1) == "0" and rc(2) == "0")
check("W01-AC-1 --out holds exactly the repo files of the public repositories, throttle.json and activity.json (stale file replaced)",
      lambda: sorted(os.listdir(out[0])) == files)
def validate(t, v, path="$"):
    if t == "string": return isinstance(v, str) or [path + " not a string"]
    if t == "integer": return (isinstance(v, int) and not isinstance(v, bool)) or [path + " not an integer"]
    if t == "number": return (isinstance(v, (int, float)) and not isinstance(v, bool)) or [path + " not a number"]
    if t == "boolean": return isinstance(v, bool) or [path + " not a boolean"]
    if isinstance(t, dict) and "nullable" in t: return True if v is None else validate(t["nullable"], v, path)
    if isinstance(t, dict) and "array" in t:
        if not isinstance(v, list): return [path + " not an array"]
        e = []
        for i, x in enumerate(v):
            r = validate(t["array"], x, "%s[%d]" % (path, i))
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
schema = lambda: json.load(open(src + "/site-schema.json"))
check("W01-AC-1 site-schema.json has version 1 and names repo, throttle and activity",
      lambda: schema()["version"] == 1 and sorted(schema()["files"]) == ["activity", "repo", "throttle"])
for f in files:
    kind = "repo" if f.startswith("repo.") else f[:-5]
    def v(f=f, kind=kind):
        r = validate(schema()["files"][kind], J(out[0], f))
        if r is not True: raise AssertionError("; ".join(r[:3]))
        return True
    check("W01-AC-1 %s has exactly the keys of the schema, of the named types" % f, v)
def bytes_ok(f):
    raw = open(os.path.join(out[0], f), "rb").read().decode("utf-8").rstrip("\n")
    d = json.loads(raw)
    return raw in (json.dumps(d, sort_keys=True, separators=(",", ":")), json.dumps(d, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
for f in files:
    check("W01-AC-1 %s is sorted-key JSON without spaces" % f, lambda f=f: bytes_ok(f))
    check("W01-AC-1 %s is byte-identical in two builds of the same state" % f,
          lambda f=f: open(os.path.join(out[0], f), "rb").read() == open(os.path.join(out[1], f), "rb").read())

# ---- W01-AC-2
a = lambda: J(out[0], "repo.acme.alpha.json")
check("W01-AC-2 repo file names the repository, the loop running (lock held) and no STOP", lambda: (a()["repo"], a()["name"], a()["running"], a()["stop"]) == ("acme/alpha", "alpha", True, False))
check("W01-AC-2 bravo: loop not running, ~/STOP-bravo exists", lambda: (lambda b: (b["name"], b["running"], b["stop"]))(J(out[0], "repo.acme.bravo.json")) == ("bravo", False, True))
ids = ["M01", "M02", "R01", "F01", "Q01", "Q02", "A01", "S01", "P01", "Y01", "Z01"]
check("W01-AC-2 the nodes are those of state/<name>/graph.yaml, in graph order", lambda: [n["id"] for n in a()["nodes"]] == ids)
nd = lambda i: node(out[0], "alpha", i)
check("W01-AC-2 name, track, deps, summary of a node", lambda: (lambda n: (n["name"], n["track"], n["deps"], n["summary"]))(nd("Y01")) == ("ready-thing", "now", ["M01", "M02"], "Ready to start"))
check("W01-AC-2 unlocks are computed from the graph, in graph order", lambda: nd("M01")["unlocks"] == ids[2:] and nd("Y01")["unlocks"] == ["Z01"] and nd("Z01")["unlocks"] == [])
check("W01-AC-2 size from the spec's header row (S, M, L)", lambda: (nd("M01")["size"], nd("R01")["size"], nd("Y01")["size"]) == ("S", "M", "L"))
check("W01-AC-2 a node without spec: size null, no criteria, has_spec false", lambda: (lambda n: (n["size"], n["criteria"], n["has_spec"]))(nd("Z01")) == (None, [], False) and nd("Y01")["has_spec"] is True)
check("W01-AC-2 criteria: ID and text after the dash", lambda: nd("M01")["criteria"][0] == {"id": "M01-AC-1", "text": "Short text one. *Verify:* `scheduler/foo.test.sh`."} and [c["id"] for c in nd("Y01")["criteria"]] == ["Y01-AC-1", "Y01-AC-2", "Y01-AC-3"])
check("W01-AC-2 a criterion text is cut to 600 characters (after the filter)", lambda: len(nd("M01")["criteria"][1]["text"]) == 600 and nd("M01")["criteria"][1]["text"].startswith("Reads"))
check("W01-AC-2 starts used, from node/<ID>/starts (0 when absent)", lambda: (nd("R01")["starts"], nd("F01")["starts"], nd("Y01")["starts"]) == (1, 2, 0))
check("W01-AC-2 state merged with the highest PR number of merged-prs.tsv (a FAILED does not matter)", lambda: (nd("M01")["state"], nd("M01")["pr"]) == ("merged", 41))
check("W01-AC-2 state merged by a squash subject, PR number from its (#N)", lambda: (nd("M02")["state"], nd("M02")["pr"]) == ("merged", 44))
check("W01-AC-2 state running (live session, also with a FAILED) with the start time from session.pid's mtime", lambda: (nd("R01")["state"], nd("R01")["started"]) == ("running", 1700000100))
check("W01-AC-2 state failed with the first line of FAILED only, filtered", lambda: (lambda n: n["state"] == "failed" and n["text"].startswith("gave up after [redacted] in") and "second line" not in n["text"] and "…" in n["text"])(nd("F01")))
check("W01-AC-2 state question with the first line of QUESTION.md and the home issue's URL", lambda: (lambda n: n["state"] == "question" and n["url"] == "https://github.com/acme/alpha/issues/12" and "SECOND-LINE-MARKER" not in n["text"] and "https://example.com/a/b/c" in n["text"])(nd("Q01")))
check("W01-AC-2 question without node/<ID>/issue: the status issue's URL (report.json)", lambda: (nd("Q02")["state"], nd("Q02")["text"], nd("Q02")["url"]) == ("question", "Which one?", "https://github.com/acme/alpha/issues/7"))
check("W01-AC-2 state answered (QUESTION.md and ANSWER.md)", lambda: nd("A01")["state"] == "answered")
check("W01-AC-2 state waiting-pr with the spec PR's number", lambda: (nd("S01")["state"], nd("S01")["pr"]) == ("waiting-pr", 51))
check("W01-AC-2 state pr-open with the PR's number and mergeable state", lambda: (nd("P01")["state"], nd("P01")["pr"], nd("P01")["mergeable"]) == ("pr-open", 52, "CONFLICTING"))
check("W01-AC-2 state held: a node ready.py would start while the throttle line says hold", lambda: nd("Y01")["state"] == "held")
n3 = lambda i: node(out[2], "alpha", i)
check("W01-AC-2 state ready with every detail null (throttle line open)", lambda: (lambda n: (n["state"], n["pr"], n["started"], n["text"], n["url"], n["mergeable"], n["waiting_for"]))(n3("Y01")) == ("ready", None, None, None, None, None, []))
check("W01-AC-2 state waiting with the deps not yet merged", lambda: (nd("Z01")["state"], nd("Z01")["waiting_for"]) == ("waiting", ["Y01"]))

# ---- W01-AC-3
check("W01-AC-3 open PRs: number, branch, mergeable state, bot author", lambda: a()["open_prs"] == [
    {"number": 51, "branch": "spec/new-thing", "mergeable": "MERGEABLE", "bot": True},
    {"number": 52, "branch": "node/P01-pr-open-thing", "mergeable": "CONFLICTING", "bot": False}])
check("W01-AC-3 a repository without open PRs lists none", lambda: J(out[0], "repo.acme.bravo.json")["open_prs"] == [] and J(out[0], "repo.acme.bravo.json")["spec_prs"] == [])
sp = lambda: a()["spec_prs"]
check("W01-AC-3 one entry for the open spec/* PR only", lambda: [(p["number"], p["branch"]) for p in sp()] == [(51, "spec/new-thing")])
check("W01-AC-3 spec PR: nodes added with their entry", lambda: sp()[0]["added"] == [{"id": "N01", "name": "new-thing", "track": "later", "deps": ["M01"], "summary": "A brand new node"}])
check("W01-AC-3 spec PR: nodes changed with the differing fields only (others null)", lambda: sp()[0]["changed"] == [
    {"id": "R01", "name": None, "track": None, "deps": ["M01", "M02"], "summary": None},
    {"id": "Y01", "name": None, "track": "later", "deps": None, "summary": "Changed summary"}])
check("W01-AC-3 spec PR: nodes removed", lambda: sp()[0]["removed"] == ["Z01"])

# ---- W01-AC-4
t = lambda i=0: J(out[i], "throttle.json")
check("W01-AC-4 both windows: utilization, reset time, status", lambda: t()["windows"] == [
    {"name": "five_hour", "utilization": 0.62, "resets_at": 1700005000, "status": "allowed"},
    {"name": "seven_day", "utilization": 0.31, "resets_at": 1700400000, "status": "allowed_warning"}])
check("W01-AC-4 the last reading's time", lambda: t()["updated"] == 1700000950)
check("W01-AC-4 hold line: held true with the reason", lambda: (t()["held"], t()["reason"]) == (True, "5-hour window projected 95% before the reset"))
check("W01-AC-4 open line: held false with the reason", lambda: (t(2)["held"], t(2)["reason"]) == (False, "usage is fine"))
check("W01-AC-4 no --throttle: reason null", lambda: t(3)["reason"] is None)
hist = lambda: [(p["t"], p["u"]) for p in t()["history"]]
samples = [(1699990000 + 60 * i, round(i / 200, 3)) for i in range(130)]
check("W01-AC-4 at most 60 history points from 130 samples", lambda: 2 <= len(t()["history"]) <= 60 and len(t()["history"]) >= 50)
check("W01-AC-4 the first and the last sample are kept", lambda: hist()[0] == samples[0] and hist()[-1] == samples[-1])
def even():
    idx = [samples.index(p) for p in hist()]
    gaps = [b - a_ for a_, b in zip(idx, idx[1:])]
    return all(g > 0 for g in gaps) and max(gaps) - min(gaps) <= 1
check("W01-AC-4 the points are thinned evenly (gaps differ by at most one sample)", even)
check("W01-AC-4 up to 60 samples are kept as they are", lambda: [(p["t"], p["u"]) for p in t(2)["history"]] == samples[:5])

# ---- W01-AC-5
act = lambda: J(out[0], "activity.json")
ev = lambda: act()["events"]
check("W01-AC-5 the last 100 events across the published repositories", lambda: len(ev()) == 100)
check("W01-AC-5 events are newest first (ties: list order, then the later line first)", lambda: [(e["repo"], e["text"][:12]) for e in ev()[:4]] == [
    ("acme/bravo", "bravo newest"), ("acme/alpha", "event number"), ("acme/bravo", "bravo tie"), ("acme/alpha", "word1, word1")] and ev()[0]["time"] == "2026-11-01T10:02:20Z")
check("W01-AC-5 the oldest event kept is alpha's line 33, the 100 newest of both logs", lambda: ev()[-1] == {"time": "2026-11-01T10:00:33Z", "repo": "acme/alpha", "text": "event number 33"})
check("W01-AC-5 the loop's open=[…] merged-prs=[…]; prefix is removed", lambda: not any(e["text"].startswith("open=") for e in ev()) and ev()[-1]["text"] == "event number 33")
check("W01-AC-5 an event text is cut to 300 characters (after the prefix is removed)", lambda: ev()[3]["text"] == ("word1, " * 60)[:300])
check("W01-AC-5 events carry time as written, repository and text", lambda: all(sorted(e) == ["repo", "text", "time"] for e in ev()) and ev()[2] == {"time": "2026-11-01T10:02:10Z", "repo": "acme/bravo", "text": "bravo tie"})
tr = lambda: {x["number"]: x for x in act()["triage"]}
check("W01-AC-5 triage issues of the published repositories only, by number, with their URL", lambda: sorted(tr()) == [21, 22, 23, 24, 25, 26] and tr()[21]["url"] == "https://github.com/acme/alpha/issues/21" and tr()[21]["repo"] == "acme/alpha")
check("W01-AC-5 triage state running (a session, also with a FAILED)", lambda: tr()[21]["state"] == "running")
check("W01-AC-5 triage state failed with its first line (also with a QUESTION.md)", lambda: tr()[22]["state"] == "failed" and tr()[22]["text"].startswith("triage failed [redacted]"))
check("W01-AC-5 triage state question with its first line", lambda: tr()[23]["state"] == "question" and tr()[23]["text"].startswith("Triage asks [redacted]"))
check("W01-AC-5 triage state answered", lambda: tr()[24]["state"] == "answered")
check("W01-AC-5 triage state idle: no session and no marker", lambda: tr()[25]["state"] == "idle" and tr()[25]["spec_pr"] is None)
check("W01-AC-5 a triage's spec PR from WAITING-PR (state idle there)", lambda: (tr()[26]["state"], tr()[26]["spec_pr"]) == ("idle", 51))
dep = lambda: act()["deploy"]
check("W01-AC-5 deploy version: the first published repository's state/<name>/version", lambda: dep()["version"] == "v1.0-7-gabc1234")
check("W01-AC-5 deploy previous (first line) and rejected (file order)", lambda: (dep()["previous"], dep()["rejected"]) == ("abc123def456", ["0badc0de1234", "5eed5eed5678"]))
check("W01-AC-5 deploy previous and rejected full hashes are cut to their first 12 characters", lambda: rc(5) == "0" and (lambda d: (d["previous"], d["rejected"]))(J(tmp + "/out5", "activity.json")["deploy"]) == ("0123456789ab", ["fedcba987654", "a1b2c3d4e5f6"]))
def dexp(i):
    return ["deployed c%d..d%d (version v0.%d)", "not deployed: make test failed on d%d", "rolled back d%d..c%d (version v0.%d)"][i % 3].replace("%d", "{}").format(*([i] * 3))
check("W01-AC-5 the last 10 deploy events of the whole log (deployed, not deployed, rolled back), newest first", lambda: [e["text"] for e in dep()["events"]] == [dexp(i) for i in range(13, 3, -1)])
check("W01-AC-5 a deploy event has time and repository", lambda: dep()["events"][0] == {"time": "2026-11-01T10:00:13Z", "repo": "acme/alpha", "text": dexp(13)})

# ---- W01-AC-6
blob = b"".join(allbytes(d) for d in out if sorted(os.listdir(d)) == files)  # empty unless the build made its files
check("W01-AC-6 the build succeeds with session logs, stderr, env, prompts and the token file unreadable", lambda: rc(1) == "0" and rc(3) == "0" and rc(4) == "0")
for what, s in (("the fake GitHub token", ghb), ("the fake Anthropic token", anb), ("the token prefix ghp_", "ghp_"), ("sk-ant-", "sk-ant-"),
                ("the 40-hex run", "0123456789abcdef0123456789abcdef01234567"), ("a base64 run of 40 or more", "QUFBQUJCQkNDQ0REREVFRUZGRkdHR0hISElJ"),
                ("the secret of the unread session logs", "SESSION-SECRET")):
    check("W01-AC-6 output has not %s" % what, lambda s=s: bool(blob) and s.encode() not in blob)
check("W01-AC-6 output has neither the runtime root nor HOME", lambda: bool(blob) and root.encode() not in blob and home.encode() not in blob and tmp.encode() not in blob)
URL = re.compile(r"https?://\S+")
PATH = re.compile(r"(?<![\w.:/~-])/[\w.@+-]+(?:/[\w.@+-]*)+")
def nopath():
    bad = []
    for d in (out[0], out[2], out[3]):
        for f in files:
            for s in strings(J(d, f)):
                bad += PATH.findall(URL.sub("", s))
    return not bad and bool(blob)
check("W01-AC-6 no absolute local path in any string of any file (URLs aside)", nopath)
check("W01-AC-6 planted paths and tokens are replaced by … and [redacted] in the status log", lambda: any("[redacted]" in e["text"] and "…" in e["text"] for e in ev()))
check("W01-AC-6 a URL is kept intact", lambda: any("see https://github.com/acme/alpha/pull/5 and" in e["text"] for e in ev()))
check("W01-AC-6 the 40-hex run is replaced, the rest of its line kept", lambda: any(e["text"].startswith("event number 128 commit ") and "[redacted]" in e["text"] and e["text"].endswith(" ok") for e in ev()))

# ---- W01-AC-7
check("W01-AC-7 no file for the private repository or the one without visibility record", lambda: sorted(os.listdir(out[0])) == files)
check("W01-AC-7 none of the private repository's events, PRs, triage issues or deploys appear anywhere", lambda: bool(blob) and not any(s in blob.decode().lower() for s in ("beta-secret", "hidden", "novis", "h99", "v9.9.9")))
check("W01-AC-7 activity.json has events of public repositories only", lambda: {e["repo"] for e in ev()} == {"acme/alpha", "acme/bravo"})
def same(a_, b_): return open(a_).read() == open(b_).read()
check("W01-AC-7 the build writes nothing outside --out (listing of the whole tree unchanged)", lambda: rc(1) == "0" and rc(4) == "0" and sorted(os.listdir(out[0])) == files and same(res + "/before", res + "/after") and same(res + "/before3", res + "/after3") and os.path.getsize(res + "/before") > 0)
check("W01-AC-7 no gh call and no other network tool call", lambda: rc(1) == "0" and rc(4) == "0" and not os.path.exists(tmp + "/calls.log"))
# ---- W01-AC-3 / W01-AC-4 additions: unfetched spec branch, non-finite usage values
def a6(): return J(tmp + "/out6", "repo.acme.alpha.json")
def sp6(n): return next(p for p in a6()["spec_prs"] if p["number"] == n)
check("W01-AC-3 a spec PR whose branch is not in the clone: build exits 0 and the PR is listed in open_prs", lambda: rc(6) == "0" and 53 in [p["number"] for p in a6()["open_prs"]])
check("W01-AC-3 an unfetched spec PR has an entry with added, changed and removed all empty (unknown, not every node removed)", lambda: (sp6(53)["added"], sp6(53)["changed"], sp6(53)["removed"]) == ([], [], []))
check("W01-AC-3 the entry of the fetched spec PR #51 is unchanged by the unfetched one", lambda: sp6(51) == next(p for p in J(out[0], "repo.acme.alpha.json")["spec_prs"] if p["number"] == 51))
def strict(path):
    def bad(c): raise ValueError("non-finite token " + c)
    json.loads(open(path, encoding="utf-8").read(), parse_constant=bad); return True
o7 = tmp + "/out7"
def hist7():
    d = J(o7, "throttle.json")
    return next(v for k, v in d.items() if isinstance(v, list) and k != "windows")
check("W01-AC-4 non-finite usage values: build exits 0 and writes all four files", lambda: rc(7) == "0" and all(os.path.exists(o7 + "/" + f) for f in ("activity.json", "throttle.json", "repo.acme.alpha.json", "repo.acme.bravo.json")))
check("W01-AC-4 every output file is strict JSON (no NaN or Infinity)", lambda: len(os.listdir(o7)) >= 4 and all(strict(o7 + "/" + f) for f in os.listdir(o7)))
check("W01-AC-4 a NaN window utilization comes out as null", lambda: J(o7, "throttle.json")["windows"][0]["utilization"] is None)
check("W01-AC-4 an Infinity sample is dropped or null, never non-finite", lambda: all(h.get("u") is None or abs(h["u"]) < float("inf") for h in hist7()))
sys.exit(1 if fails else 0)
EOF
python3 -I "$res/check.py" "$src" "$tmp" "$root" "$HOME" "$GH" "$ANT" >"$res/checks.out" 2>&1
rc=$?
cat "$res/checks.out"
n=$(grep -c '^FAIL' "$res/checks.out")
if [ "$rc" -gt 1 ]; then fail "the check harness itself failed (rc $rc)"; fi
fails=$((fails + n))
[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
