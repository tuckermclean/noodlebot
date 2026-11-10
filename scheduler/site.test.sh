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
# out8: free texts in which a URL runs into a local path (a node's FAILED line and a status-log line)
mark P01 FAILED "see https://x.com/a,$HOME/.local/x.log and https://y.org/b;$root/state/alpha/z.log plain https://plain.example/ok"
printf '2026-11-01T11:00:00Z glued https://x.com/a,%s/.local/x.log and https://y.org/b;%s/state/alpha/z.log plain https://plain.example/ev\n' "$HOME" "$root" >>"$sa/status.log"
mkdir -p "$tmp/out8"
build "$tmp/out8" "$res/rc8" --throttle "$HOLD"
# out9: session.pid files holding a huge number and a Unicode digit
mkdir -p "$sa/issue/27" "$sa/issue/28"
echo 99999999999999999999 >"$sa/issue/27/session.pid"
printf '²\n' >"$sa/issue/28/session.pid"
mkdir -p "$tmp/out9"
build "$tmp/out9" "$res/rc9" --throttle "$HOLD"
rm -rf "$sa/issue/27" "$sa/issue/28"
# out10: usage.json whose samples5h is not a list and whose windows is not an object
cp "$root/state/usage.json" "$res/usage.keep"
printf '{"updated": 1700000950, "windows": [1, 2], "samples5h": 5}\n' >"$root/state/usage.json"
mkdir -p "$tmp/out10"
build "$tmp/out10" "$res/rc10" --throttle "$HOLD"
cp "$res/usage.keep" "$root/state/usage.json"
# out11: a node's FAILED that is a symlink to a file holding a secret
rm -f "$sa/node/P01/FAILED"
echo "SYMLINK-SECRET" >"$tmp/symlink-target.txt"
ln -s "$tmp/symlink-target.txt" "$sa/node/P01/FAILED"
mkdir -p "$tmp/out11"
build "$tmp/out11" "$res/rc11" --throttle "$HOLD"
rm -f "$sa/node/P01/FAILED"
# out12: a throttle line "hold:x" without the space
mkdir -p "$tmp/out12"
build "$tmp/out12" "$res/rc12" --throttle 'hold:x'
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
# ---- review additions: glued URL paths, bad pid and usage files, symlinked marker, bare hold:
files4 = ("activity.json", "throttle.json", "repo.acme.alpha.json", "repo.acme.bravo.json")
def four(i): return rc(i) == "0" and all(os.path.exists("%s/out%d/%s" % (tmp, i, f)) for f in files4)
o8 = tmp + "/out8"
b8 = lambda: allbytes(o8)
check("W01-AC-6 glued URL and path: build exits 0, output has neither the runtime root nor HOME", lambda: rc(8) == "0" and bool(b8()) and root.encode() not in b8() and home.encode() not in b8() and tmp.encode() not in b8())
check("W01-AC-6 glued URL and path in a node's FAILED line: neither path appears in the node's text", lambda: (lambda t: bool(t) and root not in t and home not in t)(node(o8, "alpha", "P01")["text"]))
check("W01-AC-6 glued URL and path in a status-log line: neither path appears in the events", lambda: (lambda ev: any("glued" in e["text"] for e in ev) and not any(root in e["text"] or home in e["text"] for e in ev))(J(o8, "activity.json")["events"]))
check("W01-AC-6 a plain URL elsewhere in the same free text stays intact", lambda: "https://plain.example/ok" in node(o8, "alpha", "P01")["text"] and any("https://plain.example/ev" in e["text"] for e in J(o8, "activity.json")["events"]))
o9 = tmp + "/out9"
tr9 = lambda: {x["number"]: x for x in J(o9, "activity.json")["triage"]}
check("W01-AC-1 session.pid holding 99999999999999999999 and one holding a Unicode digit: build exits 0 and writes all four files", lambda: four(9))
check("W01-AC-1 a triage with an out-of-range session.pid is not running", lambda: tr9()[27]["state"] != "running")
check("W01-AC-1 a triage with a Unicode-digit session.pid is not running", lambda: tr9()[28]["state"] != "running")
o10 = tmp + "/out10"
def hist10():
    d = J(o10, "throttle.json")
    return next(v for k, v in d.items() if isinstance(v, list) and k != "windows")
