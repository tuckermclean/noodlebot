# Shared by loop-a07-feedback/-update/-list.test.sh (source after loop-a07.sh): the A07-AC-4 helpers, a spec/adopt* PR of the
# adoption (opened by the fake claude of loop-a07.sh) that the owner comments on or that conflicts with main.
#   a07_branch <name> <branch>      push <branch> to the fake forge's repo.git: main plus one commit (the PR's own work)
#   a07_conflict <name> <n>         the PR's mergeable becomes CONFLICTING in the fake forge
#   a07_comment <name> <n> <id> <body>   the owner's (acme) conversation comment on PR n
#   a07_pr_started <n>              the fake claude logged a start for <n>'s update or feedback ("pr.<n> run 1 ...")
# a07_unit_pr <kind> <key> <n> <branch>: start a loop on a graph of <kind> (none: scaffold; two: area one), hold nothing, wait for
# the unit's WAITING-PR (session over, its worktree removed), then push <branch> so that the PR's branch exists on origin.
a07_branch() {
	local w=$A07/wb.$1
	rm -rf "$w"; git clone -q "$G04/fk/$1/repo.git" "$w" 2>/dev/null
	git -C "$w" checkout -q -b "$2"
	echo "work of $2" >"$w/adopt-work.txt"
	git -C "$w" add -A
	git -C "$w" -c user.name=t -c user.email=t@t commit -q -m "work of $2"
	git -C "$w" push -q origin "$2"
	rm -rf "$w"
}
a07_conflict() {
	python3 -I -c 'import json, os, sys
p = os.path.join(sys.argv[1], "prs.json")
d = json.load(open(p))
for x in d:
    if x["number"] == int(sys.argv[2]): x["mergeable"] = "CONFLICTING"
json.dump(d, open(p + ".tmp", "w")); os.replace(p + ".tmp", p)' "$G04/fk/$1" "$2"
}
a07_comment() {
	python3 -I -c 'import json, os, sys
p = os.path.join(sys.argv[1], "comments.json")
try: d = json.load(open(p))
except OSError: d = {}
d.setdefault(sys.argv[2], []).append({"id": int(sys.argv[3]), "body": sys.argv[4], "created_at": "2026-06-01T14:00:00Z",
    "author": {"login": "acme", "is_bot": False, "is_owner": True}})
json.dump(d, open(p + ".tmp", "w")); os.replace(p + ".tmp", p)' "$G04/fk/$1" "$2" "$3" "$4"
}
a07_pr_started() { a07_logged "^pr[.]$1 run 1 "; }
# a07_any_start <n> <mode>: any session was started for "--<mode> <n>" (whatever skill: at RED the loop starts a triage)
a07_any_start() { a07_logged " --$2 $1 [|] "; }
a07_unit_pr() {
	local kind=$1 key=$2 n=$3 br=$4
	a07_fork a07
	a07_main a07 "$kind"
	a07_run a07
	need "A07-AC-4 setup: the adoption unit $key opened PR $n and ended (WAITING-PR, its worktree removed)" 20 a07_waiting "$key"
	a07_branch a07 "$br"
}
# a07_pr_session <n> <branch> <mode> <skill-mode text>: the checks shared by an update and a feedback session of PR <n>.
a07_pr_session() {
	local n=$1 br=$2 mode=$3 key=$4 wt u
	wt=$g04data/worktrees/a07/pr-$n u=$st/pr/$n/unattended.md
	chk "A07-AC-4: the session is the adoption skill's /noodlebot:adopt --$mode $n, not a triage" a07_pr_started "$n"
	chk "A07-AC-4: it was started with /noodlebot:adopt --$mode $n" a07_logged "^pr[.]$n run 1 /noodlebot:adopt --$mode $n [|] "
	chk "A07-AC-4: it works in worktrees/<name>/pr-$n" a07_logged "^pr[.]$n run 1 .* [|] $wt [|] "
	chk "A07-AC-4: on the PR's branch $br (the unit's removed worktree no longer holds it)" a07_logged "^pr[.]$n run 1 .* [|] $br\$"
	chk "A07-AC-4: no triage session ran" test -z "$(grep -E ' /noodlebot:triage' "$A07/claude.log")"
	chk "A07-AC-4: no triage unit (issue/) was made" test -z "$(ls "$st/issue" 2>/dev/null)"
	chk "A07-AC-4: the unit's own worktree adopt-$key is gone" test ! -d "$g04data/worktrees/a07/adopt-$key"
	chk "A07-AC-4: the session's state is pr/$n/ (session.pid)" test -s "$st/pr/$n/session.pid"
	chk "A07-AC-4: its prompt (pr/$n/unattended.md) runs /noodlebot:adopt --$mode $n" grep -qF "/noodlebot:adopt --$mode $n" "$u"
	chk "A07-AC-4: its prompt does not run the triage skill" test -z "$(grep -F '/noodlebot:triage' "$u")"
}
