#!/bin/bash
# G04-AC-6 (the argument): owner/name and github:owner/name run the GitHub backend (over the gh emulator) with the same
# runtime folders; an unknown forge exits 2 with a one-line message naming it and makes no runtime folder.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g04.sh"

# --- the GitHub spellings: one runtime name, `widgets`, whichever spelling
g04_gh_emul
mkdir -p "$g04data/repos"
git clone -q "$tmp/remote.git" "$g04data/repos/widgets"   # the loop finds its clone and never reaches github.com
calls() { cat "$G04/ghstate/calls.jsonl" 2>/dev/null | wc -l; }
base=''
for spec in acme/widgets github:acme/widgets; do
	c0=$(calls)
	rm -f "$g04data/state/widgets/heartbeat"
	g04_run "$spec" widgets
	if wait_until 20 g04_ticking "$g04data/state/widgets"; then pass "G04-AC-6: $spec: the loop ticks in state/widgets"; else fail "G04-AC-6: $spec: the loop ticks in state/widgets"; fi
	wait_ticks 2 "$g04data/state/widgets"
	g04_stop
	ok "G04-AC-6: $spec: the GitHub backend made its calls (the gh emulator saw some)" test "$(calls)" -gt "$c0"
	ok "G04-AC-6: $spec: the status log of state/widgets says the loop started for it" grep -qF "loop started for $spec" "$g04data/state/widgets/status.log"
	now="state: $(g04_names "$g04data/state") repos: $(g04_names "$g04data/repos") worktrees: $(g04_names "$g04data/worktrees")"
	[ -n "$base" ] || base=$now
	ok "G04-AC-6: $spec: the runtime folders are state/widgets, repos/widgets and worktrees/widgets only ($now)" \
		test "$now" = "state: widgets repos: widgets worktrees: widgets"
	ok "G04-AC-6: $spec: the same runtime folders as the first spelling" test "$now" = "$base"
done
ok "G04-AC-6: both spellings logged their start into the one status log" test "$(grep -c 'loop started for' "$g04data/state/widgets/status.log")" = 2

# --- an unknown forge: exit 2, one line naming it, no runtime folder
data2=$G04/data-unknown
for spec in gitlab:acme/widgets; do
	out=$(env G04_DIR="$G04" NOODLEBOT_DATA=$data2 PATH=$G04/bin:$PATH SCHED_TICK=1 timeout 30 bash "$G04/nb/scheduler/loop.sh" "$spec" 2>"$G04/unknown.err" >"$G04/unknown.out"; echo $?)
	ok "G04-AC-6: $spec: exits 2" test "$out" = 2
	ok "G04-AC-6: $spec: one line on stderr" test "$(wc -l <"$G04/unknown.err")" = 1
	ok "G04-AC-6: $spec: the message names the forge (gitlab)" grep -q 'gitlab' "$G04/unknown.err"
	ok "G04-AC-6: $spec: no state, repos or worktrees folder is made" sh -c "[ ! -e '$data2/state' ] && [ ! -e '$data2/repos' ] && [ ! -e '$data2/worktrees' ]"
