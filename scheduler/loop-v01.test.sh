#!/bin/bash
# V01: the loop's version. Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"

# ---- V01: the loop's version: start line, rendered prompts, NOODLEBOT_VERSION, commit trailer ----
# The loop runs from a Git checkout $nbv (tag v7.0, one commit after it, GitHub origin), so its version is
# known: v7.0-1-g<sha>. The fake claude records NOODLEBOT_VERSION and makes commits in its worktree and in
# a second worktree of the clone, each once without and once with a Noodlebot-Version trailer of its own.
nbv=$tmp/nbv datav=$tmp/datav V01=$tmp/v01 V01_CLONE=$tmp/datav/repos/pv
statev=$datav/state/pv
state=$statev   # ok prints this log on a failure
export V01 V01_CLONE
mkdir -p "$nbv/scheduler" "$nbv/plugin" "$datav/repos" "$statev/node" "$V01" "$tmp/bin5"
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/unattended.md \
	"$src"/issues.py "$src"/unattended-triage.md "$src"/status.sh "$src"/report.py "$src"/usage.py "$nbv/scheduler/"
[ -f "$src/version.sh" ] && cp "$src/version.sh" "$nbv/scheduler/"
touch "$nbv/plugin/.keep"
git init -q -b main "$nbv"
git -C "$nbv" add -A && git -C "$nbv" -c user.name=t -c user.email=t@t commit -q -m v1
git -C "$nbv" tag v7.0
git -C "$nbv" -c user.name=t -c user.email=t@t commit -q --allow-empty -m v2
git -C "$nbv" remote add origin https://github.com/o/nbv.git
v01_ver=$(git -C "$nbv" describe --tags --always)
v01_sig=$(sh "$src/version.sh" --signature "$nbv" 2>/dev/null)
git init -q -b main "$tmp/workv"; mkdir -p "$tmp/workv/docs"
printf 'nodes:\n  - {id: C01, name: only-node, deps: []}\n' >"$tmp/workv/docs/graph.yaml"
git -C "$tmp/workv" add -A && git -C "$tmp/workv" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/workv" "$tmp/remotev.git"
git clone -q "$tmp/remotev.git" "$V01_CLONE"
cat >"$tmp/bin5/claude" <<'EOF'
#!/bin/sh
case "$2" in "/noodlebot:triage "*) echo "${NOODLEBOT_VERSION-unset}" >"$V01/env.triage"; touch "$V01/done.triage"; exit 0 ;; esac
id=${2##* }
echo "${NOODLEBOT_VERSION-unset}" >"$V01/env.node"
v=${NOODLEBOT_VERSION:-}
g() { git -c user.name=t -c user.email=t@t "$@"; }
# mk <label> <file>: one commit without a trailer, one with the session's own trailer
mk() {
	echo "$2" >"$2.1"; git add "$2.1"; g commit -q -m "$1 plain"; echo "$1-plain $(git rev-parse HEAD)" >>"$V01/commits"
	echo "$2" >"$2.2"; git add "$2.2"; g commit -q -m "$1 own trailer

Noodlebot-Version: $v"; echo "$1-trailer $(git rev-parse HEAD)" >>"$V01/commits"
}
mk own a
git -C "$V01_CLONE" worktree add -q --detach "$V01/wt2" HEAD
( cd "$V01/wt2" && mk second b )
# V01-AC-6, real-world shape: the session's own trailer (the right one, then another value) followed by Co-Authored-By.
mk2() {
	echo "$2" >"$2.3"; git add "$2.3"
	g commit -q -m "$1 trailer then co-author

Noodlebot-Version: $3
Co-Authored-By: Claude <noreply@anthropic.com>"; echo "$1 $(git rev-parse HEAD)" >>"$V01/commits2"
}
mk2 own-same a "$v"
mk2 own-other a "different-value"
( cd "$V01/wt2" && mk2 second-same b "$v" && mk2 second-other b "different-value" )
echo "Q1: x" >"$V01_STATE/node/$id/QUESTION.md"
touch "$V01/done.node"
exit 0
EOF
v01_done() { [ -e "$V01/done.node" ] && [ -e "$V01/done.triage" ]; }
v01_gone() { ! kill -0 "$1" 2>/dev/null; }
# gh: no PRs; one issue labelled noodlebot by the owner, until the loop removes that label.
echo '[{"number": 46}]' >"$V01/issues.json"
cat >"$tmp/bin5/gh" <<'EOF'
#!/bin/sh
case " $* " in
*" --state merged "*) ;;
*"/issues?labels=noodlebot"*) cat "$V01/issues.json" ;;
*"/events"*) echo '[{"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "o"}}]' ;;
*" DELETE "*"/labels/noodlebot"*) echo '[]' >"$V01/issues.json"; echo '[]' ;;
*"/labels"*) cat >/dev/null; echo '{}' ;;
esac
exit 0
EOF
chmod +x "$tmp/bin5/claude" "$tmp/bin5/gh"
export V01_STATE=$statev
NOODLEBOT_DATA=$datav PATH=$tmp/bin5:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 bash "$nbv/scheduler/loop.sh" o/pv >"$tmp/pv.out" 2>&1 &
lpv=$!; pids+=("$lpv")
wait_until 20 v01_done
wait_ticks 2   # the loop has gone on ticking after the sessions ended (the old fixed sleep of 1.5 s)
touch "$HOME/STOP-pv"
wait_until 5 v01_gone "$lpv"

