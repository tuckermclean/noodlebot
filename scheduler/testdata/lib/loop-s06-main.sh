# Shared by loop-s06.test.sh and loop-s06-update.test.sh (source after loop-prelude.sh and loop-s06.sh): the folders, the
# remote and the fake gh and claude of the main S06 run, as the header of loop-s06.test.sh describes them. Runs at source.
S06=$tmp/s06; export S06
mkdir -p "$S06" "$tmp/bin06" "$tmp/nb06/scheduler" "$tmp/nb06/plugin" "$tmp/data06/repos" "$tmp/data06/state/other/node/Z01"
data06=$(cd "$tmp/data06" && pwd -P)
nb06=$(cd "$tmp/nb06" && pwd -P)
st06=$data06/state/s06 wt06=$data06/worktrees/s06
S06_STATE=$st06; export S06_STATE
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/nb06/scheduler/" ;; esac; done
git init -q -b main "$tmp/work06"; mkdir -p "$tmp/work06/docs"
{ echo 'nodes:'; for i in 1 2 3 4 5 6; do echo "  - {id: K0$i, name: k$i, deps: []}"; done; } >"$tmp/work06/docs/graph.yaml"
printf 'base\n' >"$tmp/work06/base.txt"
git -C "$tmp/work06" add -A && git -C "$tmp/work06" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$tmp/work06" checkout -q -b spec/u1 && echo spec >"$tmp/work06/spec.txt" && git -C "$tmp/work06" add -A &&
	git -C "$tmp/work06" -c user.name=t -c user.email=t@t commit -q -m spec && git -C "$tmp/work06" checkout -q main
git clone -q --bare "$tmp/work06" "$tmp/remote06.git"
git clone -q "$tmp/remote06.git" "$data06/repos/s06"
echo '[{"number": 46}]' >"$S06/issues.json"; : >"$S06/open.tsv"
cat >"$tmp/bin06/gh" <<'EOF'
#!/bin/sh
case " $* " in
*" --state open "*) cat "$S06/open.tsv" ;;
*" --state merged "* | *" --state closed "*) ;;
*"/issues?labels=noodlebot"*) cat "$S06/issues.json" ;;
*"/events"*) echo '[{"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "o"}}]' ;;
*"/labels"*) cat >/dev/null; echo '{}' ;;
esac
exit 0
EOF
cat >"$tmp/bin06/claude" <<'EOF'
#!/bin/sh
key=$(basename "$(pwd -P)")
n=$(( $(cat "$S06/runs.$key" 2>/dev/null || echo 0) + 1 )); echo $n >"$S06/runs.$key"
prompt= sid= app= prev=
for a in "$@"; do
	case $prev in -p) prompt=$a ;; --resume) sid=$a ;; --append-system-prompt) app=$a ;; esac
	prev=$a
done
r=$key.$n
printf '%s\n' "$@" >"$S06/args.$r"; printf '%s' "$prompt" >"$S06/prompt.$r"; printf '%s' "$app" >"$S06/append.$r"
printf '%s' "$sid" >"$S06/sid.$r"; pwd -P >"$S06/pwd.$r"
case $key in K0[1-6]) sd=$S06_STATE/node/$key ;; issue-*) sd=$S06_STATE/issue/${key#issue-} ;; *) sd=$S06_STATE/pr/${key#pr-} ;; esac
out() { printf '%s\n' "$1"; printf '%s\n' "$1" >>"$S06/log0.$key"; }
. "$S06_LIB/loop-s06-rej.sh"
if [ -n "$sid" ]; then   # resumed
	echo $PPID >"$S06/pg2.$key"
	git status --porcelain >"$S06/status.$r" 2>&1; git rev-parse HEAD >"$S06/head.$r" 2>&1; cat base.txt >"$S06/base.$r" 2>&1
	touch "$S06/resumed-up.$key"
	[ $key = K06 ] && exit 7
	printf '{"type":"system","subtype":"init","session_id":"%s","resumed_run":true}\n' "$sid"
	printf '{"type":"assistant","message":{"content":[{"type":"text","text":"resumed run of %s"}]},"resumed_run":true}\n' "$key"
	while [ -e "$S06/hold.$key" ]; do sleep 0.2; done
	if [ $key = K02 ]; then
		r=$(cat "$S06/reset.$key"); rej "$r"
		echo '{"type":"result","subtype":"error_during_execution","result":"You have hit your usage limit"}'
		while [ ! -e "$S06/go" ]; do sleep 0.2; done
	fi
	case $key in K0*) echo "Q1: x" >"$sd/QUESTION.md" ;; issue-*) echo "Q1: x" >"$sd/QUESTION.md" ;; esac
	exit 0
fi
if [ $n -ge 2 ]; then echo "Q1: x" >"$sd/QUESTION.md"; exit 0; fi   # restarted the usual way
echo $PPID >"$S06/pg.$key"; sleep 300 & echo $! >"$S06/child.$key"
echo dirty >>base.txt; echo u >"u.$key.txt"
git status --porcelain >"$S06/status.$r" 2>&1; git rev-parse HEAD >"$S06/head.$r" 2>&1
[ $key = K02 ] && out '{"type":"system","subtype":"init","session_id":"sid-K02-old"}'
[ $key = K05 ] || out "{\"type\":\"system\",\"subtype\":\"init\",\"cwd\":\"$(pwd -P)\",\"session_id\":\"sid-$key\"}"
touch "$S06/up.$key"
while [ ! -e "$S06/arm" ]; do sleep 0.2; done
back=300; [ $key = K03 ] && back=5
r=$(( $(date +%s) - back )); echo $r >"$S06/reset.$key"
out "$(rej "$r")"
[ $key = K02 ] && out '{"type":"result","subtype":"error_during_execution","result":"You have hit your usage limit"}'
[ $key = K04 ] && { out '{"type":"assistant","message":{"content":[{"type":"text","text":"working again"}]}}'; out '{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}'; }
touch "$S06/armed.$key"
wait
EOF
chmod +x "$tmp/bin06/gh" "$tmp/bin06/claude"