check("W01-AC-1 usage.json with samples5h not a list and windows not an object: build exits 0 and writes all four files", lambda: four(10))
check("W01-AC-4 such a usage.json gives throttle.json an empty history and no windows", lambda: hist10() == [] and J(o10, "throttle.json")["windows"] == [])
o11 = tmp + "/out11"
check("W01-AC-6 a symlinked FAILED: build exits 0 and the target's content appears nowhere in the output", lambda: rc(11) == "0" and len(os.listdir(o11)) >= 4 and b"SYMLINK-SECRET" not in allbytes(o11))
check("W01-AC-6 a symlinked FAILED still marks the node failed, with text null", lambda: (lambda n: (n["state"], n["text"]))(node(o11, "alpha", "P01")) == ("failed", None))
o12 = tmp + "/out12"
check("W01-AC-4 --throttle 'hold:x': build exits 0 and throttle.json says held true", lambda: rc(12) == "0" and J(o12, "throttle.json")["held"] is True)
check("W01-AC-4 --throttle 'hold:x': a node ready.py would start is held in the same build", lambda: node(o12, "alpha", "Y01")["state"] == "held")
sys.exit(1 if fails else 0)
EOF
python3 -I "$res/check.py" "$src" "$tmp" "$root" "$HOME" "$GH" "$ANT" >"$res/checks.out" 2>&1
rc=$?
cat "$res/checks.out"
n=$(grep -c '^FAIL' "$res/checks.out")
if [ "$rc" -gt 1 ]; then fail "the check harness itself failed (rc $rc)"; fi
fails=$((fails + n))

# ---- W02 site-publish: site.py publish against a fake gh that records arguments, GH_TOKEN and the
# request body, and answers as told by $tmp/ghd/answer (200, 404, 422, 403, 500, fail).
PT=ghp_PUBLISHtokenVALUE0123456789abcdefXYZ
GID=0123abcd0123abcd0123abcd0123abcd
ghd=$tmp/ghd
mkdir -p "$ghd" "$tmp/ghbin"
{
	printf '#!/bin/sh\nd=%s\nPT=%s\n' "$ghd" "$PT"
	cat <<'FAKE'
n=$(date +%s%N).$$
printf '%s\n' "$@" >"$d/call.$n.args"
if [ "${GH_TOKEN:-}" = "$PT" ]; then echo ok >"$d/call.$n.tok"; else echo bad >"$d/call.$n.tok"; fi
prev=
for a in "$@"; do
	if [ "$prev" = --input ]; then
		if [ "$a" = - ]; then cat >"$d/call.$n.body"; else cp "$a" "$d/call.$n.body"; fi
	fi
	prev=$a
done
[ ! -e "$d/delay" ] || sleep 2
case $(cat "$d/answer" 2>/dev/null) in
200) echo '{"id":"x","files":{}}'; exit 0 ;;
404) echo '{"message":"Not Found","marker":"RESPONSEBODYMARK"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
422) echo '{"message":"Validation Failed","marker":"RESPONSEBODYMARK"}'; echo 'gh: Validation Failed (HTTP 422)' >&2; exit 1 ;;
403) echo '{"message":"Forbidden","marker":"RESPONSEBODYMARK"}'; echo 'gh: Forbidden (HTTP 403)' >&2; exit 1 ;;
500) echo '{"message":"Server Error","marker":"RESPONSEBODYMARK"}'; echo 'gh: Server Error (HTTP 500)' >&2; exit 1 ;;
*) echo 'gh: connection refused' >&2; exit 1 ;;
esac
FAKE
} >"$tmp/ghbin/gh"
chmod +x "$tmp/ghbin/gh"
rm -rf "$root/site"
cp "$HOME/.config/noodlebot/repos" "$tmp/pub-repos"
mkdir -p "$sb/node/B01"; rm -f "$sb/node/B01/starts"

