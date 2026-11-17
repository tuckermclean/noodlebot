#!/bin/sh
# Tests that no script prints an error for a file that may be missing (S11-AC-2):  sh scheduler/quiet-reads.test.sh   (make test)
#
# The bug: in  cmd <"$f" 2>/dev/null  the input redirection fails before 2>/dev/null applies, so a missing file prints an
# error on every tick. The check is textual, per line. Non-test scripts = every *.sh under scheduler/ except *.test.sh
# and scheduler/testdata/. A line fails when a file input redirection (< word, not << heredoc, not <( or < <( process
# substitution, not <&) is followed by 2>/dev/null with nothing but other redirections between (this covers a group
# redirection, { ...; } <"f" 2>/dev/null). Not the bug, so passed: 2>/dev/null before the <, a process substitution whose
# own command is silenced, and a group silenced as a whole ({ ... <"f"; } 2>/dev/null). A redirection split over lines or
# built in a variable escapes the check (the reviewer reads those).
# Also: fu_branch, extracted by name from scheduler/loop.sh (the whole loop is not run), on a node folder without
# FOLLOWUP fails with empty stderr and, with one, prints its branch.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$src/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

cat >"$tmp/scan.py" <<'PY'
import os, re, sys

root = sys.argv[1]
WORD = r"""(?:"[^"]*"|'[^']*'|[^\s<>|;&()"']+)"""
REDIR = r"(?:\d*>>?&?[^\s|;&()<>]*|\d*<[^\s<(&][^\s|;&()<>]*)"
BUG = re.compile(r"(?<![<>&])<\s*" + WORD + r"(?:\s+" + REDIR + r")*\s+2>/dev/null(?![\w/])")
n = 0
for dp, dn, fns in os.walk(os.path.join(root, "scheduler")):
    dn[:] = sorted(d for d in dn if os.path.relpath(os.path.join(dp, d), root) != "scheduler/testdata")
    for fn in sorted(fns):
        if not fn.endswith(".sh") or fn.endswith(".test.sh"):
            continue
        full = os.path.join(dp, fn)
        rel = os.path.relpath(full, root)
        n += 1
        with open(full, encoding="utf-8", errors="replace") as f:
            for no, line in enumerate(f, 1):
                if line.lstrip().startswith("#"):
                    continue
                if BUG.search(line):
                    print("%s:%d: %s" % (rel, no, line.strip()))
print("SCANNED %d" % n, file=sys.stderr)
PY
scan() { python3 -I "$tmp/scan.py" "$1" 2>"$tmp/scan.err"; }

# The tree.
s11_hit=$(scan "$root")
s11_n=$(sed -n 's/^SCANNED //p' "$tmp/scan.err")
if [ "${s11_n:-0}" -ge 5 ]; then pass "S11-AC-2: the scan covers the scripts under scheduler/ (${s11_n})"
else fail "S11-AC-2: the scan found only ${s11_n:-0} scripts under scheduler/"; fi
if [ -z "$s11_hit" ]; then pass "S11-AC-2: no non-test script under scheduler/ silences stderr after an input redirection"
else
	echo "$s11_hit" | while IFS= read -r l; do echo "FAIL: S11-AC-2: ${l%%: *}: input redirection followed by 2>/dev/null (${l#*: })"; done
	fails=$((fails + $(echo "$s11_hit" | wc -l)))
fi

