#!/bin/sh
# D07: deploy.sh deploys a runtime commit after the repository's CI workflow passed it (no make test), then runs a local
# smoke check. Test of scheduler/deploy.sh against a fake remote of the scheduler's own repository (the live checkout is a
# clone), in the style of deploy-d04.test.sh. make test is stubbed by the first commit's Makefile: it appends one line per
# call to $log ("call <sha>"). HOME holds .config/noodlebot/deploy-ci and a fake token script (it prints a recognisable token,
# or fails while $D07/token-fails exists). A fake gh on PATH answers the workflow-runs request from the per-sha fixture
# $D07/runs/<sha> (a GitHub API body; no fixture: no runs), records each call (its arguments and whether GH_TOKEN was the
# token) in $D07/gh.log, and fails while $D07/gh-fails exists. The interface is in out/node/D07/brief.md.
#   sh scheduler/deploy-d07.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
# ok <name> <condition>: PASS when the whole shell condition (a string, evaluated here) succeeds.
ok() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

unset TEST_JOBS TESTS USAGE_7D_MARGIN NOODLEBOT_VERSION GH_TOKEN GITHUB_TOKEN
export HOME=$tmp/home
export NOODLEBOT_DATA=$tmp/data
D07=$tmp/D07; export D07
mkdir -p "$HOME/.config/noodlebot" "$D07/runs" "$D07/bin" "$tmp/scratch"
log=$tmp/make.log
: >"$log"
deploy=$src/deploy.sh
live=$tmp/live
dd=$NOODLEBOT_DATA/deploy
scratchd=$tmp/scratch
cfg=$HOME/.config/noodlebot/deploy-ci
secret=D07-fake-token-SECRET
wf=test.yml

# the fake gh
cat >"$D07/bin/gh" <<'EOT'
#!/bin/sh
sha=$(printf '%s\n' "$*" | grep -Eo '[0-9a-f]{40}' | head -n 1)
if [ "${GH_TOKEN:-}" = "D07-fake-token-SECRET" ]; then t=token; elif [ -n "${GH_TOKEN:-}" ]; then t=other; else t=unset; fi
echo "$* | GH_TOKEN=$t" >>"$D07/gh.log"
if [ -e "$D07/gh-fails" ]; then echo "gh: simulated failure (HTTP 500)" >&2; exit 1; fi
if [ -n "$sha" ] && [ -f "$D07/runs/$sha" ]; then cat "$D07/runs/$sha"; else echo '{"total_count":0,"workflow_runs":[]}'; fi
EOT
chmod +x "$D07/bin/gh"
# the fake token script: called as token <owner/name>
cat >"$HOME/.config/noodlebot/token" <<'EOT'
#!/bin/sh
echo "$*" >>"$D07/token.log"
if [ -e "$D07/token-fails" ]; then echo "token script: simulated failure" >&2; exit 1; fi
echo "D07-fake-token-SECRET"
EOT
chmod +x "$HOME/.config/noodlebot/token"
: >"$D07/gh.log"
PATH=$D07/bin:$PATH; export PATH

git init -q -b main "$tmp/work"
g() { git -C "$tmp/work" -c user.name=t -c user.email=t@t "$@"; }
# mk <label> <path>...: a new commit on the remote's main that appends <label> to each path (creating it).
mk() {
	l=$1; shift
	for p in "$@"; do mkdir -p "$(dirname "$tmp/work/$p")"; echo "$l" >>"$tmp/work/$p"; done
	g add -A && g commit -q -m "$l" && g push -q "$tmp/remote.git" HEAD:main 2>/dev/null
}
head_w() { git -C "$tmp/work" rev-parse HEAD; }
printf 'test:\n\t@sha=$$(git rev-parse HEAD); echo "call $$sha" >>%s\n' "$log" >"$tmp/work/Makefile"
for p in SPEC.md README.md docs/graph.yaml scheduler/x.sh; do
	mkdir -p "$(dirname "$tmp/work/$p")"; echo base >"$tmp/work/$p"
