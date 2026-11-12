# Shared by loop-w02*.test.sh (source after loop-prelude.sh): the fixture of the W02 runs (a fresh scheduler copy, fake gh/claude/report.py/site.py).
# ---- W02: the visibility record (W02-AC-6) and the publish step (W02-AC-5) ----
# A fresh scheduler copy (own data root, own HOME config). The fake report.py and a wrapper around the
# real site.py log their calls, in order, to $W02/order.log; the wrapper also logs GH_TOKEN and then
# runs the real publish ("site-real.py") against the fake gh, which answers the gist PATCH as $W02/patch-mode
# says (ok, or 500) and "repos/o/<name> --jq .private" as $W02/vis-mode.<name> says (false, true, fail).
W02=$tmp/w02
nbw=$W02/nb
mkdir -p "$nbw/scheduler" "$nbw/plugin" "$W02/bin"
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/unattended.md \
	"$src"/issues.py "$src"/unattended-triage.md "$src"/status.sh "$src"/usage.py "$nbw/scheduler/"
[ -f "$src/harness.py" ] && { mkdir -p "$nbw/scheduler/harnesses"; cp "$src/harness.py" "$nbw/scheduler/"; cp "$src"/harnesses/*.py "$nbw/scheduler/harnesses/"; }
[ -f "$src/labels.py" ] && cp "$src/labels.py" "$nbw/scheduler/"
[ -f "$src/site-schema.json" ] && cp "$src/site-schema.json" "$nbw/scheduler/"
[ -f "$src/site.py" ] && cp "$src/site.py" "$nbw/scheduler/site-real.py"
cat >"$nbw/scheduler/report.py" <<'EOF'
import sys
open(sys.argv[0].rsplit("/", 1)[0] + "/../../order.log", "a").write("report\n")
EOF
cat >"$nbw/scheduler/site.py" <<'EOF'
import os, sys
d = os.path.dirname(os.path.abspath(__file__))
w = os.path.join(d, "..", "..")
open(os.path.join(w, "order.log"), "a").write("publish " + " ".join(sys.argv[1:]) + "\n")
open(os.path.join(w, "ghtok.log"), "a").write(os.environ.get("GH_TOKEN", "<unset>") + "\n")
os.execv(sys.executable, [sys.executable, "-I", os.path.join(d, "site-real.py")] + sys.argv[1:])
EOF
W02TOK=ghp_W02gistTOKENvalue0123456789abcd
cat >"$W02/bin/gh" <<EOF
#!/bin/sh
W=$W02
EOF
cat >>"$W02/bin/gh" <<'EOF'
case " $* " in
*" --state merged "*) echo "1 node/A01-first-node" ;;
*" -X PATCH gists/"*)
	echo "patch GH_TOKEN=${GH_TOKEN:-<unset>}" >>"$W/order.log"; echo "$*" >>"$W/gh-args.log"
	prev=; for a in "$@"; do [ "$prev" = --input ] && cp "$a" "$W/body.$(date +%s%N)" 2>/dev/null; prev=$a; done
	case $(cat "$W/patch-mode" 2>/dev/null) in
	500) echo '{"message":"Server Error"}'; echo 'gh: Server Error (HTTP 500)' >&2; exit 1 ;;
	*) echo '{"id":"x"}' ;;
	esac ;;
*" repos/o/"*" --jq .private "*)
	n=${*#* repos/o/}; n=${n%% *}
	echo "$* GH_TOKEN=${GH_TOKEN:-<unset>}" >>"$W/vis.$n.log"
	case $(cat "$W/vis-mode.$n" 2>/dev/null) in
	true) echo true ;; fail) echo 'gh: Bad Gateway (HTTP 502)' >&2; exit 1 ;; *) echo false ;;
	esac ;;
*" repos/"*"/labels"*) cat >/dev/null; echo '[{"name": "noodlebot"}, {"name": "noodlebot-triaged"}, {"name": "noodlebot-status"}, {"name": "noodlebot-unit"}]' ;;
esac
echo "$*" >>"$W/gh-args.log"
exit 0
EOF
cat >"$W02/bin/claude" <<'EOF'
#!/bin/sh
id=${2##* }
env >"$W02_DIR/env.$id"; printf '%s\n' "$@" >"$W02_DIR/prompt.$id"
echo "Q1: x" >"$W02_STATE/node/$id/QUESTION.md"
exit 0
EOF
chmod +x "$W02/bin/gh" "$W02/bin/claude"
# w02_run <name> <gistfiles: both|gist|none> <patch-mode> <vis-mode> [<env assignment>...]: starts a loop
# for o/<name> with a 1 s tick and leaves its pid in $w02_pid.
w02_run() {
	local name=$1 files=$2 root=$W02/data
	w02_name=$name; w02_state=$root/state/$name
	rm -f "$HOME/.config/noodlebot/gist" "$HOME/.config/noodlebot/gist-token"
	case $files in both|gist) echo "w02gistid" >"$HOME/.config/noodlebot/gist" ;; esac
	case $files in both) printf '%s' "$W02TOK" >"$HOME/.config/noodlebot/gist-token"; chmod 600 "$HOME/.config/noodlebot/gist-token" ;; esac
	echo "$3" >"$W02/patch-mode"; echo "$4" >"$W02/vis-mode.$name"
	rm -f "$W02/order.log" "$W02/ghtok.log" "$W02/gh-args.log"; : >"$W02/order.log"
	mkdir -p "$root/repos" "$w02_state/node/A02"
	git clone -q "$tmp/remote.git" "$root/repos/$name"
	shift 4
	env "$@" W02_DIR="$W02" W02_STATE="$w02_state" NOODLEBOT_DATA=$root PATH=$W02/bin:$PATH SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		bash "$nbw/scheduler/loop.sh" "o/$name" >"$W02/$name.out" 2>&1 &
	w02_pid=$!; pids+=("$w02_pid")
}
w02_gone() { ! kill -0 "$1" 2>/dev/null; }
w02_stop() { touch "$HOME/STOP-$w02_name"; wait_until 8 w02_gone "$w02_pid"; kill "$w02_pid" 2>/dev/null; wait "$w02_pid" 2>/dev/null; true; }
# w02_wait <seconds> <command...>
w02_wait() { wait_until "$@"; }
w02_cnt() { grep -c "$1" "$2" 2>/dev/null || true; }
w02_ge() { [ "$(w02_cnt "$1" "$2")" -ge "$3" ]; }
w02_sl() { cat "$w02_state/status.log" 2>/dev/null; }
w02_n() { w02_sl | grep -cF "$1" || true; }
