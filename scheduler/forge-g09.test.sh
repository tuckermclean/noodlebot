#!/bin/sh
# G09: ci dispatch and ci logs --attempt (and, in a later slice, ci artifact) on both backends.
#   sh scheduler/forge-g09.test.sh   (make test)
#
#   G09-AC-1  ci dispatch --workflow --ref --input k=v: one dispatch with that ref and those inputs, the new run's id printed
#             (the answer names the run or not), the inputs as exact strings in a JSON body on stdin, a bad or repeated input
#             and a bad --workflow exit 2 / forge.BadValue with no call, a rejected dispatch, a run not found in the bound and
#             two new runs exit 1; forge.CAPABILITIES, `forge.py ops` and the README row
#   G09-AC-2  a dispatch the forge refuses, and a fake forge without ci_dispatch, exit 3 naming ci_dispatch (no call for the latter)
#   G09-AC-5  ci logs --attempt N: that attempt's jobs, each with id, name, conclusion, log and html_url; html_url without
#             --attempt too; a missing attempt exits 1, one below 1 exits 2, a refused listing exits 3 naming ci_logs
# Both backends (the GitHub backend over the gh emulator testdata/forge/fakegh.py, which records each call, and the fake
# forge testdata/forge/fake.py, which records its calls when $FAKE_FORGE_CALLS is set), through the Python interface and the
# CLI. The cases are testdata/forge/g09.py. All scratch files are under $tmp/G09; HOME is scratch: the real token script is
# never run (a counting fake of it is), no GH_TOKEN is set.
#
# What the implementation must follow (the cases read it):
#   - the bound for finding the dispatched run is $FORGE_DISPATCH_WAIT seconds (float, read at each call) and the pause between
#     two listings $FORGE_DISPATCH_POLL seconds (float, read at each call); the GitHub backend's module (forge._load("github"))
#     has the constant DISPATCH_WAIT, 60, once ci_dispatch is reachable (the default of the variable); the cases set the
#     bound to 1 second so the not-found case does not take 60.
#   - the Python interface takes input as a list of "name=value" strings; a malformed one (no "=", empty name) or a name given
#     twice raises forge.BadValue before the backend is called; the CLI's --input is repeated, exit 2.
#   - a run that is not found: ForgeError whose message says the dispatch was accepted and the run not found ("accepted",
#     "not found") and names `ci runs`; two new runs: ForgeError naming both ids; a 404 or 422: ForgeError; a 403:
#     CapabilityOff (ci_dispatch); never a result.
#   - ci logs attempt: int option, below 1 is forge.BadValue; each job of ci logs has html_url (the forge's web page of the job).
#   - the fake forge's ci_dispatch/ci_logs, the fake gh's dispatch and attempt routes and the new fixture files
#     (ci_attempts.json, ci_job_urls.json) are in testdata/forge (world.py documents the new files and forge.json keys).
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
td=$src/testdata/forge
. "$src/testdata/lib/common.sh"
for v in $(env | sed -n 's/^\(NOODLEBOT_FORGE[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done
unset GH_TOKEN USAGE_7D_MARGIN NOODLEBOT_DATA NOODLEBOT_VERSION FAKE_FORGE_CALLS FAKE_GH_DIR FORGE_DISPATCH_WAIT FORGE_DISPATCH_POLL
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
G=$tmp/G09
mkdir -p "$G/home" "$G/w/bin"
export HOME=$G/home XDG_CONFIG_HOME=$G/home GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
W=$G/w
printf '#!/bin/sh\nexec python3 "%s/fakegh.py" "$@"\n' "$td" >"$W/bin/gh"
chmod +x "$W/bin/gh"
# a file an input's value can name with a leading @ (gh api -F would read it)
printf 'secret\n' >"$W/at-file"

python3 -I "$td/g09.py" "$W" >"$G/out" 2>"$G/err"
cat "$G/out"
fails=$((fails + $(grep -c '^FAIL: ' "$G/out")))
grep -q '^DONE$' "$G/out" || { echo "FAIL: G09: the cases did not run to their end: $(tail -n 3 "$G/err" | tr '\n' ' ')"; fails=$((fails + 1)); }
[ "$fails" -eq 0 ] || { echo "forge-g09: $fails check(s) failed"; exit 1; }
echo "forge-g09: all checks passed"