done
g add -A && g commit -q -m c0
g tag v0.1.0
git clone -q --bare "$tmp/work" "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$live"
g remote add origin "$tmp/remote.git" 2>/dev/null

ver() { git -C "$tmp/work" describe --tags --always "$1" 2>/dev/null; }
head_of() { git -C "$live" rev-parse HEAD; }
ncalls() { grep -c '^call ' "$log"; }
callsof() { grep -c "^call $1\$" "$log"; }
ghcalls() { grep -c "$1" "$D07/gh.log"; }
in_rejected() { grep -qx "$1" "$dd/rejected" 2>/dev/null; }
rejsum() { cat "$dd/rejected" 2>/dev/null | cksum; }
nlines() { printf '%s\n' "$1" | grep -c .; }
deployed_line() { echo "deployed $1..$2 (version $(ver "$2"))$3"; }
ci_line() { deployed_line "$1" "$2" " after CI: $wf run $3 passed"; }
cifail_line() { echo "not deployed: $1 (version $(ver "$1")) fails CI: $wf run $2 $3"; }
# depe: a deploy run with the scratch folders under $scratchd; stdout in $o, stderr in $e, status in $dst, seconds in $secs.
depe() {
	t0=$(date +%s)
	TMPDIR=$scratchd sh "$deploy" "$live" >"$tmp/o.out" 2>"$tmp/o.err"; dst=$?
	secs=$(( $(date +%s) - t0 ))
	o=$(cat "$tmp/o.out"); e=$(cat "$tmp/o.err")
	cat "$tmp/o.out" "$tmp/o.err" >>"$D07/all.out"
}
scratch_gone() { [ -z "$(ls -A "$scratchd")" ] && [ "$(git -C "$live" worktree list | wc -l)" = 1 ]; }
# robj <id> <status> <conclusion|null> <created_at> <sha>: one run of the API body; setruns <sha> <run>...: the fixture.
robj() {
	c=$3; [ "$c" = null ] || c="\"$c\""
	printf '{"id": %s, "status": "%s", "conclusion": %s, "created_at": "%s", "head_sha": "%s", "event": "push", "head_branch": "main"}' "$1" "$2" "$c" "$4" "$5"
}
setruns() {
	s=$1; shift; body=; cnt=0
	for r in "$@"; do body=${body:+$body, }$r; cnt=$((cnt + 1)); done
	printf '{"total_count": %s, "workflow_runs": [%s]}\n' "$cnt" "$body" >"$D07/runs/$s"
}
# setrun <sha> <id> <status> <conclusion> [created_at]
setrun() { setruns "$1" "$(robj "$2" "$3" "$4" "${5:-2026-01-01T00:00:05Z}" "$1")"; }
cfg_on() { printf 'acme/widget %s main\n' "$wf" >"$cfg"; }

# D07-AC-1: without the file, the same remote runs the make test stub as D01 says (and gh is not called).
mk r0 scheduler/x.sh
r0=$(head_w); c0=$(git -C "$tmp/work" rev-parse HEAD~1)
rm -f "$cfg"
depe
ok "D07-AC-1 without deploy-ci a runtime commit runs the make test stub and is deployed as before" '[ "$(head_of)" = "$r0" ] && [ "$(callsof "$r0")" = 1 ] && [ "$o" = "$(deployed_line "$c0" "$r0" "")" ] && [ "$(cat "$dd/previous" 2>/dev/null)" = "$c0" ]'
ok "D07-AC-1 without deploy-ci gh and the token script are not called" '[ ! -s "$D07/gh.log" ] && [ ! -e "$D07/token.log" ]'
: >"$cfg"
mk e1 scheduler/e1.sh
e1=$(head_w)
depe
ok "D07-AC-1 an empty deploy-ci is the same as none: make test runs, gh is not called" '[ "$(head_of)" = "$e1" ] && [ "$(callsof "$e1")" = 1 ] && [ ! -s "$D07/gh.log" ]'

