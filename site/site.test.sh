#!/bin/sh
# Test of the status site's front end (W03 site-front):
#   - .github/workflows/pages.yml and the SITE_TESTS=required line of test.yml, checked with Python + PyYAML;
#   - the node:test files site/test/*.test.mjs (the poller, the page, the views), run when `node` is installed.
# Without node: prints "site tests skipped: node not installed" and exits 0, or exits 1 when SITE_TESTS=required
# (test.yml sets it, so CI always runs the front-end tests).
#   sh site/site.test.sh   (make test)
#
# The node tests get their data from the fixture this script builds: a runtime root made from
# scheduler/testdata/site (alpha, bravo), with the hostile texts `<script>alert(1)</script>` and `"` planted in a
# node's question and failure, an event, a triage question and a PR branch, built and published by
# scheduler/site.py (publish, with a fake gh, so the manifest is the one W02 writes). It is handed over as
# $SITE_FIXTURE: gist.json (the answer of GET /gists/<id>), files/<name>, hostile.json. See test/helper.mjs.
# Each node test's result becomes one PASS:/FAIL: line named after its criterion (W03-AC-N ...).
set -u
case $0 in */*) d=${0%/*} ;; *) d=. ;; esac
src=$(cd "$d" && pwd -P)
repo=${src%/*}
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# node_gate: 0 when node is installed; else prints the skip line and gives 1, or 2 under SITE_TESTS=required.
node_gate() {
	command -v node >/dev/null 2>&1 && return 0
	echo "site tests skipped: node not installed"
	[ "${SITE_TESTS:-}" = required ] && return 2
	return 1
}
# nested run (the self-check below): only the gate, so that a PATH without node can be tried.
if [ "${SITE_TEST_GATE_ONLY:-}" = 1 ]; then
	node_gate
	[ $? -ne 2 ] || exit 1
	exit 0
fi

tmp=$(mktemp -d)
cleanup() { chmod -R u+rwX "$tmp" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

# ---- W03-AC-6: the skip / required behaviour of this script, with a PATH that holds no node
mkdir -p "$tmp/nonode"
o=$(env -u SITE_TESTS PATH=$tmp/nonode SITE_TEST_GATE_ONLY=1 /bin/sh "$src/site.test.sh" 2>&1 </dev/null); rc=$?
if [ $rc -eq 0 ] && [ "$o" = "site tests skipped: node not installed" ]; then
	pass "W03-AC-6 without node and without SITE_TESTS the script prints the skip line and exits 0"
else
	fail "W03-AC-6 without node and without SITE_TESTS the script prints the skip line and exits 0 (rc=$rc, output: $o)"
fi
o=$(env PATH=$tmp/nonode SITE_TESTS=required SITE_TEST_GATE_ONLY=1 /bin/sh "$src/site.test.sh" 2>&1 </dev/null); rc=$?
if [ $rc -eq 1 ]; then
	pass "W03-AC-6 without node and with SITE_TESTS=required the script exits 1"
else
	fail "W03-AC-6 without node and with SITE_TESTS=required the script exits 1 (rc=$rc)"
fi

# ---- W03-AC-6: pages.yml and test.yml
cat >"$tmp/yml.py" <<'PY'
import json, os, re, shutil, subprocess, sys, tempfile
import yaml
repo, tmp = sys.argv[1:3]
fails = 0
def check(name, fn):
    global fails
    try:
        ok, why = bool(fn()), ""
    except Exception as e:  # a missing file or key is a failed check, never a crash
        ok, why = False, " (%s: %s)" % (type(e).__name__, str(e)[:150])
    if ok:
        print("PASS: " + name)
    else:
        fails += 1
        print("FAIL: " + name + why)

def load(p):
    with open(os.path.join(repo, p), encoding="utf-8") as f:
        return yaml.safe_load(f)
def pages(): return load(".github/workflows/pages.yml")
def triggers(w): return w[True] if True in w else w["on"]  # PyYAML reads the key `on` as True
def steps(w):
    out = []
    for j in w["jobs"].values():
        out += j.get("steps", [])
    return out

SHA = "0123456789abcdef0123456789abcdef01234567"
def push_ok():
    t = triggers(pages())
    p = t["push"]
    return (set(t) == {"push", "workflow_dispatch"} and set(p) == {"branches", "paths"} and p["branches"] == ["main"]
            and sorted(p["paths"]) == [".github/workflows/pages.yml", "site/**"])
check("W03-AC-6 pages.yml triggers only on pushes to main changing site/** or itself, and on workflow_dispatch", push_ok)

def perms_ok():
    w = pages()
    want = {"contents": "read", "pages": "write", "id-token": "write"}
    eff = [j.get("permissions", w.get("permissions")) for j in w["jobs"].values()]
    return bool(eff) and all(e == want for e in eff) and w.get("permissions", want) == want
check("W03-AC-6 pages.yml has exactly the permissions contents: read, pages: write, id-token: write", perms_ok)

def conc_ok():
    w = pages()
    c = w.get("concurrency")
    return isinstance(c, (str, dict)) and bool(c if isinstance(c, str) else c.get("group"))
check("W03-AC-6 pages.yml has a concurrency group", conc_ok)

def pinned():
    us = [s["uses"] for s in steps(pages()) if "uses" in s]
    return len(us) >= 2 and all(re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", u) for u in us)
check("W03-AC-6 every uses: in pages.yml is pinned to a 40-character commit SHA", pinned)

def uses_ok():
    us = [s["uses"].split("@")[0] for s in steps(pages()) if "uses" in s]
    return "actions/upload-pages-artifact" in us and "actions/deploy-pages" in us
check("W03-AC-6 pages.yml uploads the Pages artifact (actions/upload-pages-artifact) and deploys it (actions/deploy-pages)", uses_ok)

def expand(text, gist, work):
    text = re.sub(r"\$\{\{\s*vars\.NOODLEBOT_GIST_ID\s*\}\}", gist, text)
    text = re.sub(r"\$\{\{\s*github\.workspace\s*\}\}", work, text)
    return re.sub(r"\$\{\{[^}]*\}\}", "", text)

def tree(work):
    for rel, body in [("site/index.html", "<html></html>"), ("site/app.js", "//"), ("site/poll.js", "//"), ("site/style.css", ""),
                      ("site/site.test.sh", "#!/bin/sh\n"), ("site/test/poll.test.mjs", "//"), ("site/test/helper.mjs", "//")]:
        p = os.path.join(work, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(body)

def run_steps(gist):
    """Runs the run: steps of pages.yml in order in a fresh tree with the variable set to gist; returns
    (work dir, [(rc, output)], upload path)."""
    w = pages()
    work = tempfile.mkdtemp(dir=tmp)
    tree(work)
    res, upload = [], None
    for s in steps(w):
        if "uses" in s and s["uses"].startswith("actions/upload-pages-artifact@"):
            upload = expand(str((s.get("with") or {}).get("path", "_site/")), gist, work)
        if "run" not in s:
            continue
        env = {"PATH": os.environ["PATH"], "HOME": work, "GITHUB_WORKSPACE": work}
        for k, v in (s.get("env") or {}).items():
            env[k] = expand(str(v), gist, work)
        r = subprocess.run(["bash", "-e", "-c", expand(s["run"], gist, work)], cwd=work, env=env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        res.append((r.returncode, r.stdout.decode("utf-8", "replace")))
        if r.returncode != 0:
            break
    return work, res, upload

def config_ok():
    work, res, up = run_steps("abc123def456")
    if not res or any(rc != 0 for rc, _ in res):
        return False
    with open(os.path.join(work, "site/config.json"), encoding="utf-8") as f:
        return json.load(f) == {"gist": "abc123def456"}
check("W03-AC-6 pages.yml writes site/config.json from vars.NOODLEBOT_GIST_ID: {\"gist\": \"<id>\"}", config_ok)

def empty_fails():
    work, res, up = run_steps("")
    return bool(res) and res[-1][0] != 0 and "NOODLEBOT_GIST_ID" in res[-1][1] and not os.path.exists(os.path.join(work, "site/config.json"))
check("W03-AC-6 pages.yml fails with a message naming NOODLEBOT_GIST_ID, and writes no config.json, when the variable is empty", empty_fails)

def artifact_ok():
    work, res, up = run_steps("abc123def456")
    if up is None or not res or any(rc != 0 for rc, _ in res):
        return False
    d = up if os.path.isabs(up) else os.path.join(work, up)
    names = []
    for root, dirs, files in os.walk(d):
        names += [os.path.relpath(os.path.join(root, n), d) for n in dirs + files]
    return (os.path.isfile(os.path.join(d, "index.html")) and os.path.isfile(os.path.join(d, "app.js"))
            and os.path.isfile(os.path.join(d, "config.json"))
            and not any(n == "test" or n.startswith("test/") or n.endswith("site.test.sh") for n in names))
check("W03-AC-6 the Pages artifact holds the page and config.json but no test/ and no site.test.sh", artifact_ok)

def test_yml():
    w = load(".github/workflows/test.yml")
    def req(m): return isinstance(m, dict) and str(m.get("SITE_TESTS")) == "required"
    if req(w.get("env")):
        return True
    for j in w["jobs"].values():
        if req(j.get("env")) or any(req(s.get("env")) or re.search(r"\bSITE_TESTS=required\b", s.get("run", "")) for s in j.get("steps", [])):
            return True
    return False
check("W03-AC-6 test.yml sets SITE_TESTS=required", test_yml)
sys.exit(1 if fails else 0)
PY
if python3 -c 'import yaml' 2>/dev/null; then
	python3 -I "$tmp/yml.py" "$repo" "$tmp" 2>&1 </dev/null | tee "$tmp/yml.out"
	grep -q '^FAIL' "$tmp/yml.out" && fails=$((fails + 1))
else
	fail "W03-AC-6 the workflow checks need python3 with PyYAML"
fi

# ---- the node tests
node_gate
case $? in
0) ;;
1) [ "$fails" -eq 0 ] || exit 1; exit 0 ;;
*) fail "W03-AC-6 node is not installed and SITE_TESTS=required"; exit 1 ;;
esac

# the fixture: a runtime root from scheduler/testdata/site, built and published
fx=$repo/scheduler/testdata/site
root=$tmp/data
HOME=$tmp/home
export HOME GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset NOODLEBOT_DATA NOODLEBOT_VERSION USAGE_7D_MARGIN GH_TOKEN
mkdir -p "$HOME/.config/noodlebot" "$root/state" "$root/repos" "$root/deploy" "$tmp/cwd" "$tmp/ghbin" "$tmp/ghd"
XSS='<script>alert(1)</script>'
Q='"'
mk_clone() {
	o=$tmp/origin-$1
	git init -q -b main "$o"
	mkdir -p "$o/docs" "$o/nodes"
	cp "$fx/$1/graph.yaml" "$o/docs/graph.yaml"
	[ ! -d "$fx/$1/nodes" ] || cp "$fx/$1"/nodes/*.md "$o/nodes/"
	git -C "$o" add -A
	git -C "$o" -c user.name=t -c user.email=t@t commit -q -m init
	git clone -q "$o" "$root/repos/$1" 2>/dev/null
}
mk_clone alpha
mk_clone bravo
sa=$root/state/alpha sb=$root/state/bravo
mkdir -p "$sa/node" "$sa/issue" "$sb/node"
echo public >"$sa/visibility"; echo public >"$sb/visibility"
cp "$fx/alpha/graph.yaml" "$sa/graph.yaml"; cp "$fx/bravo/graph.yaml" "$sb/graph.yaml"
printf '41 node/M01-merged-thing\n' >"$sa/merged-prs.tsv"; echo 41 >"$sa/merged-prs.txt"
printf '51 spec/new-thing 0123abc true MERGEABLE\n52 node/P01-%s 4567def false CONFLICTING\n' "$XSS$Q" >"$sa/open-prs.tsv"
cut -d' ' -f2 "$sa/open-prs.tsv" >"$sa/open-prs.txt"
printf 'M01 merged-thing: the old one (#41)\n' >"$sa/subjects.txt"
: >"$sb/merged-prs.tsv"; : >"$sb/merged-prs.txt"; : >"$sb/open-prs.tsv"; : >"$sb/open-prs.txt"; : >"$sb/subjects.txt"
echo v1.0-7-gabc1234 >"$sb/version"
echo 0123456789ab >"$root/deploy/previous"; printf '0badc0de1234\n' >"$root/deploy/rejected"
mark() { mkdir -p "$sa/node/$1"; [ -z "${3:-}" ] || printf '%s\n' "$3" >"$sa/node/$1/$2"; }
mark M01 starts; echo 1 >"$sa/node/M01/starts"
mark F01 FAILED "gave up: $XSS and $Q"; echo 2 >"$sa/node/F01/starts"
mark Q01 QUESTION.md "Is $XSS ok? say $Q yes $Q"; echo "12 home issue" >"$sa/node/Q01/issue"; echo 1 >"$sa/node/Q01/starts"
mark A01 QUESTION.md "Answered?"; mark A01 ANSWER.md "yes"
mark S01 WAITING-PR 51
mark P01 starts
mkdir -p "$sa/issue/23" "$sa/issue/24"
printf '%s\n' "Triage asks $XSS $Q" >"$sa/issue/23/QUESTION.md"
printf 'q\n' >"$sa/issue/24/QUESTION.md"; printf 'a\n' >"$sa/issue/24/ANSWER.md"
printf '2026-11-01T10:00:01Z node started\n2026-11-01T10:00:02Z event with %s and a %s quote\n2026-11-01T10:00:03Z deployed c1..d1 (version v0.1)\n2026-11-01T10:00:04Z not deployed: make test failed on d2\n' "$XSS" "$Q" >"$sa/status.log"
printf '2026-11-01T10:01:00Z bravo newest event\n2026-11-01T10:00:30Z bravo older event\n' >"$sb/status.log"
python3 -I - "$sa/../usage.json" <<'PY'
import json, sys
json.dump({"updated": 1700000950,
           "windows": {"five_hour": {"resetsAt": 1700005000, "utilization": 0.62, "status": "allowed"},
                       "seven_day": {"resetsAt": 1700400000, "utilization": 0.31, "status": "allowed_warning"}},
           "samples5h": [[1699990000 + 60 * i, round(i / 200, 3), 1700005000] for i in range(100)]}, open(sys.argv[1], "w"))
PY
cp "$fx/repos" "$tmp/repos.full"
printf 'acme/alpha\nacme/bravo\n' >"$tmp/repos"

# publish with a fake gh that keeps the --input body: that body is the gist's files map plus manifest.json
cat >"$tmp/ghbin/gh" <<'FAKE'
#!/bin/sh
prev=
for a in "$@"; do
	[ "$prev" = --input ] && cp "$a" "$GHD/body.json"
	prev=$a
done
echo '{"id":"x","files":{}}'
FAKE
chmod +x "$tmp/ghbin/gh"
HOLD='hold: 5-hour window projected 95% before the reset'
(cd "$tmp/cwd" && GHD=$tmp/ghd GH_TOKEN=fake PATH=$tmp/ghbin:$PATH python3 -I "$repo/scheduler/site.py" publish \
	--data-root "$root" --repos "$tmp/repos" --gist 0123abcd0123abcd --throttle "$HOLD" --now 1700001000 \
	>"$tmp/publish.log" 2>&1 </dev/null)
fixdir=$tmp/fixture
mkdir -p "$fixdir/files"
if python3 -I - "$tmp/ghd/body.json" "$fixdir" "$XSS" "$Q" <<'PY'
import json, sys
body, out, xss, q = sys.argv[1:5]
files = json.load(open(body))["files"]
gist = {"id": "0123abcd0123abcd", "files": {}}
for n, f in files.items():
    c = f["content"]
    gist["files"][n] = {"filename": n, "type": "application/json", "size": len(c.encode()), "truncated": False,
                        "raw_url": "https://gist.githubusercontent.com/raw/0123abcd/" + n, "content": c}
    open("%s/files/%s" % (out, n), "w", encoding="utf-8").write(c)
json.dump(gist, open(out + "/gist.json", "w"), ensure_ascii=False)
where = [n for n, f in files.items() if xss in f["content"]]
json.dump({"script": xss, "quote": q, "where": where}, open(out + "/hostile.json", "w"))
sys.exit(0 if "manifest.json" in files and where else 1)
PY
then
	pass "W03 fixture: site.py publish built the gist files with a manifest and the hostile text planted"
else
	fail "W03 fixture: site.py publish built the gist files with a manifest and the hostile text planted ($(head -c 300 "$tmp/publish.log"))"
	exit 1
fi

# run the node tests; each result is a PASS:/FAIL: line
cd "$src" || exit 1
set -- test/*.test.mjs
SITE_FIXTURE=$fixdir node --test --test-reporter=tap "$@" >"$tmp/tap.out" 2>"$tmp/tap.err" </dev/null
nrc=$?
awk '
	/^(not )?ok [0-9]+ - / {
		if (pending != "") print "FAIL: " pending
		pending = ""
		line = $0; fail = (line ~ /^not ok/)
		sub(/^(not )?ok [0-9]+ - /, "", line); sub(/ *# (SKIP|TODO).*$/, "", line)
		if (fail) pending = line; else print "PASS: " line
		next
	}
	pending != "" && /^  error: / { l = $0; sub(/^  error: /, "", l); gsub(/^.|.$/, "", l); print "FAIL: " pending " (" substr(l, 1, 160) ")"; pending = ""; next }
	pending != "" && /^  failureType: / { next }
	END { if (pending != "") print "FAIL: " pending }
' "$tmp/tap.out" >"$tmp/results"
cat "$tmp/results"
fails=$((fails + $(grep -c '^FAIL' "$tmp/results")))
if ! grep -q '^PASS\|^FAIL' "$tmp/results"; then
	fail "W03 the node test run produced no result (exit $nrc): $(head -c 300 "$tmp/tap.err")"
elif [ "$nrc" -ne 0 ] && ! grep -q '^FAIL' "$tmp/results"; then
	fail "W03 the node test run exited $nrc without a failed test: $(head -c 300 "$tmp/tap.err")"
fi
[ "$fails" -eq 0 ]
