#!/bin/sh
# D08-AC-1: .github/workflows/test.yml runs exactly one `make test` step per event (pull_request,
# push), with the enforcing env on pull requests and without TEST_BUDGET_ENFORCE=1 on push; every
# make test step's `if:` is one this test can read; the triggers are still pull_request and push to main.
#   sh scheduler/runtests-d08.test.sh   (make test)
# D08_WORKFLOW overrides the workflow file (for trying the parser on a scratch copy).
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
wf=${D08_WORKFLOW:-$src/../.github/workflows/test.yml}
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

if ! python3 -c 'import yaml' 2>/dev/null; then
	fail "D08-AC-1: python3 with PyYAML is available"
	echo "FAIL: D08-AC-1: nothing else can be checked without PyYAML"
	exit 1
fi
pass "D08-AC-1: python3 with PyYAML is available"

cat >"$tmp/check.py" <<'EOT'
import re, sys, yaml

def out(ok, name):
    print(("PASS: " if ok else "FAIL: ") + "D08-AC-1: " + name)

try:
    with open(sys.argv[1]) as f:
        doc = yaml.safe_load(f)
    assert isinstance(doc, dict)
except Exception as e:
    out(False, "test.yml parses as YAML (%s)" % e)
    sys.exit(0)
out(True, "test.yml parses as YAML")

on = doc.get("on", doc.get(True))
if isinstance(on, str):
    on = {on: None}
elif isinstance(on, list):
    on = {k: None for k in on}
elif not isinstance(on, dict):
    on = {}
out("pull_request" in on, "triggered by pull_request")
push = on.get("push")
br = push.get("branches") if isinstance(push, dict) else None
if isinstance(br, str):
    br = [br]
out(isinstance(br, list) and "main" in br, "triggered by push to main")

COND = re.compile(r"""^\s*(?:\$\{\{\s*)?github\.event_name\s*==\s*(['"])(\w+)\1\s*(?:\}\})?\s*$""")
steps = []
for job in (doc.get("jobs") or {}).values():
    steps += (job or {}).get("steps") or []
mt = [s for s in steps if isinstance(s, dict) and re.search(r"\bmake\s+test\b", str(s.get("run", "")))]

runs = {"pull_request": [], "push": []}
for i, s in enumerate(mt):
    label = s.get("name", "step %d" % i)
    if "if" not in s:
        for ev in runs: runs[ev].append(s)
        out(True, "make test step '%s' has no if (both events)" % label)
        continue
    m = COND.match(str(s["if"]))
    if m is None:
        out(False, "make test step '%s' has a readable if: (got %r)" % (label, s["if"]))
        continue
    out(True, "make test step '%s' has a readable if:" % label)
    if m.group(2) in runs:
        runs[m.group(2)].append(s)

want = {
    "pull_request": {"TEST_BUDGET_ENFORCE": "1", "TEST_FILE_BUDGET": "60", "TEST_BUDGET": "360", "SITE_TESTS": "required"},
    "push": {"SITE_TESTS": "required", "TEST_FILE_BUDGET": "60", "TEST_BUDGET": "360"},
}
for ev in ("pull_request", "push"):
    ss = runs[ev]
    out(len(ss) == 1, "%s: exactly one make test step (found %d)" % (ev, len(ss)))
    if len(ss) != 1:
        continue
    env = ss[0].get("env") or {}
    env = {str(k): str(v) for k, v in env.items()}
    for k, v in want[ev].items():
        out(env.get(k) == v, "%s: %s=%s (got %r)" % (ev, k, v, env.get(k)))
    if ev == "push":
        out(env.get("TEST_BUDGET_ENFORCE") != "1", "push: TEST_BUDGET_ENFORCE is not 1 (got %r)" % env.get("TEST_BUDGET_ENFORCE"))
EOT
python3 -I "$tmp/check.py" "$wf" >"$tmp/out" 2>"$tmp/err"
rc=$?
cat "$tmp/out"
if [ "$rc" -ne 0 ]; then
	cat "$tmp/err"
	fail "D08-AC-1: the checker ran to its end (exit $rc)"
fi
n=$(grep -c '^FAIL:' "$tmp/out")
fails=$((fails + n))
[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all D08 checks passed"