done
# --- change 5: github:acme/widgets means acme/widgets wherever the repository reaches a helper or a session
# (a node session's prompt and environment, the site-repos file, the helpers' --repo); no `github:` anywhere in them.
g04_cleanup; rm -rf "$g04data/state/widgets/node" "$g04data/worktrees/widgets" "$G04/ghstate/calls.jsonl"; git -C "$g04data/repos/widgets" worktree prune
echo gistid >"$HOME/.config/noodlebot/gist"; printf 'fake-gist-token' >"$HOME/.config/noodlebot/gist-token"; chmod 600 "$HOME/.config/noodlebot/gist-token"
cat >"$G04/bin/claude" <<'EOF2'
#!/bin/sh
id=${2##* }
echo "$id" >>"$G04_DIR/runs.$id"
printf '%s\n' "$NOODLEBOT_FORGE_REPO" >"$G04_DIR/session.forge-repo"
mkdir -p "out/node/$id" && echo brief >"out/node/$id/brief.md"
while :; do sleep 0.2; done
EOF2
rm -f "$g04data/state/widgets/heartbeat" "$g04data/state/widgets/site-repos"
g04_run github:acme/widgets widgets
st=$g04data/state/widgets
ok_wait() { [ -s "$G04/session.forge-repo" ] && [ -s "$st/node/A01/unattended.md" ] && [ -s "$st/site-repos" ]; }
wait_until 20 ok_wait
wait_ticks 2 "$st"
g04_stop
ok "G04-AC-6: github:acme/widgets: a node session's NOODLEBOT_FORGE_REPO is acme/widgets" test "$(cat "$G04/session.forge-repo" 2>/dev/null)" = acme/widgets
ok "G04-AC-6: github:acme/widgets: the node prompt (unattended.md) has no 'github:' (@REPO@ is acme/widgets)" sh -c "[ -s '$st/node/A01/unattended.md' ] && ! grep -q 'github:' '$st/node/A01/unattended.md' && grep -q 'acme/widgets' '$st/node/A01/unattended.md'"
ok "G04-AC-6: github:acme/widgets: the site-repos file holds acme/widgets" test "$(cat "$st/site-repos" 2>/dev/null)" = acme/widgets
ok "G04-AC-6: github:acme/widgets: no forge call carries 'github:' in its argv" sh -c "[ -s '$G04/ghstate/calls.jsonl' ] && ! grep -q 'github:' '$G04/ghstate/calls.jsonl'"
# --- S4-Q2: the token script fails (the loop's NOODLEBOT_FORGE_TOKEN_SCRIPT exits non-zero): the tick notes "no GitHub App
# token; nothing started" and leaves merged-prs.tsv, open-prs.tsv and closed-prs.tsv in state/widgets byte-identical.
g04_cleanup; rm -rf "$g04data/state/widgets/node" "$g04data/worktrees/widgets"; git -C "$g04data/repos/widgets" worktree prune
cp "$HOME/.config/noodlebot/token" "$G04/token.ok"
printf '#!/bin/sh\necho "token: refused" >&2\nexit 3\n' >"$HOME/.config/noodlebot/token"; chmod +x "$HOME/.config/noodlebot/token"
st=$g04data/state/widgets
printf '41 node/M01-merged-one\n42 node/M02-merged-two\n' >"$st/merged-prs.tsv"
printf '43 node/O01-open-one 0123456789abcdef0123456789abcdef01234567 true MERGEABLE\n' >"$st/open-prs.tsv"
printf '44 node/C01-closed-one 2026-06-01T12:00:00Z false\n45 node/C02-closed-two 2026-06-02T12:00:00Z true\n' >"$st/closed-prs.tsv"
for k in merged open closed; do cp "$st/$k-prs.tsv" "$G04/before.$k-prs.tsv"; done
rm -f "$st/heartbeat"
n_tok() { local n; n=$(grep -cF 'no GitHub App token; nothing started' "$st/status.log" 2>/dev/null); echo "${n:-0}"; }
tok0=$(n_tok)
tok_noted() { [ "$(n_tok)" -gt "$tok0" ]; }
g04_run acme/widgets widgets
tq=0
if wait_until 20 g04_ticking "$st" && wait_until 10 tok_noted; then tq=1; fi
wait_ticks 2 "$st"
g04_stop
cp "$G04/token.ok" "$HOME/.config/noodlebot/token"
ok "S4-Q2: a failing token script: the tick notes 'no GitHub App token; nothing started'" test "$tq" = 1
for k in merged open closed; do   # without that tick, an untouched file proves nothing: the checks fail with it
	c="S4-Q2: a failing token script: state/widgets/$k-prs.tsv is byte-identical to what it held before the tick"
	if [ "$tq" = 1 ]; then ok "$c" cmp -s "$G04/before.$k-prs.tsv" "$st/$k-prs.tsv"; else fail "$c (no tick met the failing token script)"; fi
done
loop_end