# D07-AC-1: a runtime commit whose newest push run succeeded is deployed without make test.
cfg_on
mk a1 scheduler/a.sh
a1=$(head_w); setrun "$a1" 1001 completed success
before=$(head_of); n=$(ncalls)
depe
ok "D07-AC-1 a runtime commit whose run succeeded: the live checkout moves to it" '[ "$(head_of)" = "$a1" ] && [ "$dst" = 0 ]'
ok "D07-AC-1 deploy/previous holds the old HEAD" '[ "$(head_of)" = "$a1" ] && [ "$(cat "$dd/previous" 2>/dev/null)" = "$before" ]'
ok "D07-AC-1 one status line 'deployed <old>..<new> (version <v>) after CI: <workflow> run <id> passed'" '[ "$o" = "$(ci_line "$before" "$a1" 1001)" ]'
ok "D07-AC-1 the make test stub records no call" '[ "$(head_of)" = "$a1" ] && [ "$(ncalls)" = "$n" ]'
ok "D07-AC-1 gh was called with the repository, workflow, branch and sha" 'grep "$a1" "$D07/gh.log" | grep -F "repos/acme/widget/actions/workflows/$wf/runs" | grep -Fq "branch=main" && grep "$a1" "$D07/gh.log" | grep -Fq "head_sha=$a1"'
ok "D07-AC-1 gh was called with a GH_TOKEN (the token script's)" 'grep "$a1" "$D07/gh.log" | grep -Fq "GH_TOKEN=token" && grep -Fqx "acme/widget" "$D07/token.log"'
ok "D07-AC-1 no token appears in the output" '! printf "%s\n%s\n" "$o" "$e" | grep -Fq "$secret"'
# the newest of the runs decides: an older failure and a newer success
mk a2 scheduler/a2.sh
a2=$(head_w)
setruns "$a2" "$(robj 2001 completed failure 2026-01-01T00:00:01Z "$a2")" "$(robj 2002 completed success 2026-01-01T00:00:09Z "$a2")"
before=$(head_of); n=$(ncalls)
depe
ok "D07-AC-1 an older failed run and a newer successful one: the newest decides, deployed (run 2002)" '[ "$(head_of)" = "$a2" ] && [ "$o" = "$(ci_line "$before" "$a2" 2002)" ] && [ "$(ncalls)" = "$n" ]'

# D07-AC-2: a run that failed (and one that was cancelled) is rejected, once, without make test.
mk f1 scheduler/f1.sh
f1=$(head_w); setrun "$f1" 3001 completed failure
before=$(head_of); n=$(ncalls)
depe
ok "D07-AC-2 a run that concluded failure: one 'not deployed: <sha> (version <v>) fails CI: <workflow> run <id> <conclusion>' line" '[ "$o" = "$(cifail_line "$f1" 3001 failure)" ]'
ok "D07-AC-2 the failed commit is not deployed and is in deploy/rejected" '[ "$(head_of)" = "$before" ] && in_rejected "$f1"'
ok "D07-AC-2 no make test call" '[ "$(ncalls)" = "$n" ] && [ "$(head_of)" = "$before" ]'
gc=$(ghcalls "$f1")
depe
ok "D07-AC-2 a second run prints nothing and calls gh for it no more" '[ "$gc" -ge 1 ] && [ -z "$o" ] && [ "$(ghcalls "$f1")" = "$gc" ] && in_rejected "$f1"'
mk f2 scheduler/f2.sh
f2=$(head_w); setrun "$f2" 3002 completed cancelled
depe
ok "D07-AC-2 a run that concluded cancelled: one 'fails CI: ... run <id> cancelled' line, rejected, not deployed" '[ "$o" = "$(cifail_line "$f2" 3002 cancelled)" ] && in_rejected "$f2" && [ "$(head_of)" = "$before" ] && [ "$(ncalls)" = "$n" ]'
gc=$(ghcalls "$f2")
depe
ok "D07-AC-2 the cancelled commit is not asked for again" '[ "$gc" -ge 1 ] && [ -z "$o" ] && [ "$(ghcalls "$f2")" = "$gc" ]'
mk f3 scheduler/f3.sh
f3=$(head_w)
setruns "$f3" "$(robj 3003 completed success 2026-01-01T00:00:01Z "$f3")" "$(robj 3004 completed failure 2026-01-01T00:00:09Z "$f3")"
depe
ok "D07-AC-2 an older success and a newer failure: the newest decides, rejected (run 3004)" '[ "$o" = "$(cifail_line "$f3" 3004 failure)" ] && in_rejected "$f3" && [ "$(head_of)" = "$before" ]'