cat >"$res/pub.py" <<'EOF'
import fcntl, glob, hashlib, json, os, re, subprocess, sys, time
src, tmp, root, home, tok, gid = sys.argv[1:7]
ghd = tmp + "/ghd"
HOLD = "hold: 5-hour window projected 95% before the reset"
fails = 0
def check(name, fn):
    global fails
    try:
        ok, why = fn(), ""
    except Exception as e:  # a missing file, key or call is a failed check, never a crash
        ok, why = False, " (%s: %s)" % (type(e).__name__, str(e)[:120])
    if ok: print("PASS: " + name)
    else:
        fails += 1; print("FAIL: " + name + why)
def one(name, fn):
    check(name, lambda: bool(fn()))

seen_calls, all_calls, outputs = set(), [], []
def new_calls():
    out = []
    for p in sorted(glob.glob(ghd + "/call.*.args")):
        if p in seen_calls: continue
        seen_calls.add(p); b = p[:-5]
        c = {"args": open(p).read().split("\n")[:-1], "tok": open(b + ".tok").read().strip()}
        c["body"] = json.load(open(b + ".body")) if os.path.exists(b + ".body") else None
        out.append(c); all_calls.append(c)
    return out
def answer(a): open(ghd + "/answer", "w").write(a)
def pub_args(now, extra=()):
    return [sys.executable, "-I", src + "/site.py", "publish", "--data-root", root, "--repos", tmp + "/pub-repos",
            "--gist", gid, "--throttle", HOLD, "--now", str(now)] + list(extra)
def env():
    e = dict(os.environ); e["PATH"] = tmp + "/ghbin:" + e["PATH"]; e["GH_TOKEN"] = tok
    return e