ok "V01 (harness): the loop's checkout has a known version after a tag" sh -c "case '$v01_ver' in v7.0-1-g*) true ;; *) false ;; esac"
ok "V01-AC-3: a first start writes exactly one line 'loop started for o/pv, version <version>'" sh -c "[ \$(grep -c 'loop started for o/pv, version ' '$statev/status.log') = 1 ] && grep -q 'loop started for o/pv, version $v01_ver\$' '$statev/status.log'"
ok "V01-AC-3: and state/pv/version holds that version" sh -c "[ \"\$(cat '$statev/version' 2>/dev/null)\" = '$v01_ver' ]"
for t in "$src"/unattended*.md; do
	ok "V01-AC-5: the template $(basename "$t") contains @VERSION@" grep -qF @VERSION@ "$t"
done
for k in "node:$statev/node/C01/unattended.md" "triage:$statev/issue/46/unattended.md"; do
	f=${k#*:}
	ok "V01-AC-5: the rendered ${k%%:*} prompt exists" test -s "$f"
	ok "V01-AC-5: the rendered ${k%%:*} prompt has no @VERSION@ left" sh -c "[ -s '$f' ] && ! grep -qF @VERSION@ '$f'"
	ok "V01-AC-5: the rendered ${k%%:*} prompt contains the loop's version" grep -qF "$v01_ver" "$f"
	ok "V01-AC-5: the rendered ${k%%:*} prompt contains the signature line" grep -qF -- "$v01_sig" "$f"
	ok "V01-AC-5: the rendered ${k%%:*} prompt tells the session to end PR bodies and comments with the signature line" sh -c "grep -qiE 'pr body|pr bodies' '$f' && grep -qi 'comment' '$f' && grep -qF -- '$v01_sig' '$f'"
	ok "V01-AC-5: the rendered ${k%%:*} prompt, in one instruction, says to end every PR body and every comment with the signature line" sh -c "grep -qi 'end every PR body and every comment' '$f' && grep -i -A3 'end every PR body and every comment' '$f' | grep -qF -- '$v01_sig'"
done
ok "V01-AC-5: the node session's environment has NOODLEBOT_VERSION equal to the version" sh -c "[ \"\$(cat '$V01/env.node' 2>/dev/null)\" = '$v01_ver' ]"
ok "V01-AC-5: the triage session's environment has NOODLEBOT_VERSION equal to the version" sh -c "[ \"\$(cat '$V01/env.triage' 2>/dev/null)\" = '$v01_ver' ]"
# AC-6: each commit ends with exactly one trailer.
ok "V01-AC-6: the fake session made its four commits" sh -c "[ \$(wc -l <'$V01/commits' 2>/dev/null || echo 0) = 4 ]"
while read -r lbl sha; do
	where=worktree; case $lbl in second-*) where="second worktree of the clone" ;; esac
	case $lbl in *plain) how="without a trailer of its own" ;; *) how="with a trailer of its own" ;; esac
	ok "V01-AC-6: a commit in the session's $where, $how, ends with exactly one Noodlebot-Version trailer for the session's version" sh -c "[ \"\$(git -C '$V01_CLONE' log -1 --format=%B '$sha' | git interpret-trailers --parse | grep -c '^Noodlebot-Version:')\" = 1 ] && git -C '$V01_CLONE' log -1 --format=%B '$sha' | git interpret-trailers --parse | grep -qx 'Noodlebot-Version: $v01_ver'"
done <"$V01/commits"
ok "V01-AC-6: the fake session made its four commits with a Co-Authored-By after the trailer" sh -c "[ \$(wc -l <'$V01/commits2' 2>/dev/null || echo 0) = 4 ]"
while read -r lbl sha; do
	ok "V01-AC-6: a session commit '$lbl' (its own trailer, then Co-Authored-By) ends with exactly one Noodlebot-Version trailer, the session's version" sh -c "[ \"\$(git -C '$V01_CLONE' log -1 --format=%B '$sha' | git interpret-trailers --parse | grep -c '^Noodlebot-Version:')\" = 1 ] && git -C '$V01_CLONE' log -1 --format=%B '$sha' | git interpret-trailers --parse | grep -qx 'Noodlebot-Version: $v01_ver'"
done <"$V01/commits2"
git -C "$V01_CLONE" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "outside any session" 2>/dev/null
ok "V01-AC-6: a commit in the clone outside any session gets no Noodlebot-Version trailer" sh -c "[ -x '$V01_CLONE/.git/hooks/commit-msg' ] && ! git -C '$V01_CLONE' log -1 --format=%B | git interpret-trailers --parse | grep -q '^Noodlebot-Version:'"
NOODLEBOT_VERSION=probe git -C "$V01_CLONE" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "inside a session" 2>/dev/null
ok "V01-AC-6: the same clone's hook adds the trailer when NOODLEBOT_VERSION is set" sh -c "[ \"\$(git -C '$V01_CLONE' log -1 --format=%B | git interpret-trailers --parse | grep -c '^Noodlebot-Version: probe\$')\" = 1 ]"

loop_end