# D07-AC-3: a run in progress (later queued, later success): waiting, nothing deployed or rejected, exit 2.
mk w1 scheduler/w1.sh
w1=$(head_w); setrun "$w1" 4001 in_progress null
rejs=$(rejsum); n=$(ncalls)
depe
ok "D07-AC-3 a run in progress: exit 2 within 35 s, nothing deployed, nothing rejected, no make test call" '[ "$dst" = 2 ] && [ "$secs" -le 35 ] && [ "$(head_of)" = "$before" ] && [ "$(rejsum)" = "$rejs" ] && [ "$(ncalls)" = "$n" ]'
ok "D07-AC-3 the first wait prints 'waiting for CI: <sha> (version <v>) <workflow>' as the one status line" '[ "$o" = "waiting for CI: $w1 (version $(ver "$w1")) $wf" ]'
ok "D07-AC-3 the first wait also writes the stderr line 'waiting for CI: <sha> <workflow> in_progress'" 'printf "%s\n" "$e" | grep -Fqx "waiting for CI: $w1 $wf in_progress"'
ok "D07-AC-3 the waiting sha is recorded in deploy/waiting" 'grep -Fq "$w1" "$dd/waiting" 2>/dev/null'
depe
ok "D07-AC-3 a later wait prints no status line, only the stderr line, exit 2" '[ "$dst" = 2 ] && [ -z "$o" ] && printf "%s\n" "$e" | grep -Fqx "waiting for CI: $w1 $wf in_progress" && [ "$(head_of)" = "$before" ] && [ "$(rejsum)" = "$rejs" ]'
setrun "$w1" 4001 completed success
depe
ok "D07-AC-3 once the fixture reports success the next run deploys it" '[ "$(head_of)" = "$w1" ] && [ "$o" = "$(ci_line "$before" "$w1" 4001)" ] && [ "$(ncalls)" = "$n" ]'
# no run yet, then queued, then success
before=$(head_of)
mk w2 scheduler/w2.sh
w2=$(head_w)
depe
ok "D07-AC-3 a commit with no run yet: exit 2 within 35 s, nothing deployed or rejected, no make test call" '[ "$dst" = 2 ] && [ "$secs" -le 35 ] && [ "$(head_of)" = "$before" ] && [ "$(rejsum)" = "$rejs" ] && [ "$(ncalls)" = "$n" ]'
ok "D07-AC-3 no run: the status line on the first run, the stderr line '... $wf no run'" '[ "$o" = "waiting for CI: $w2 (version $(ver "$w2")) $wf" ] && printf "%s\n" "$e" | grep -Fqx "waiting for CI: $w2 $wf no run"'
setrun "$w2" 4002 queued null
depe
ok "D07-AC-3 a queued run: stderr line '... queued', no status line (not the first wait)" '[ "$dst" = 2 ] && [ -z "$o" ] && printf "%s\n" "$e" | grep -Fqx "waiting for CI: $w2 $wf queued" && [ "$(head_of)" = "$before" ]'
setrun "$w2" 4002 completed success
depe
ok "D07-AC-3 a commit that had no run is deployed once its run succeeded" '[ "$(head_of)" = "$w2" ] && [ "$o" = "$(ci_line "$before" "$w2" 4002)" ] && [ "$(ncalls)" = "$n" ]'

