#!/bin/sh
# Tests scheduler/feedback.py (G06-AC-4): an open-PR list as long as the loop's limit may be cut short, so the record
# and FEEDBACK.md of a PR missing from it are kept; a shorter list is whole, and they are removed (G03-AC-2).
#   sh scheduler/feedback-g06.test.sh   (make test)
#
# The command-line interface this file fixes, on top of feedback.test.sh's (which keeps working unchanged):
#   python3 -I feedback.py --repo O/N --state DIR --owner LOGIN --prs FILE [--limit N]        find new feedback
#   python3 -I feedback.py --repo O/N --state DIR --owner LOGIN --prs FILE [--limit N] mark K  advance PR K's record
#  * --limit N is the loop's `gh pr list --limit` (500 in the loop). The loop passes it as an option BEFORE `mark`
#    (options first: argparse of CI's python 3.12.3 is fussy about options after a positional).
#  * When FILE has N lines or more (wc -l of open-prs.tsv >= N), the list may be cut short: no record DIR/feedback/K
#    and no DIR/feedback/K.md (also K.next) of a PR missing from FILE is removed. Everything else is as without --limit.
#  * FILE with fewer than N lines is whole: a PR missing from it loses both files, as without --limit.
#  * Without --limit nothing changes: a PR missing from FILE loses both files.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

G06=$tmp/G06
data=$G06/data
mkdir -p "$G06/bin"
cp -R "$src/testdata/feedback" "$data"
export FB_DATA=$data
cat >"$G06/bin/gh" <<'EOS'
#!/bin/sh
# fake gh: only `gh api --paginate repos/o/r/(issues|pulls)/N/(comments|reviews)`, served from $FB_DATA.
[ "$1" = api ] && [ "$2" = --paginate ] && [ $# -eq 3 ] || { echo "fake gh: unexpected: $*" >&2; exit 2; }
case $3 in
repos/o/r/issues/*/comments | repos/o/r/pulls/*/comments | repos/o/r/pulls/*/reviews) ;;
*) echo "fake gh: unexpected path $3" >&2; exit 2 ;;
esac
f=$(echo "${3#repos/o/r/}" | tr / -)
if [ -f "$FB_DATA/$f.json" ]; then cat "$FB_DATA/$f.json"; else echo '[]'; fi
EOS
chmod +x "$G06/bin/gh"
export PATH=$G06/bin:$PATH
export GH_TOKEN=fake

prs=$data/open-prs.tsv
grep -v '^18 ' "$prs" >"$G06/prs-no18"     # PR 18 (a bot PR) is missing from this list
n_no18=$(wc -l <"$G06/prs-no18")
fb() { python3 -I "$src/feedback.py" --repo o/r --state "$state" --owner owner --prs "$list" "$@"; }

# fresh <dir>: a state dir whose records cover every open PR (the first run), plus a pending FEEDBACK.md file for PR 18.
fresh() {
	state=$1; list=$prs
	mkdir -p "$state"
	fb >/dev/null 2>&1; rc=$?
	printf 'PR: 18\nBranch: node/N18-x\n' >"$state/feedback/18.md"
}
# a keep only counts when feedback.py ran fine (rc 0), not when it died on an option it does not know
have18() { [ "${rc:-1}" = 0 ] && [ -e "$state/feedback/18" ] && [ -s "$state/feedback/18.md" ]; }
gone18() { [ "${rc:-1}" = 0 ] && [ ! -e "$state/feedback/18" ] && [ ! -e "$state/feedback/18.md" ]; }

# --- a list as long as the limit -------------------------------------------------------------------------------
fresh "$G06/a"
ok "G06-AC-4 setup: the first run records PR 18 and its FEEDBACK.md exists" have18
list=$G06/prs-no18
fb --limit "$n_no18" >/dev/null 2>"$G06/err"; rc=$?
ok "G06-AC-4: a list as long as --limit (PR 18 missing) is read, exit 0" test "$rc" = 0
ok "G06-AC-4: the record feedback/18 of the missing PR is kept" test "$rc" = 0 -a -e "$state/feedback/18"
ok "G06-AC-4: the FEEDBACK.md file feedback/18.md of the missing PR is kept" test "$rc" = 0 -a -s "$state/feedback/18.md"
ok "G06-AC-4: the records of the PRs in the list stay too" test "$rc" = 0 -a -e "$state/feedback/17" -a -e "$state/feedback/11"
fb --limit "$n_no18" >/dev/null 2>&1; rc=$?
ok "G06-AC-4: a second run with the long list keeps them still" have18
fb --limit "$n_no18" mark 11 >/dev/null 2>&1; rc=$?
ok "G06-AC-4: mark with --limit exits 0" test "$rc" = 0
ok "G06-AC-4: mark with a long list keeps the missing PR's files" have18

# a longer list than the limit counts as cut short too
fresh "$G06/b"; list=$G06/prs-no18
fb --limit $((n_no18 - 1)) >/dev/null 2>&1; rc=$?
ok "G06-AC-4: a list longer than --limit is cut short as well: the missing PR's record and file are kept" have18

# --- a shorter list -----------------------------------------------------------------------------------------------
fresh "$G06/c"; list=$G06/prs-no18
fb --limit $((n_no18 + 1)) >/dev/null 2>"$G06/err"; rc=$?
ok "G06-AC-4: a list shorter than --limit is read, exit 0" test "$rc" = 0
ok "G06-AC-4: given a shorter list, the record and FEEDBACK.md file of the missing PR are removed" gone18
ok "G06-AC-4: the records of the PRs in the list stay" test "$rc" = 0 -a -e "$state/feedback/17" -a -e "$state/feedback/11"

# --- without --limit: as before ----------------------------------------------------------------------------------
fresh "$G06/d"; list=$G06/prs-no18
fb >/dev/null 2>&1; rc=$?
ok "G06-AC-4: without --limit the missing PR's record and file are removed as before" gone18

[ "$fails" -eq 0 ] || { echo "$fails FAILED"; exit 1; }
echo "all passed"
