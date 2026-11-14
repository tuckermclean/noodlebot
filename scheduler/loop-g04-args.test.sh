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
loop_end
