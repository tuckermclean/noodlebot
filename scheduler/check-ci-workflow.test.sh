#!/bin/sh
# D10-AC-1, D10-AC-2: scheduler/check-ci-workflow.py reports PROBLEMS 0 (exit 0) on
# .github/workflows/test.yml and on a passing fixture, and exits 1 with a problem line naming the job,
# the step where there is one, and what is wrong, on each of 15 failing fixtures. Every failing fixture
# is the passing one with exactly one change. The fixtures are written into a scratch folder at run time.
#   sh scheduler/check-ci-workflow.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$src/.." && pwd -P)
chk=$src/check-ci-workflow.py
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

if ! python3 -c 'import yaml' 2>/dev/null; then
	fail "D10-AC-1: python3 with PyYAML is available"
	echo "FAIL: D10-AC-2: nothing else can be checked without PyYAML"
	exit 1
fi
pass "D10-AC-1: python3 with PyYAML is available"

# mk <file>: the passing fixture, with the slots below (set by the caller) filled in.
mk() {
	cat >"$1" <<EOF
name: ci
$ON_KEY:
$ON_PR
$ON_PUSH
env:
  SITE_TESTS: required
$WF_ENV
jobs:
  unit:
    runs-on: ubuntu-24.04
    continue-on-error: false
$JOB_EXTRA
$JOB_ENV
    steps:
      - uses: actions/checkout@v1
      - name: make test (pull_request)
        if: github.event_name == 'pull_request'
        continue-on-error: false
        run: make test
        env:
          TEST_BUDGET_ENFORCE: $PR_ENFORCE
      - name: make test (push)
        if: $PUSH_IF
        continue-on-error: $PUSH_COE
        run: $PUSH_RUN
$PUSH_ENV
$STEPS_EXTRA
EOF
}

defaults() {
	ON_KEY='"on"'
	ON_PR='  pull_request:'
	ON_PUSH="  push:
    branches: [main]"
	WF_ENV=''
	JOB_EXTRA=''
	JOB_ENV="    env:
      TEST_FILE_BUDGET: 60
      TEST_BUDGET: 360
      GH_TOKEN: \${{ secrets.GITHUB_TOKEN }}"
	PR_ENFORCE=1
	PUSH_IF="github.event_name == 'push'"
	PUSH_COE=false
	PUSH_RUN='make test'
	PUSH_ENV=''
	STEPS_EXTRA=''
}

# run <file>: output in $tmp/out, status in $rc. Python is run isolated, as the node spec says.
run() {
	python3 -I "$chk" "$1" >"$tmp/out" 2>&1
	rc=$?
}

# ok <name> <file>
ok() {
	run "$2"
	if [ "$rc" -eq 0 ] && grep -qx 'PROBLEMS 0' "$tmp/out"; then
		pass "D10-AC-1: $1: PROBLEMS 0, exit 0"
	else
		fail "D10-AC-1: $1: expected PROBLEMS 0 and exit 0, got exit $rc: $(head -c 300 "$tmp/out" | tr '\n' '|')"
	fi
}

# bad <name> <file> <job|-> <step|-> <keyword-regex>
# exit 1, `PROBLEMS <n>` with n>0, and one problem line holding the job id, the step (when given) and the keyword.
bad() {
	run "$2"
	if [ "$rc" -ne 1 ]; then
		fail "D10-AC-2: $1: expected exit 1, got $rc: $(head -c 300 "$tmp/out" | tr '\n' '|')"
		return
	fi
	if ! grep -Eq '^PROBLEMS [1-9][0-9]*$' "$tmp/out"; then
		fail "D10-AC-2: $1: no 'PROBLEMS <n>' line with n > 0"
		return
	fi
	grep -v '^PROBLEMS ' "$tmp/out" >"$tmp/lines"
	if [ "$3" != - ]; then grep -iF -e "$3" "$tmp/lines" >"$tmp/l2"; else cp "$tmp/lines" "$tmp/l2"; fi
	if [ "$4" != - ]; then grep -iF -e "$4" "$tmp/l2" >"$tmp/l3"; else cp "$tmp/l2" "$tmp/l3"; fi
	if grep -Eiq -e "$5" "$tmp/l3"; then
		pass "D10-AC-2: $1: exit 1, a problem line names job '$3', step '$4', $5"
	else
		fail "D10-AC-2: $1: no problem line with job '$3', step '$4' and /$5/: $(head -c 300 "$tmp/lines" | tr '\n' '|')"
	fi
}

