#!/bin/sh
# The conformance suite of the forge interface (G04): scheduler/forge.py, its GitHub backend and the fake forge.
#   sh scheduler/forge.test.sh   (make test)
#
# One set of cases runs against both backends: the GitHub backend over a gh emulator on PATH
# (testdata/forge/fakegh.py, recording each call) and the fake forge (testdata/forge/fake.py, state in files), each
# through the Python interface and through the CLI's JSON, from the same fixture content (testdata/forge/fixture).
# testdata/forge/conf.py holds the cases (every operation of the interface table of the G04 brief; the normalised results
# are compared by their guaranteed keys); this file runs them and adds:
#   G04-AC-1  the README's inventory lists only exported operations (testdata/forge/readme_check.py)
#   G04-AC-2  the operations over both backends; a failing call exits 1 / raises ForgeError, never an empty result;
#             an unknown forge exits 2 (testdata/forge/iface.py)
#   G04-AC-3  credentials (GH_TOKEN as given, the counting token script once per process and repository, none),
#             the token in no output, argv or git config; a capability the fake forge lacks (conf.py)
#   G04-AC-8  the README's operations table
# All scratch files are under $tmp/G04. HOME is a scratch folder: the real token script is never run.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$src/.." && pwd -P)
td=$src/testdata/forge
. "$src/testdata/lib/common.sh"
for v in $(env | sed -n 's/^\(NOODLEBOT_FORGE[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done
unset GH_TOKEN USAGE_7D_MARGIN NOODLEBOT_DATA NOODLEBOT_VERSION
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
G=$tmp/G04
mkdir -p "$G/home"
real_git=$(command -v git)
export HOME=$G/home XDG_CONFIG_HOME=$G/home GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
# lines <file>: print a checker's PASS/FAIL lines (and their details) and count the FAIL ones.
lines() {
	cat "$1"
	fails=$((fails + $(grep -c '^FAIL: ' "$1")))
}

# work <dir>: the files a conformance run needs: gh and git on a bin folder, a checkout with branch feat/x, a bare
# template, the bodies the site and comment cases read.
work() {
	mkdir -p "$1/bin"
	printf '#!/bin/sh\nexec python3 "%s/fakegh.py" "$@"\n' "$td" >"$1/bin/gh"
	cat >"$1/bin/git" <<EOF2
#!/bin/sh
# records the argv of each git call and the NAMES of the environment variables that carry the token value
[ -z "\${G04_GITLOG:-}" ] || { echo "\$*" >>"\$G04_GITLOG"; env | grep -F "\${G04_TOKEN:-@none@}" | cut -d= -f1 >>"\$G04_GITENV"; }
exec "$real_git" "\$@"
EOF2
	chmod +x "$1/bin/gh" "$1/bin/git"
	"$real_git" init -q --bare "$1/bare-template.git"
	"$real_git" init -q -b main "$1/checkout"
	echo one >"$1/checkout/f" && "$real_git" -C "$1/checkout" add f && "$real_git" -C "$1/checkout" commit -q -m one
	"$real_git" -C "$1/checkout" checkout -q -b feat/x
	echo two >"$1/checkout/f" && "$real_git" -C "$1/checkout" commit -q -a -m two
	printf '{"files": {"index.json": {"content": "{\\"a\\": 1}"}}}' >"$1/site-body.json"
	printf 'from a file' >"$1/body.txt"
}

# --- the conformance run: both backends at once ---------------------------------------------------------------------
work "$G/gh"; work "$G/fake"
python3 "$td/conf.py" run github "$G/gh" "$G/gh.json" >"$G/gh.out" 2>"$G/gh.err" &
p1=$!
python3 "$td/conf.py" run fake "$G/fake" "$G/fake.json" >"$G/fake.out" 2>"$G/fake.err" &
p2=$!

# --- the interface: operations list, forge arguments, unknown forge (while the runs go) -----------------------------
cp -r "$td/fixture" "$G/iface-state"
python3 "$td/iface.py" "$G/iface-state" >"$G/iface.out" 2>"$G/iface.err"
[ -s "$G/iface.out" ] || { echo "FAIL: G04-AC-2: the interface checks did not run: $(head -n 3 "$G/iface.err")"; fails=$((fails + 1)); }
lines "$G/iface.out"

# --- the README (G04-AC-1, G04-AC-8) --------------------------------------------------------------------------------
python3 -I "$src/forge.py" ops >"$G/ops.json" 2>/dev/null || : >"$G/ops.json"
python3 -I "$td/readme_check.py" "$src/forges/README.md" "$root" "$G/ops.json" >"$G/readme.out" 2>"$G/readme.err"
[ -s "$G/readme.out" ] || { echo "FAIL: G04-AC-1: the README checks did not run: $(head -n 3 "$G/readme.err")"; fails=$((fails + 1)); }
lines "$G/readme.out"

# --- credentials (G04-AC-3): the GitHub backend over the emulator ---------------------------------------------------
TOK=ghs_G04distinctive0token
cp -r "$td/fixture" "$G/cstate"
cbin=$G/gh/bin
# cred <name> <env assignments...> -- <command...>: run the command with the emulator's state and a clean credential env.
cred() {
	_n=$1; shift
	rm -f "$G/count" "$G/cstate/calls.jsonl" "$G/gitlog" "$G/gitenv"
	: >"$G/count"
	(
		unset GH_TOKEN NOODLEBOT_FORGE_TOKEN_SCRIPT
		PATH=$cbin:$PATH FAKE_GH_DIR=$G/cstate TOKEN_COUNT_FILE=$G/count
		export PATH FAKE_GH_DIR TOKEN_COUNT_FILE
		while [ "$1" != -- ]; do export "$1"; shift; done
		shift
		"$@" >"$G/$_n.out" 2>"$G/$_n.err"
	)
	echo $? >"$G/$_n.rc"
}
# calls_tokens: the GH_TOKEN of every recorded gh call, one per line ("none" for unset).
calls_tokens() { [ -f "$G/cstate/calls.jsonl" ] && python3 -c '
import json, sys
for l in open(sys.argv[1]):
    print(json.loads(l)["gh_token"] or "none")' "$G/cstate/calls.jsonl"; }
ncalls() { [ -f "$G/cstate/calls.jsonl" ] && wc -l <"$G/cstate/calls.jsonl" || echo 0; }
argv_clean() { [ -s "$G/cstate/calls.jsonl" ] && python3 -c '
import json, sys
tok = sys.argv[2]
sys.exit(1 if any(tok in json.dumps(json.loads(l)["argv"]) for l in open(sys.argv[1])) else 0)' "$G/cstate/calls.jsonl" "$1"; }
# quiet <token> <run>: the run made gh calls (so it did something) and printed the token nowhere.
quiet() { [ -s "$G/cstate/calls.jsonl" ] && ! grep -rqF -- "$1" "$G/$2.out" "$G/$2.err" 2>/dev/null; }

ts=$td/token-count.sh
cred many NOODLEBOT_FORGE_TOKEN_SCRIPT="$ts" -- python3 -I "$td/cred.py" many
ok "G04-AC-3: (precondition) several calls in one Python process ran" test "$(cat "$G/many.rc")" = 0 -a "$(ncalls)" -ge 5
ok "G04-AC-3: several calls (and a second open of the same repository) in one process run the token script once" test "$(wc -l <"$G/count")" = 1
ok "G04-AC-3: the token script is run with <owner/name>" test "$(cat "$G/count")" = acme/widgets
ok "G04-AC-3: every gh call of that process saw the token script's token in GH_TOKEN" test "$(calls_tokens | sort -u)" = "$TOK"
ok "G04-AC-3: the token is in no argv of the gh calls" argv_clean "$TOK"
ok "G04-AC-3: the token is in no stdout or stderr of the process" quiet "$TOK" many
cred repos NOODLEBOT_FORGE_TOKEN_SCRIPT="$ts" -- python3 -I "$td/cred.py" repos
ok "G04-AC-3: the token script runs once per repository in a process (two repositories, four opens: two runs)" test "$(sort "$G/count" | tr '\n' ' ')" = "acme/other acme/widgets "

cred one1 NOODLEBOT_FORGE_TOKEN_SCRIPT="$ts" -- python3 -I "$src/forge.py" --repo acme/widgets repo default-branch
cat "$G/count" >"$G/count1"
ok "G04-AC-3: (precondition) the CLI works over the emulator" test "$(cat "$G/one1.rc")" = 0 -a "$(cat "$G/one1.out")" = '"main"'
cred two NOODLEBOT_FORGE_TOKEN_SCRIPT="$ts" -- sh -c 'python3 -I "$1" --repo acme/widgets repo default-branch; python3 -I "$1" --repo acme/widgets label list' sh "$src/forge.py"
ok "G04-AC-3: two CLI processes run the token script twice (a second process runs it again)" test "$(wc -l <"$G/count")" = 2
ok "G04-AC-3: both CLI processes' gh calls saw the token" test "$(ncalls)" -ge 2 -a "$(calls_tokens | sort -u)" = "$TOK"
ok "G04-AC-3: the token is in no stdout or stderr of the CLI processes" quiet "$TOK" two

cred caller GH_TOKEN=caller-token-G04 NOODLEBOT_FORGE_TOKEN_SCRIPT="$ts" -- python3 -I "$td/cred.py" many
ok "G04-AC-3: with GH_TOKEN set the calls use it as given (and the process works)" test "$(cat "$G/caller.rc")" = 0 -a "$(calls_tokens | sort -u)" = caller-token-G04
ok "G04-AC-3: with GH_TOKEN set the token script is not run" test "$(wc -l <"$G/count")" = 0 -a "$(ncalls)" -ge 5
ok "G04-AC-3: the caller's token is in no stdout or stderr" quiet caller-token-G04 caller
ok "G04-AC-3: the caller's token is in no argv of the gh calls" argv_clean caller-token-G04
cred callercli GH_TOKEN=caller-token-G04 NOODLEBOT_FORGE_TOKEN_SCRIPT="$ts" -- python3 -I "$src/forge.py" --repo acme/widgets label list
ok "G04-AC-3: the CLI with GH_TOKEN set uses it as given and does not run the token script" test "$(wc -l <"$G/count")" = 0 -a "$(calls_tokens | sort -u)" = caller-token-G04 -a "$(cat "$G/callercli.rc")" = 0
ok "G04-AC-3: the caller's token is in no argv of the CLI's gh calls" argv_clean caller-token-G04

cred none -- python3 -I "$td/cred.py" many
ok "G04-AC-3: with neither GH_TOKEN nor a token script gh sees no GH_TOKEN (its own login)" test "$(cat "$G/none.rc")" = 0 -a "$(ncalls)" -ge 5 -a "$(calls_tokens | sort -u)" = none
cred nonecli -- python3 -I "$src/forge.py" --repo acme/widgets label list
ok "G04-AC-3: the CLI with no credential at all works and gh sees no GH_TOKEN" test "$(cat "$G/nonecli.rc")" = 0 -a "$(calls_tokens | sort -u)" = none

cred tfail NOODLEBOT_FORGE_TOKEN_SCRIPT="$ts" TOKEN_FAIL=1 -- python3 -I "$td/cred.py" fail
ok "G04-AC-3: a failing token script raises ForgeError saying the token script failed, and gh is not called" test "$(cat "$G/tfail.rc")" = 0 -a "$(ncalls)" = 0
cred tfailcli NOODLEBOT_FORGE_TOKEN_SCRIPT="$ts" TOKEN_FAIL=1 -- python3 -I "$src/forge.py" --repo acme/widgets label list
ok "G04-AC-3: with a failing token script the CLI exits 1, nothing on stdout, a stderr line naming the token script" sh -c 'test "$(cat "$1/tfailcli.rc")" = 1 -a ! -s "$1/tfailcli.out" && grep -qi "token script" "$1/tfailcli.err"' sh "$G"
cred tempty NOODLEBOT_FORGE_TOKEN_SCRIPT="$ts" TOKEN_EMPTY=1 -- python3 -I "$td/cred.py" empty
ok "G04-AC-3: a token script that prints no token does not crash the process (ForgeError or no token)" test "$(cat "$G/tempty.rc")" = 0

touch "$G/cstate/fail"
cred failtok NOODLEBOT_FORGE_TOKEN_SCRIPT="$ts" -- python3 -I "$src/forge.py" --repo acme/widgets label list
ok "G04-AC-3: a failing gh call with a token: exit 1, nothing on stdout, the token in no output" sh -c 'test "$(cat "$1/failtok.rc")" = 1 -a ! -s "$1/failtok.out" && [ -s "$1/cstate/calls.jsonl" ] && ! grep -qF "$2" "$1/failtok.err"' sh "$G" "$TOK"
rm -f "$G/cstate/fail"

# the token and git: a push with a token script, to a bare repository the GitHub clone URL is redirected to
"$real_git" init -q --bare "$G/bare-cred.git"
cred push NOODLEBOT_FORGE_TOKEN_SCRIPT="$ts" G04_GITLOG="$G/gitlog" G04_GITENV="$G/gitenv" G04_TOKEN="$TOK" PATH="$cbin:$PATH" \
	GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$G/bare-cred.git.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/acme/widgets \
	-- python3 -I "$src/forge.py" --repo acme/widgets branch push --path "$G/gh/checkout" --branch feat/x
want=$("$real_git" -C "$G/gh/checkout" rev-parse feat/x)
ok "G04-AC-3: (precondition) the push with a token script reached the bare repository" test "$(cat "$G/push.rc")" = 0 -a "$("$real_git" --git-dir "$G/bare-cred.git" rev-parse refs/heads/feat/x 2>/dev/null)" = "$want"
ok "G04-AC-3: git saw the push of the branch, and never --force" sh -c 'grep -q "push" "$1" && grep -q "feat/x" "$1" && ! grep -qE -- "--force|(^| )-f( |$)| \+" "$1"' sh "$G/gitlog"
ok "G04-AC-3: git got the token through its environment" test -s "$G/gitenv"
ok "G04-AC-3: the token is in no argv git saw" sh -c '[ -s "$1" ] && ! grep -qF "$2" "$1"' sh "$G/gitlog" "$TOK"
ok "G04-AC-3: the token is in no git configuration (the checkout, the bare repository, HOME) and in no file there" sh -c '[ -s "$1/gitlog" ] && ! grep -rqaF "$2" "$1/gh/checkout/.git" "$1/bare-cred.git" "$1/home" 2>/dev/null' sh "$G" "$TOK"
ok "G04-AC-3: the token is in no stdout or stderr of the push" sh -c '[ -s "$1/gitlog" ] && ! grep -qF "$2" "$1/push.out" "$1/push.err"' sh "$G" "$TOK"

# --- wait for the conformance runs, then compare --------------------------------------------------------------------
wait "$p1" "$p2" 2>/dev/null
if [ -s "$G/gh.json" ] && [ -s "$G/fake.json" ]; then
	python3 "$td/conf.py" check "$G/gh.json" "$G/fake.json" >"$G/check.out" 2>"$G/check.err"
	[ -s "$G/check.out" ] || { echo "FAIL: G04-AC-2: the comparison did not run: $(tail -n 3 "$G/check.err")"; fails=$((fails + 1)); }
	lines "$G/check.out"
else
	echo "FAIL: G04-AC-2: the conformance run produced no result: $(tail -n 2 "$G/gh.err" "$G/fake.err" | tr '\n' ' ')"
	fails=$((fails + 1))
fi

# --- the session wrapper (G04-AC-3, G04-AC-4): forge-cli.sh, run-session.sh's environment, nodes.py over $NOODLEBOT_FORGE -
# HOME's token script is a counting fake (under $G/home, scratch: the real token script is never run)
mkdir -p "$G/home/.config/noodlebot"
printf '#!/bin/sh\nexec sh "%s" "$@"\n' "$ts" >"$G/home/.config/noodlebot/token"
chmod +x "$G/home/.config/noodlebot/token"
fcli=$src/forge-cli.sh
ok "G04-AC-3: scheduler/forge-cli.sh exists and is executable" test -f "$fcli" -a -x "$fcli"
cred wref NOODLEBOT_FORGE_TOKEN_SCRIPT="$ts" -- python3 -I "$src/forge.py" --repo acme/widgets label list
cred wrap -- sh "$fcli" --repo acme/widgets label list
ok "G04-AC-3: forge-cli.sh with no GH_TOKEN and no token script variable runs HOME's token script once; gh sees its token" test "$(cat "$G/wrap.rc")" = 0 -a "$(wc -l <"$G/count")" = 1 -a "$(calls_tokens | sort -u)" = "$TOK"
ok "G04-AC-3: forge-cli.sh's stdout and exit code are forge.py's" sh -c 'test -s "$1/wref.out" && cmp -s "$1/wref.out" "$1/wrap.out" && test "$(cat "$1/wref.rc")" = "$(cat "$1/wrap.rc")"' sh "$G"
ok "G04-AC-3: the token is in no output of forge-cli.sh" quiet "$TOK" wrap
cred wrapbad -- sh "$fcli" --repo gitlab:foo/bar caps
ok "G04-AC-3: forge-cli.sh on an unknown forge exits 2 with nothing on stdout (as forge.py)" test -x "$fcli" -a "$(cat "$G/wrapbad.rc")" = 2 -a ! -s "$G/wrapbad.out" -a -s "$G/wrapbad.err"
cred wrapset NOODLEBOT_FORGE_TOKEN_SCRIPT="$ts" TOKEN_VALUE=ghs_G04other -- sh "$fcli" --repo acme/widgets label list
ok "G04-AC-3: forge-cli.sh with NOODLEBOT_FORGE_TOKEN_SCRIPT set uses that script, not HOME's" test "$(cat "$G/wrapset.rc")" = 0 -a "$(calls_tokens | sort -u)" = ghs_G04other
cred wrapgh GH_TOKEN=caller-token-G04 -- sh "$fcli" --repo acme/widgets label list
ok "G04-AC-3: forge-cli.sh with GH_TOKEN set uses it as given and runs no token script" test "$(cat "$G/wrapgh.rc")" = 0 -a "$(wc -l <"$G/count")" = 0 -a "$(calls_tokens | sort -u)" = caller-token-G04
ok "G04-AC-3: the caller's token is in no output of forge-cli.sh" quiet caller-token-G04 wrapgh

# run-session.sh: the session's environment (a fake claude dumps it; the loop's variables are in the environment)
mkdir -p "$G/sess/bin" "$G/sess/wt" "$G/sess/state"
printf '#!/bin/sh\nenv >"%s/sess/env"\nexit 0\n' "$G" >"$G/sess/bin/claude"
chmod +x "$G/sess/bin/claude"
echo "the system prompt" >"$G/sess/state/unattended.md"
printf 'oauth-G04\n' >"$G/home/.config/noodlebot/oauth-token"
env -u GH_TOKEN PATH="$G/sess/bin:$PATH" NOODLEBOT_FORGE_TOKEN_SCRIPT=/nonexistent/G04-token NOODLEBOT_FORGE_REPO=acme/widgets \
	GH_TOKEN=ghx timeout -k 1 10 bash "$src/run-session.sh" "$G/sess/wt" "$G/sess/state" "/node B03" >"$G/sess/out" 2>"$G/sess/err"
ok "G04-AC-4: (precondition) run-session.sh started the session (the fake claude ran)" test -s "$G/sess/env"
ok "G04-AC-4: the session's NOODLEBOT_FORGE is the absolute path of scheduler/forge-cli.sh" grep -qxF "NOODLEBOT_FORGE=$src/forge-cli.sh" "$G/sess/env"
ok "G04-AC-4: the session's NOODLEBOT_FORGE_REPO is passed through" grep -qxF "NOODLEBOT_FORGE_REPO=acme/widgets" "$G/sess/env"
ok "G04-AC-4: the session has no NOODLEBOT_FORGE_TOKEN_SCRIPT" sh -c '[ -s "$1" ] && ! grep -q "^NOODLEBOT_FORGE_TOKEN_SCRIPT=" "$1"' sh "$G/sess/env"
ok "G04-AC-4: the session has no GH_TOKEN" sh -c '[ -s "$1" ] && ! grep -q "^GH_TOKEN=" "$1"' sh "$G/sess/env"

# nodes.py over $NOODLEBOT_FORGE: a recording fake CLI in a folder without forge.py
mkdir -p "$G/np/cli" "$G/np/repo/docs" "$G/np/repo/nodes"
cat >"$G/np/cli/forge-cli.sh" <<'EOF2'
#!/bin/sh
# records its argv (one call per line); prints $G04_PRS (JSON) or exits non-zero while $G04_CLI_FAIL is set
echo "$*" >>"$G04_CLI_LOG"
[ -z "${G04_CLI_FAIL:-}" ] || { echo "forge: boom" >&2; exit 1; }
cat "$G04_PRS"
EOF2
chmod +x "$G/np/cli/forge-cli.sh"
printf '[{"number": 7, "state": "open", "head": "node/A01-first"}, {"number": 3, "state": "merged", "head": "node/A02-second"}]\n' >"$G/np/prs.json"
printf 'template: {headings: [Purpose]}\nnodes:\n  - {id: A01, track: now, name: first, deps: [], summary: "x"}\n  - {id: A02, track: now, name: second, deps: [], summary: "x"}\n' >"$G/np/repo/docs/graph.yaml"
for n in A01-first A02-second; do printf '# %s\n\n**Owns:** x\n' "$n" >"$G/np/repo/nodes/$n.md"; done
"$real_git" init -q -b main "$G/np/repo"
npy() { # npy <name> [env assignments]: nodes.py in the scratch repository, the fake CLI as $NOODLEBOT_FORGE
	_n=$1; shift
	( cd "$G/np/repo" && env -u NOODLEBOT_FORGE_REPO PATH="$G/gh/bin:$PATH" NOODLEBOT_FORGE="$G/np/cli/forge-cli.sh" G04_CLI_LOG="$G/np/$_n.log" \
		G04_PRS="$G/np/prs.json" "$@" python3 -I "$src/../plugin/skills/triage/nodes.py" >"$G/np/$_n.out" 2>"$G/np/$_n.err" )
	echo $? >"$G/np/$_n.rc"
}
npy ok
ok "G04-AC-4: nodes.py with NOODLEBOT_FORGE runs that CLI for its PR list (argv has pr list)" sh -c 'test -f "$1" && grep -q "pr list" "$1"' sh "$G/np/ok.log"
ok "G04-AC-4: nodes.py uses the CLI's JSON (open #7, merged #3)" sh -c 'grep -q "^A01 .*open #7" "$1" && grep -q "^A02 .*merged #3" "$1"' sh "$G/np/ok.out"
npy bad G04_CLI_FAIL=1
ok "G04-AC-4: nodes.py with the CLI failing: state ? for every node, the unknown message, exit 1" sh -c 'test "$(cat "$1/np/bad.rc")" = 1 && grep -q "^A01 .* ? " "$1/np/bad.out" && grep -q "unknown" "$1/np/bad.out" && test -s "$1/np/bad.log"' sh "$G"

# forge-cli.sh with neither GH_TOKEN, NOODLEBOT_FORGE_TOKEN_SCRIPT nor an executable ~/.config/noodlebot/token: no token
# script is named, the call runs with no token (gh uses its own login) and succeeds (G04-AC-3, change 2's order)
mkdir -p "$G/home-notoken/.config/noodlebot"
cred wrapnone HOME="$G/home-notoken" -- sh "$fcli" --repo acme/widgets label list
ok "G04-AC-3: forge-cli.sh with no token script anywhere (no variable, no ~/.config/noodlebot/token) exits 0" test "$(cat "$G/wrapnone.rc")" = 0
ok "G04-AC-3: forge-cli.sh with no token script anywhere runs gh with no token" test "$(calls_tokens | sort -u)" = none
printf '#!/bin/sh\necho should-not-run >&2\nexit 1\n' >"$G/home-notoken/.config/noodlebot/token"
cred wrapnx HOME="$G/home-notoken" -- sh "$fcli" --repo acme/widgets label list
ok "G04-AC-3: forge-cli.sh with a non-executable ~/.config/noodlebot/token runs gh with no token and exits 0" test "$(cat "$G/wrapnx.rc")" = 0 -a "$(calls_tokens | sort -u)" = none

# nodes.py over $NOODLEBOT_FORGE with no $NOODLEBOT_FORGE_REPO: the repository is origin's, passed as --repo
# (the CLI's folder holds forge.py, which nodes.py reads repo_of_remote from)
mkdir -p "$G/np/cli2"
cp "$G/np/cli/forge-cli.sh" "$G/np/cli2/forge-cli.sh"
cp "$src/forge.py" "$G/np/cli2/forge.py"
[ ! -d "$src/forges" ] || cp -R "$src/forges" "$G/np/cli2/forges"
"$real_git" -C "$G/np/repo" remote add origin git@github.com:someone/thing.git
( cd "$G/np/repo" && env -u NOODLEBOT_FORGE_REPO NOODLEBOT_FORGE="$G/np/cli2/forge-cli.sh" G04_CLI_LOG="$G/np/origin.log" \
	G04_PRS="$G/np/prs.json" python3 -I "$src/../plugin/skills/triage/nodes.py" >"$G/np/origin.out" 2>"$G/np/origin.err" )
ok "G04-AC-4: nodes.py with no NOODLEBOT_FORGE_REPO passes origin's repository: argv has --repo someone/thing and pr list" sh -c 'test -f "$1" && grep -q -e "--repo someone/thing" "$1" && grep -q "pr list" "$1"' sh "$G/np/origin.log"

if [ "$fails" -ne 0 ]; then
	echo "forge tests: $fails failed"
	exit 1
fi
echo "forge tests: all passed"
