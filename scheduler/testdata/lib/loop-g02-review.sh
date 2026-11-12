# Shared by loop-g02-review*.test.sh (source after loop-g02.sh): the fixture of the slice 1f cases (nodes N30..N36, PRs 250..256).
# ---- G02 (fourth review, slice 1f): review1d findings 1-5 ----
# Nodes N30..N36 (PRs 250..256); N30's branch and main both change the file f, so a merge of origin/main
# into it conflicts. The wrapper g02_bin3/claude merges origin/main in its cwd when $G02_GD/conflict.<key>
# exists, and commits there on run n when commit.<key>.<n> exists, then runs the fake claude above.
sed -i 's/ [A-Z]*$/ MERGEABLE/' "$G02_GD/prs.tsv"
g02g fetch -q "$G02/remote.git" main && g02g reset -q --hard FETCH_HEAD
printf '  - {id: N30, name: aa, deps: []}\n  - {id: N31, name: bb, deps: []}\n  - {id: N32, name: cc, deps: []}\n  - {id: N33, name: dd, deps: []}\n' >>"$G02/work/docs/graph.yaml"
printf '  - {id: N34, name: ee, deps: []}\n  - {id: N35, name: ff, deps: []}\n  - {id: N36, name: gg, deps: []}\n' >>"$G02/work/docs/graph.yaml"
g02g commit -q -a -m "graph: N30..N36" && g02g push -q "$G02/remote.git" main
for g02_i in 30:aa 31:bb 32:cc 33:dd 34:ee 35:ff 36:gg; do
	g02g checkout -q -b "node/N${g02_i%%:*}-${g02_i#*:}" main
	[ "${g02_i%%:*}" = 30 ] && { echo branch >"$G02/work/f"; g02g add f; }
	g02g commit -q --allow-empty -m "node ${g02_i%%:*}" && g02g push -q "$G02/remote.git" "node/N${g02_i%%:*}-${g02_i#*:}"; g02g checkout -q main
done
echo main >"$G02/work/f"; g02g add f; g02g commit -q -m "main changes f" && g02g push -q "$G02/remote.git" main
# every node of this part has an open PR from the start (so no node session of its own starts); each case turns its PR CONFLICTING
printf '250 node/N30-aa app/noodlebot true MERGEABLE\n251 node/N31-bb app/noodlebot true MERGEABLE\n252 node/N32-cc app/noodlebot true MERGEABLE\n253 node/N33-dd app/noodlebot true MERGEABLE\n254 node/N34-ee app/noodlebot true MERGEABLE\n255 node/N35-ff app/noodlebot true MERGEABLE\n256 node/N36-gg app/noodlebot true MERGEABLE\n' >>"$G02_GD/prs.tsv"
mkdir -p "$G02/bin3"
cat >"$G02/bin3/claude" <<'EOT'
#!/bin/sh
k=${2##* }; n=$(( $(cat "$G02_GD/runs.$k" 2>/dev/null || echo 0) + 1 ))
if [ -e "$G02_GD/commit.$k.$n" ]; then
	echo m >"local-$k-$n.txt"; git add "local-$k-$n.txt"; git -c user.name=t -c user.email=t@t commit -q -m "local commit of run $n"
fi
[ -e "$G02_GD/conflict.$k" ] && git -c user.name=t -c user.email=t@t merge origin/main >/dev/null 2>&1
exec "$G02_GD/../bin/claude" "$@"
EOT
chmod +x "$G02/bin3/claude"
g02b_loop() {   # g02b_loop <SCHED_MAX> <data root> <SCHED_RAMP>: the wrapper first on PATH
	rm -f "$HOME/STOP-g02"
	NOODLEBOT_DATA=$2 PATH=$G02/bin3:$G02/bin:$PATH SCHED_RAMP=$3 SCHED_START_GAP=0 SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 SCHED_MAX=$1 \
		bash "$G02/nb/scheduler/loop.sh" o/g02 >>"$G02/loop.out" 2>&1 &
	pids+=("$!"); g02_lp=$!
}
g02_fetchrepo() { git -C "$g02_data/repos/g02" fetch -q origin; }