def pub(now, extra=()):
    r = subprocess.run(pub_args(now, extra), cwd=tmp + "/cwd", env=env(), stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    o, e = r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")
    outputs.append(o + e)
    return r.returncode, o, e, new_calls()
def files_of(c): return c["body"]["files"]
def manifest(c): return json.loads(files_of(c)["manifest.json"]["content"])
def mfiles(m):
    d = m["files"]
    return d
def bump(k): os.makedirs(tmp + "/data/state/bravo/node/B01", exist_ok=True); open(tmp + "/data/state/bravo/node/B01/starts", "w").write("%d\n" % k)
def pj():
    p = root + "/site/published.json"
    return open(p, "rb").read() if os.path.exists(p) else b"<absent>"
schema = json.load(open(src + "/site-schema.json"))["version"]
BR, AL = "repo.acme.bravo.json", "repo.acme.alpha.json"
BUILT = sorted(["activity.json", AL, BR, "throttle.json"])
S = {}

# ---- W02-AC-1: first publish, then a second run with nothing changed
answer("200")
T0 = 1700001000
S["rc1"], S["o1"], S["e1"], c1 = pub(T0)
one("W02-AC-1 first publish: exit 0 and exactly one gh call", lambda: S["rc1"] == 0 and len(c1) == 1)
one("W02-AC-1 the call is one PATCH gists/<ID> through gh api --input <file>, never a POST",
    lambda: c1[0]["args"][0] == "api" and "PATCH" in c1[0]["args"] and any(a.lstrip("/").endswith("gists/" + gid) for a in c1[0]["args"]) and "POST" not in c1[0]["args"] and "--input" in c1[0]["args"])
one("W02-AC-1 the first PATCH holds every built file (public repositories only) and manifest.json, and nothing else",
    lambda: sorted(files_of(c1[0])) == sorted(BUILT + ["manifest.json"]) and all(isinstance(v["content"], str) for v in files_of(c1[0]).values()))
M1 = lambda: manifest(c1[0])
one("W02-AC-1 the manifest holds the schema version of site-schema.json", lambda: schema in [v for k, v in M1().items() if isinstance(v, int) and ("version" in k or "schema" in k)])
one("W02-AC-1 the manifest holds updated and seen, both the publish time", lambda: M1()["updated"] == T0 and M1()["seen"] == T0)
one("W02-AC-1 the manifest holds each file's SHA-256", lambda: all(re.fullmatch(r"[0-9a-f]{64}", mfiles(M1())[f]) for f in BUILT))
one("W02-AC-1 the manifest hashes match the sent files' bytes",
    lambda: all(hashlib.sha256(files_of(c1[0])[f]["content"].encode("utf-8")).hexdigest() == mfiles(M1())[f] for f in BUILT))
one("W02-AC-1 the manifest hashes match the files built into $NOODLEBOT_DATA/site/out/",
    lambda: all(hashlib.sha256(open(root + "/site/out/" + f, "rb").read()).hexdigest() == mfiles(M1())[f] for f in BUILT))
one("W02-AC-1 published.json is written after a 2xx answer", lambda: pj() != b"<absent>" and len(pj()) > 2)
S["pj1"] = pj()
rc, o, e, c = pub(T0 + 10)
one("W02-AC-1 a second run with nothing changed makes no gh call at all, exit 0", lambda: rc == 0 and c == [])
one("W02-AC-1 the second run leaves published.json as it was", lambda: pj() == S["pj1"])
rc, o, e, c = pub(T0 + 899)
one("W02-AC-1 nothing changed and the keepalive not due (899 s): no gh call", lambda: rc == 0 and c == [])

# ---- W02-AC-2: a change in one repository, within and past --min-interval
bump(1)
rc, o, e, c = pub(T0 + 20)
one("W02-AC-2 a change within --min-interval of the last publish sends nothing, exit 0", lambda: rc == 0 and c == [])
one("W02-AC-2 a change within --min-interval leaves published.json as it was", lambda: pj() == S["pj1"])
T1 = T0 + 61
rc, o, e, c2 = pub(T1)
one("W02-AC-2 the next run past --min-interval sends the change in one call", lambda: rc == 0 and len(c2) == 1)
one("W02-AC-2 only that repository's file and manifest.json are sent (plus files whose own hash changed)",
    lambda: BR in files_of(c2[0]) and AL not in files_of(c2[0]) and "manifest.json" in files_of(c2[0])
    and sorted(files_of(c2[0])) == sorted(["manifest.json"] + [f for f in BUILT if mfiles(manifest(c2[0]))[f] != mfiles(M1())[f]]))
one("W02-AC-2 the changed file differs from the first publish's and the manifest has every file's hash",
    lambda: mfiles(manifest(c2[0]))[BR] != mfiles(M1())[BR] and sorted(mfiles(manifest(c2[0]))) == BUILT)
one("W02-AC-2 updated moves to the time the content changed, seen is this publish's time", lambda: manifest(c2[0])["updated"] == T1 and manifest(c2[0])["seen"] == T1)
one("W02-AC-2 the sent changed file is the built bytes (hash matches)", lambda: hashlib.sha256(files_of(c2[0])[BR]["content"].encode("utf-8")).hexdigest() == mfiles(manifest(c2[0]))[BR])

# ---- W02-AC-3: a due keepalive
rc, o, e, c = pub(T1 + 899)
one("W02-AC-3 keepalive not yet due (899 s) with nothing changed: no gh call", lambda: rc == 0 and c == [])
T2 = T1 + 900
rc, o, e, c3 = pub(T2)
one("W02-AC-3 a publish 900 s after the last with nothing changed makes one call", lambda: rc == 0 and len(c3) == 1)
one("W02-AC-3 the keepalive sends only manifest.json", lambda: list(files_of(c3[0])) == ["manifest.json"])
one("W02-AC-3 the keepalive manifest has a new seen and an unchanged updated", lambda: manifest(c3[0])["seen"] == T2 and manifest(c3[0])["updated"] == T1)
one("W02-AC-3 the keepalive manifest still lists every file's hash", lambda: mfiles(manifest(c3[0])) == mfiles(manifest(c2[0])))
rc, o, e, c = pub(T2 + 10)
one("W02-AC-3 after a keepalive the clock restarts: no call 10 s later", lambda: rc == 0 and c == [])

# ---- W02-AC-2: a repository removed from the list, restored, then made private
shutil_repos = open(tmp + "/pub-repos").read()
open(tmp + "/pub-repos", "w").write("\n".join(l for l in shutil_repos.split("\n") if "bravo" not in l) + "\n")
T3 = T2 + 100
rc, o, e, c4 = pub(T3)
one("W02-AC-2 a repository removed from the list: one call", lambda: rc == 0 and len(c4) == 1)
one("W02-AC-2 the removed repository's file is null in that PATCH", lambda: BR in files_of(c4[0]) and files_of(c4[0])[BR] is None)
one("W02-AC-2 the PATCH sends the manifest, not the unchanged repository file", lambda: "manifest.json" in files_of(c4[0]) and AL not in files_of(c4[0]))
one("W02-AC-2 the manifest no longer lists the removed repository's file", lambda: BR not in mfiles(manifest(c4[0])) and AL in mfiles(manifest(c4[0])))
open(tmp + "/pub-repos", "w").write(shutil_repos)
T4 = T3 + 100
rc, o, e, c5 = pub(T4)
one("W02-AC-2 the repository back in the list is sent again, with its content", lambda: rc == 0 and len(c5) == 1 and isinstance(files_of(c5[0])[BR], dict))
open(tmp + "/data/state/bravo/visibility", "w").write("private\n")
T5 = T4 + 100
rc, o, e, c6 = pub(T5)
one("W02-AC-2 a repository made private: its file is null in the next PATCH", lambda: rc == 0 and len(c6) == 1 and BR in files_of(c6[0]) and files_of(c6[0])[BR] is None)
one("W02-AC-2 a repository made private is not in the manifest", lambda: BR not in mfiles(manifest(c6[0])))
one("W02-AC-6 the private repository, the one without record and the one marked private are in no PATCH",
    lambda: all(not re.search(r"hidden|novis", json.dumps(c["body"])) for c in all_calls if c["body"]) and
    all(set(files_of(c)) <= set(BUILT + ["manifest.json"]) for c in all_calls if c["body"]))
open(tmp + "/data/state/bravo/visibility", "w").write("public\n")

# ---- W02-AC-4: each error answer and a failed call
T = T5 + 100
k = 10
for code in ("404", "422", "403", "500", "fail"):
    k += 1; bump(k)
    before = pj()
    answer(code)
    rc, o, e, ce = pub(T)
    lines = [l for l in e.split("\n") if l.strip()]
    tag = "W02-AC-4 answer %s" % code
    one(tag + ": exit 1", lambda: rc == 1)
    one(tag + ": one gh call was made for the change", lambda: len(ce) == 1 and ce[0]["body"] is not None)
    one(tag + ": exactly one stderr line", lambda: len(lines) == 1)
    if code == "404":
        one(tag + ": the line is 'gist <ID> not found or not writable with this token'", lambda: lines[0].strip().endswith("gist %s not found or not writable with this token" % gid))
    elif code != "fail":
        one(tag + ": the line names the status", lambda: code in lines[0])
    one(tag + ": no response body in stdout or stderr", lambda: "RESPONSEBODYMARK" not in o + e and "Validation Failed" not in o + e)
    if code == "404":
        one(tag + ": the line names the status (404)", lambda: "404" in lines[0])
    if code != "fail":
        one(tag + ": the line is '... publish failed (<status>)' with the HTTP code in the parentheses", lambda: re.search(r"publish failed \([^)]*" + code + r"[^)]*\)", lines[0]) is not None)
    else:
        one(tag + ": the line has 'publish failed (' with something in the parentheses", lambda: re.search(r"publish failed \([^)]+\)", lines[0]) is not None)
    one(tag + ": published.json is byte-identical", lambda: pj() == before)
    answer("200")
    rc2, o2, e2, cn = pub(T + 100)
    one(tag + ": the next run sends the same change", lambda: rc2 == 0 and len(cn) == 1 and
        {f: v for f, v in files_of(cn[0]).items() if f != "manifest.json"} == {f: v for f, v in files_of(ce[0]).items() if f != "manifest.json"})
    one(tag + ": the next run's PATCH is for the change (bravo file), not a bare keepalive", lambda: BR in files_of(cn[0]))
    T += 200
one("W02-AC-4 no call ever was a POST, and every call was to gists/<ID>",
    lambda: len(all_calls) > 10 and all("POST" not in c["args"] and any(a.lstrip("/").endswith("gists/" + gid) for a in c["args"]) for c in all_calls))

# ---- W02-AC-3: --keepalive 0 turns the keepalive off
T += 100000
rc, o, e, c = pub(T, ["--keepalive", "0"])
one("W02-AC-3 --keepalive 0, nothing changed, long after the last publish: no gh call, exit 0", lambda: rc == 0 and c == [])
k += 1; bump(k)
rc, o, e, c = pub(T + 100, ["--keepalive", "0"])
one("W02-AC-3 --keepalive 0: a change past --min-interval is still sent", lambda: rc == 0 and len(c) == 1)
k += 1; bump(k)
rc, o, e, c = pub(T + 105, ["--keepalive", "0"])
one("W02-AC-3 --keepalive 0: a changed file within --min-interval sends nothing", lambda: rc == 0 and c == [])
T += 100000

# ---- W02-AC-3: a held lock; two publishes started at once
os.makedirs(root + "/site", exist_ok=True)
lk = open(root + "/site/lock", "a")
fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
k += 1; bump(k)
t0 = time.time()
rc, o, e, c = pub(T)
one("W02-AC-3 with the lock held by another process the publish does nothing and exits 0, without waiting", lambda: rc == 0 and c == [] and time.time() - t0 < 30)
fcntl.flock(lk, fcntl.LOCK_UN); lk.close()
open(ghd + "/delay", "w").close()
ps = [subprocess.Popen(pub_args(T + 100), cwd=tmp + "/cwd", env=env(), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
res2 = [(p.communicate(timeout=60), p.returncode) for p in ps]
for (o_, e_), _ in res2: outputs.append(o_.decode("utf-8", "replace") + e_.decode("utf-8", "replace"))
cc = new_calls()
os.remove(ghd + "/delay")
one("W02-AC-3 of two publishes started at once exactly one makes a request", lambda: len(cc) == 1)
one("W02-AC-3 the one that lost the lock exits 0 too", lambda: [r for _, r in res2] == [0, 0])
one("W02-AC-3 the lock file is $NOODLEBOT_DATA/site/lock", lambda: os.path.exists(root + "/site/lock"))

# ---- W02-AC-5 (site.py part): the token is in no argument, no output, no file under the runtime root
one("W02-AC-5 the fake gh saw GH_TOKEN equal to the token in every call", lambda: len(all_calls) > 10 and all(c["tok"] == "ok" for c in all_calls))
one("W02-AC-5 the token is in no gh argument", lambda: all(tok not in "\n".join(c["args"]) for c in all_calls) and bool(all_calls))
one("W02-AC-5 the token is in no request body", lambda: all(tok not in json.dumps(c["body"]) for c in all_calls if c["body"]) and bool(all_calls))
one("W02-AC-5 the token is in no stdout or stderr of any publish", lambda: bool(outputs) and all(tok not in x for x in outputs))
def under_root():
    n = 0
    for d, _, fs in os.walk(root):
        for f in fs:
            try: b = open(os.path.join(d, f), "rb").read()
            except OSError: continue
            n += 1
            if tok.encode() in b or tok[4:].encode() in b: return False
    return n > 0 and os.path.exists(root + "/site/published.json")
one("W02-AC-5 the token is in no file under the runtime root (published.json and site/out included)", under_root)
sys.exit(1 if fails else 0)
EOF
python3 -I "$res/pub.py" "$src" "$tmp" "$root" "$HOME" "$PT" "$GID" >"$res/pub.out" 2>&1
prc=$?
cat "$res/pub.out"
n=$(grep -c '^FAIL' "$res/pub.out")
if [ "$prc" -gt 1 ]; then fail "W02 the publish check harness itself failed (rc $prc)"; fi
fails=$((fails + n))
[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