# Planted forms in a scratch copy.
S11="$tmp/S11"
mkdir -p "$S11/scheduler/testdata"
s11_plant() { # <bug|ok> <name> <line>: a script of three lines holding <line> as its line 3
	printf '#!/bin/sh\n# a comment\n%s\n' "$3" >"$S11/scheduler/s11_$2.sh"
	s11_hit=$(scan "$S11")
	if [ "$1" = bug ]; then
		case $s11_hit in
		"scheduler/s11_$2.sh:3:"*) pass "S11-AC-2: planted $2 fails the check, naming scheduler/s11_$2.sh:3" ;;
		*) fail "S11-AC-2: planted $2 not named at scheduler/s11_$2.sh:3 (got: $s11_hit)" ;;
		esac
	else
		if [ -z "$s11_hit" ]; then pass "S11-AC-2: planted $2 passes the check"
		else fail "S11-AC-2: planted $2 was flagged: $s11_hit"; fi
	fi
	rm -f "$S11/scheduler/s11_$2.sh"
}
s11_plant bug subst 'b=$(tr -d " " <"$d/FOLLOWUP" 2>/dev/null) && echo "$b"'
s11_plant bug read 'read -r l <"$HOME/f" 2>/dev/null || l=""'
s11_plant bug bare 'n=$(wc -c <$log 2>/dev/null || echo 0)'
s11_plant bug single "x=\$(cat <'f' 2>/dev/null)"
s11_plant bug other 'cmd <"$f" 9>&- 2>/dev/null'
s11_plant bug pipe 'tr "\0" " " <"/proc/$p/cmdline" 2>/dev/null | grep -q x'
s11_plant bug group '{ if [ a ]; then cat; else sed d; fi; } <"$here/$prompt" 2>/dev/null |'
s11_plant bug group2 '{ cat; } <"$f" 2>/dev/null'
s11_plant ok procsub 'while read -r l; do :; done < <(git -C "$c" worktree list 2>/dev/null)'
s11_plant ok procsub2 'lockmatch "$p" < <(sed -n "s/^lock://p" "$fi" 2>/dev/null) && return 0'
s11_plant ok groupquiet 'x=$({ tr "\0" " " <"/proc/$p/cmdline"; } 2>/dev/null)'
s11_plant ok groupquiet2 '{ cat <"$f"; } 2>/dev/null'
s11_plant ok before 'cmd 2>/dev/null <"$f"'
s11_plant ok heredoc 'cat <<EOT 2>/dev/null'
s11_plant ok plainread 'x=$(cat <"$f")'
s11_plant ok comment '# x=$(cat <"$f" 2>/dev/null)'
# A bug in a test file or under scheduler/testdata/ is not scanned.
printf '#!/bin/sh\ncat <"$f" 2>/dev/null\n' >"$S11/scheduler/s11_x.test.sh"
cp "$S11/scheduler/s11_x.test.sh" "$S11/scheduler/testdata/s11_y.sh"
s11_hit=$(scan "$S11")
if [ -z "$s11_hit" ]; then pass "S11-AC-2: a *.test.sh and a script under scheduler/testdata/ are not scanned"
else fail "S11-AC-2: a test file or testdata script was scanned: $s11_hit"; fi

# fu_branch, taken from scheduler/loop.sh by name: from "fu_branch()" to the line where its braces balance.
awk '
	!on && /^fu_branch\(\)/ { on = 1 }
	on {
		print
		t = $0; o = gsub(/\{/, "", t); c = gsub(/\}/, "", t); depth += o - c
		if (depth <= 0 && (o + c) > 0) exit
	}
' "$root/scheduler/loop.sh" >"$tmp/fu.def"
if [ -s "$tmp/fu.def" ] && bash -c ". '$tmp/fu.def'; type fu_branch >/dev/null" 2>/dev/null; then
	pass "S11-AC-2: fu_branch is found in scheduler/loop.sh"
	mkdir -p "$S11/n/none" "$S11/n/has" "$S11/n/blank"
	printf 'node/X-followup-1\n' >"$S11/n/has/FOLLOWUP"
	printf '  \n' >"$S11/n/blank/FOLLOWUP"
	s11_fu() { bash -c ". '$tmp/fu.def'; fu_branch \"\$1\"" _ "$1" >"$tmp/fu.out" 2>"$tmp/fu.err"; echo $? >"$tmp/fu.rc"; }
	s11_fu "$S11/n/none"
	if [ "$(cat "$tmp/fu.rc")" != 0 ] && [ ! -s "$tmp/fu.out" ]; then pass "S11-AC-2: fu_branch on a node without FOLLOWUP fails with no output"
	else fail "S11-AC-2: fu_branch on a node without FOLLOWUP returned $(cat "$tmp/fu.rc"), stdout '$(cat "$tmp/fu.out")'"; fi
	if [ ! -s "$tmp/fu.err" ]; then pass "S11-AC-2: fu_branch on a node without FOLLOWUP writes nothing to stderr"
	else fail "S11-AC-2: fu_branch on a node without FOLLOWUP wrote to stderr: $(head -c 200 "$tmp/fu.err")"; fi
	s11_fu "$S11/n/has"
	if [ "$(cat "$tmp/fu.rc")" = 0 ] && [ "$(cat "$tmp/fu.out")" = node/X-followup-1 ] && [ ! -s "$tmp/fu.err" ]; then
		pass "S11-AC-2: fu_branch with a FOLLOWUP prints its branch"
	else fail "S11-AC-2: fu_branch with a FOLLOWUP returned $(cat "$tmp/fu.rc"), stdout '$(cat "$tmp/fu.out")', stderr '$(head -c 100 "$tmp/fu.err")'"; fi
	s11_fu "$S11/n/blank"
	if [ "$(cat "$tmp/fu.rc")" != 0 ] && [ ! -s "$tmp/fu.out" ] && [ ! -s "$tmp/fu.err" ]; then pass "S11-AC-2: fu_branch with a blank FOLLOWUP fails with no output"
	else fail "S11-AC-2: fu_branch with a blank FOLLOWUP returned $(cat "$tmp/fu.rc"), stdout '$(cat "$tmp/fu.out")'"; fi
else
	fail "S11-AC-2: fu_branch is not found in scheduler/loop.sh (a function definition starting a line)"
fi

[ "$fails" = 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