# D07-AC-4: the smoke check rejects a shell syntax error and a Python syntax error in a CI-passed commit.
before=$(head_of)
mk b1 scheduler/bad.sh
sed -i 's/^b1$/if then ) fi/' "$tmp/work/scheduler/bad.sh"; g add -A && g commit -q --amend -m b1 && g push -q -f "$tmp/remote.git" HEAD:main 2>/dev/null
b1=$(head_w); setrun "$b1" 5001 completed success
depe
smoke_ok() { [ "$(nlines "$o")" = 1 ] && printf '%s\n' "$o" | grep -Eq "^not deployed: $1 \(version $(ver "$1")\) fails the smoke check: (\./)?$2\$"; }
ok "D07-AC-4 a shell syntax error in scheduler/*.sh: 'not deployed: <sha> (version <v>) fails the smoke check: <file>'" 'smoke_ok "$b1" scheduler/bad.sh'
ok "D07-AC-4 the shell syntax error is rejected (deploy/rejected), the live checkout stays, no make test" '[ "$(head_of)" = "$before" ] && in_rejected "$b1" && [ "$(ncalls)" = "$n" ]'
ok "D07-AC-4 the smoke check leaves no scratch worktree and the live checkout no __pycache__" 'scratch_gone && [ -z "$(find "$live" -name __pycache__)" ]'
printf 'ok\n' >"$tmp/work/scheduler/bad.sh"
mk b2 scheduler/bad.py
printf 'def (:\n' >"$tmp/work/scheduler/bad.py"; g add -A && g commit -q --amend -m b2 && g push -q -f "$tmp/remote.git" HEAD:main 2>/dev/null
b2=$(head_w); setrun "$b2" 5002 completed success
depe
ok "D07-AC-4 a Python syntax error in scheduler/*.py: 'not deployed: <sha> (version <v>) fails the smoke check: <file>'" 'smoke_ok "$b2" scheduler/bad.py'
ok "D07-AC-4 the Python syntax error is rejected, the live checkout stays, no make test" '[ "$(head_of)" = "$before" ] && in_rejected "$b2" && [ "$(ncalls)" = "$n" ]'
ok "D07-AC-4 no scratch worktree is left, the live checkout has no __pycache__" 'scratch_gone && [ -z "$(find "$live" -name __pycache__)" ]'
rm -f "$tmp/work/scheduler/bad.py"
mk c1 scheduler/ok.sh
c1=$(head_w); setrun "$c1" 5003 completed success
depe
ok "D07-AC-4 a clean CI-passed commit is deployed after CI (the smoke check passed)" '[ "$(head_of)" = "$c1" ] && [ "$o" = "$(ci_line "$before" "$c1" 5003)" ] && [ "$(ncalls)" = "$n" ]'
ok "D07-AC-4 a clean commit's smoke check leaves no scratch worktree behind and the live checkout no __pycache__" 'scratch_gone && [ -z "$(find "$live" -name __pycache__)" ]'