# passing cases
ok "test.yml" "$root/.github/workflows/test.yml"
defaults
WF_ENV=''
mk "$tmp/pass.yml"
ok "three-level fixture" "$tmp/pass.yml"

# failing cases, each one change from the passing fixture
defaults; JOB_EXTRA="    if: github.ref == 'refs/heads/main'"; mk "$tmp/f01.yml"
bad "job-level if" "$tmp/f01.yml" unit - 'if'

defaults; sed 's/^    continue-on-error: false$/    continue-on-error: true/' "$tmp/pass.yml" >"$tmp/f02.yml"
bad "job continue-on-error: true" "$tmp/f02.yml" unit - 'continue-on-error'

defaults; PUSH_COE=true; mk "$tmp/f03.yml"
bad "push step continue-on-error: true" "$tmp/f03.yml" unit '(push)' 'continue-on-error'

defaults; PUSH_RUN='make test || true'; mk "$tmp/f04.yml"
bad "run: make test || true" "$tmp/f04.yml" unit '(push)' 'run'

defaults; PUSH_RUN='sh scheduler/runtests.sh'; mk "$tmp/f05.yml"
bad "run: sh scheduler/runtests.sh" "$tmp/f05.yml" unit '(push)' 'run'

defaults; WF_ENV='  TEST_BUDGET_ENFORCE: 1'; mk "$tmp/f06.yml"
bad "TEST_BUDGET_ENFORCE: 1 in workflow env" "$tmp/f06.yml" unit '(push)' 'TEST_BUDGET_ENFORCE'

defaults; JOB_ENV="    env:
      TEST_FILE_BUDGET: 60
      TEST_BUDGET: 360
      TEST_BUDGET_ENFORCE: 1
      GH_TOKEN: \${{ secrets.GITHUB_TOKEN }}"; mk "$tmp/f07.yml"
bad "TEST_BUDGET_ENFORCE: 1 in job env" "$tmp/f07.yml" unit '(push)' 'TEST_BUDGET_ENFORCE'

defaults; PR_ENFORCE=0; mk "$tmp/f08.yml"
bad "TEST_BUDGET_ENFORCE: 0 in the pull-request step" "$tmp/f08.yml" unit '(pull_request)' 'TEST_BUDGET_ENFORCE'

defaults; PUSH_IF="contains(github.ref, 'main') && github.event_name == 'push'"; mk "$tmp/f09.yml"
bad "unreadable step if" "$tmp/f09.yml" unit '(push)' 'if'

defaults; JOB_ENV="    env:
      TEST_FILE_BUDGET: \${{ vars.FILE_BUDGET }}
      TEST_BUDGET: 360
      GH_TOKEN: \${{ secrets.GITHUB_TOKEN }}"; mk "$tmp/f10.yml"
bad "TEST_FILE_BUDGET as an expression" "$tmp/f10.yml" unit - 'TEST_FILE_BUDGET'

defaults; JOB_ENV="    env:
      - TEST_FILE_BUDGET=60
      - TEST_BUDGET=360"; mk "$tmp/f11.yml"
bad "job env as a list" "$tmp/f11.yml" unit - 'env'

defaults; JOB_ENV="    env:
      TEST_FILE_BUDGET: 60
      TEST_BUDGET: 600
      GH_TOKEN: \${{ secrets.GITHUB_TOKEN }}"; mk "$tmp/f12.yml"
bad "TEST_BUDGET: 600" "$tmp/f12.yml" unit - 'TEST_BUDGET'

defaults; STEPS_EXTRA="      - name: make test (extra)
        run: make test"; mk "$tmp/f13.yml"
bad "third make test step without if" "$tmp/f13.yml" unit - 'make test|step|one|3'

defaults; ON_PUSH=''; mk "$tmp/f14.yml"
bad "push trigger removed" "$tmp/f14.yml" - - 'push'

defaults; ON_PR=''; mk "$tmp/f15.yml"
bad "pull_request trigger removed" "$tmp/f15.yml" - - 'pull_request'

[ "$fails" -eq 0 ]