# D07-AC-5: a failing gh and a failing token script wait (exit 2), leave things as they were, and print no token.
before=$(head_of)
mk g1 scheduler/g1.sh
g1=$(head_w); setrun "$g1" 6001 completed success
rejs=$(rejsum); n=$(ncalls)
: >"$D07/gh-fails"
depe
ok "D07-AC-5 a failing gh: exit 2, the live checkout and deploy/rejected as they were, no make test" '[ "$dst" = 2 ] && [ "$(head_of)" = "$before" ] && [ "$(rejsum)" = "$rejs" ] && [ "$(ncalls)" = "$n" ]'
ok "D07-AC-5 a failing gh: a stderr line names the failure, no status line" '[ -z "$o" ] && printf "%s\n" "$e" | grep -i "gh" | grep -q .'
ok "D07-AC-5 a failing gh: no token is printed" '! printf "%s\n%s\n" "$o" "$e" | grep -Fq "$secret"'
rm -f "$D07/gh-fails"
: >"$D07/token-fails"
depe
ok "D07-AC-5 a failing token script: exit 2, the live checkout and deploy/rejected as they were, no make test" '[ "$dst" = 2 ] && [ "$(head_of)" = "$before" ] && [ "$(rejsum)" = "$rejs" ] && [ "$(ncalls)" = "$n" ]'
ok "D07-AC-5 a failing token script: a stderr line names the failure, no status line" '[ -z "$o" ] && printf "%s\n" "$e" | grep -i "token" | grep -q .'
ok "D07-AC-5 a failing token script: no token is printed" '! printf "%s\n%s\n" "$o" "$e" | grep -Fq "$secret"'
rm -f "$D07/token-fails"
depe
ok "D07-AC-5 once gh and the token script work again the commit is deployed" '[ "$(head_of)" = "$g1" ] && [ "$o" = "$(ci_line "$before" "$g1" 6001)" ]'
# a sha rejected for CI, put back by deploy/retry with its run now success, is deployed on the next run
before=$(head_of)
mk t1 scheduler/t1.sh
t1=$(head_w); setrun "$t1" 7001 completed failure 2026-01-01T00:00:01Z
depe
ok "D07-AC-5 setup: a commit rejected for CI" '[ "$o" = "$(cifail_line "$t1" 7001 failure)" ] && in_rejected "$t1"'
setruns "$t1" "$(robj 7001 completed failure 2026-01-01T00:00:01Z "$t1")" "$(robj 7002 completed success 2026-01-01T00:00:09Z "$t1")"
printf '%s\n' "$t1" >"$dd/retry"
n=$(ncalls)
depe
ok "D07-AC-5 a rejected sha put back by deploy/retry, with its run now success, is deployed on the next run" '[ "$(head_of)" = "$t1" ] && printf "%s\n" "$o" | grep -Fqx "$(ci_line "$before" "$t1" 7002)" && ! in_rejected "$t1" && [ "$(ncalls)" = "$n" ]'

# D07-AC-6: a non-runtime range is fast-forwarded without CI; a malformed deploy-ci deploys nothing.
before=$(head_of)
mk n1 SPEC.md docs/x.md README.md
n1=$(head_w)
gl=$(wc -l <"$D07/gh.log"); n=$(ncalls)
depe
ok "D07-AC-6 a non-runtime range is fast-forwarded with D04's 'without make test: no runtime change' line" '[ "$(head_of)" = "$n1" ] && [ "$o" = "$(deployed_line "$before" "$n1" " without make test: no runtime change")" ]'
ok "D07-AC-6 a non-runtime range makes no gh call and runs no make test" '[ "$(head_of)" = "$n1" ] && [ "$(wc -l <"$D07/gh.log")" = "$gl" ] && [ "$(ncalls)" = "$n" ]'
mk m1 scheduler/m1.sh
m1=$(head_w); setrun "$m1" 8001 completed success
before=$(head_of); rejs=$(rejsum); gl=$(wc -l <"$D07/gh.log")
for bad in 'acme/widget test.yml' 'widget test.yml main' 'acme/widget test.yml main extra' 'acme/widget'; do
	printf '%s\n' "$bad" >"$cfg"
	depe
	ok "D07-AC-6 a malformed deploy-ci ($bad) deploys nothing, runs no make test, exits 2" '[ "$dst" = 2 ] && [ "$(head_of)" = "$before" ] && [ "$(ncalls)" = "$n" ] && [ "$(rejsum)" = "$rejs" ] && [ "$(wc -l <"$D07/gh.log")" = "$gl" ]'
	ok "D07-AC-6 a malformed deploy-ci ($bad): one stderr line 'deploy-ci: <reason>', no status line" '[ "$(printf "%s\n" "$e" | grep -c "^deploy-ci:")" = 1 ] && [ -z "$o" ]'
done
cfg_on
depe
ok "D07-AC-6 with the configuration put right the commit is deployed after CI" '[ "$(head_of)" = "$m1" ] && [ "$o" = "$(ci_line "$before" "$m1" 8001)" ]'

# no token anywhere
ok "D07-AC-5 no output of any run held the token" '! grep -Fq "$secret" "$D07/all.out"'

echo
if [ "$fails" -eq 0 ]; then echo "all D07 deploy tests passed"; else echo "$fails D07 deploy test(s) FAILED"; exit 1; fi
