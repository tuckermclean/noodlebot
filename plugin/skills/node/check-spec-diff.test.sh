#!/bin/sh
# Tests plugin/skills/node/check-spec-diff.py (G05-AC-1): a fixture repository with commits on main and branches.
#   sh plugin/skills/node/check-spec-diff.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$src/../../.." && pwd -P)
chk="$src/check-spec-diff.py"
tmp=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$tmp"' EXIT
d="$tmp/G05"; mkdir -p "$d"
fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# g() <repo> <git args>: quiet git in the fixture.
g() { r=$1; shift; git -C "$r" "$@" >/dev/null 2>&1; }
# put <repo> <path> <text>: write a file (creating folders).
put() { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" >"$1/$2"; }
# mkrepo <name> <agents-spec-line or empty>: a repository on main with spec and other files.
mkrepo() {
	r="$d/$1"; mkdir -p "$r"
	git -C "$r" init -q -b main >/dev/null 2>&1
	put "$r" SPEC.md base
	put "$r" docs/graph.yaml base
	put "$r" docs/other.md base
	put "$r" nodes/N01-x.md base
	put "$r" nodes/N02-y.md base
	put "$r" scripts/run.sh base
	put "$r" scripts/old.sh base
	put "$r" scripts/mv.sh base
	put "$r" t/a.test.sh base
	put "$r" notes/one.md base
	{
		printf '# Agents\n\n## Other\n\nx\n\n## Building a node\n\nText.\n\n'
		[ -n "$2" ] && printf '%s\n\n' "$2"
		printf '## After\n\ny\n'
	} >"$r/AGENTS.md"
	g "$r" add -A; g "$r" commit -q -m base
}
# br <repo> <branch>: a branch from main.
br() { g "$1" checkout -q main; g "$1" checkout -q -b "$2"; }
# cm <repo>: add everything and commit.
cm() { g "$1" add -A; g "$1" commit -q -m c; }

# run <repo> <args...>: sets rc, out (stdout), nots (the NOT SPEC lines, sorted).
run() {
	r=$1; shift
	if [ ! -f "$chk" ]; then rc=127; out=""; nots=""; return; fi
	out=$(python3 -I "$chk" --repo "$r" "$@" 2>"$d/err"); rc=$?
	nots=$(printf '%s\n' "$out" | grep '^NOT SPEC ' | sort)
}
# expect <id> <what> <rc> <expected NOT SPEC lines, newline-joined>
expect() {
	if [ "$rc" = "$3" ] && [ "$nots" = "$4" ]; then ok "$1: $2"
	else bad "$1: $2 (exit $rc, want $3; NOT SPEC lines: [$(printf '%s' "$nots" | tr '\n' '|')], want [$(printf '%s' "$4" | tr '\n' '|')])"; fi
}
nl='
'
[ -f "$chk" ] && ok "G05-AC-1: check-spec-diff.py exists" || bad "G05-AC-1: plugin/skills/node/check-spec-diff.py exists"

# ---- default list (no Spec files line)
mkrepo dflt ""
R="$d/dflt"
br "$R" spec-only
put "$R" SPEC.md changed; put "$R" docs/graph.yaml changed; put "$R" nodes/N01-x.md changed; put "$R" nodes/new/deep.md new; cm "$R"
run "$R" main spec-only
expect G05-AC-1 "default list: only SPEC.md, docs/graph.yaml and files under nodes/ exits 0" 0 ""

br "$R" mixed
put "$R" SPEC.md changed; put "$R" nodes/N01-x.md changed
put "$R" t/a.test.sh changed; put "$R" scripts/run.sh changed; cm "$R"
put "$R" scripts/run.sh changed-again; put "$R" t/a.test.sh changed-again; cm "$R"
run "$R" main mixed
expect G05-AC-1 "a test file and a script changed: exit 1, each named once, no spec file named" 1 "NOT SPEC scripts/run.sh${nl}NOT SPEC t/a.test.sh"
case $out in *"NOT SPEC SPEC.md"*|*"NOT SPEC nodes/"*) bad "G05-AC-1: spec files are not named as NOT SPEC" ;; *) [ "$rc" = 1 ] && ok "G05-AC-1: spec files are not named as NOT SPEC" || bad "G05-AC-1: spec files are not named as NOT SPEC (exit $rc)" ;; esac

br "$R" other-docs
put "$R" docs/other.md changed; put "$R" docs/graph.yaml changed; cm "$R"
run "$R" main other-docs
expect G05-AC-1 "default list: docs/other.md is outside, docs/graph.yaml inside" 1 "NOT SPEC docs/other.md"

# ---- deleted and renamed paths
br "$R" deleted
g "$R" rm -q scripts/old.sh; g "$R" rm -q nodes/N02-y.md; cm "$R"
run "$R" main deleted
expect G05-AC-1 "a deleted script is judged (deleted spec file is not named)" 1 "NOT SPEC scripts/old.sh"

br "$R" del-spec
g "$R" rm -q nodes/N02-y.md; g "$R" rm -q SPEC.md; cm "$R"
run "$R" main del-spec
expect G05-AC-1 "deleting only spec files exits 0" 0 ""

br "$R" renamed
g "$R" mv scripts/mv.sh nodes/mv.sh; g "$R" mv nodes/N01-x.md lib-x.md; cm "$R"
run "$R" main renamed
expect G05-AC-1 "renames are judged by both names (script moved into nodes/, node moved out)" 1 "NOT SPEC lib-x.md${nl}NOT SPEC scripts/mv.sh"

br "$R" renamed-spec
g "$R" mv SPEC.md nodes/SPEC-old.md; cm "$R"
run "$R" main renamed-spec
expect G05-AC-1 "a rename between two spec paths exits 0" 0 ""

# ---- the Spec files line at <from>
mkrepo lined '- **Spec files:** `SPEC.md`, `docs/`, `notes/one.md`.'
R="$d/lined"
br "$R" listed
put "$R" docs/other.md changed; put "$R" docs/new/z.md new; put "$R" notes/one.md changed; put "$R" SPEC.md changed; cm "$R"
run "$R" main listed
expect G05-AC-1 "line at <from>: a listed file and a listed folder pass" 0 ""
br "$R" notlisted
put "$R" nodes/N01-x.md changed; put "$R" docs/graph.yaml changed; put "$R" notes/two.md new; cm "$R"
run "$R" main notlisted
expect G05-AC-1 "line at <from>: the default list does not apply (nodes/ outside, notes/two.md outside)" 1 "NOT SPEC nodes/N01-x.md${nl}NOT SPEC notes/two.md"

mkrepo fewer '- **Spec files:** `SPEC.md`.'
F="$d/fewer"
br "$F" listed
put "$F" docs/other.md changed; put "$F" docs/new/z.md new; put "$F" notes/one.md changed; put "$F" SPEC.md changed; cm "$F"
run "$F" main listed
expect G05-AC-1 "the same branch with the line naming fewer files fails" 1 "NOT SPEC docs/new/z.md${nl}NOT SPEC docs/other.md${nl}NOT SPEC notes/one.md"

# ---- a branch that adds or widens the line is judged by the list at <from>
br "$R" widen
put "$R" AGENTS.md "$(sed 's|`notes/one.md`|`notes/one.md`, `scripts/`, `AGENTS.md`|' "$R/AGENTS.md")"
put "$R" scripts/run.sh changed; cm "$R"
run "$R" main widen
expect G05-AC-1 "a branch widening the line is judged by the list at <from>" 1 "NOT SPEC AGENTS.md${nl}NOT SPEC scripts/run.sh"

R="$d/dflt"
br "$R" adds-line
put "$R" AGENTS.md "$(sed 's|^Text\.$|Text.\n\n- **Spec files:** `SPEC.md`, `AGENTS.md`, `scripts/`.|' "$R/AGENTS.md")"
put "$R" scripts/run.sh changed; put "$R" SPEC.md changed; cm "$R"
run "$R" main adds-line
expect G05-AC-1 "a branch adding the line is judged by the list at <from> (AGENTS.md and scripts/ outside)" 1 "NOT SPEC AGENTS.md${nl}NOT SPEC scripts/run.sh"

# ---- --allow
br "$R" allow
put "$R" AGENTS.md "changed"; put "$R" SPEC.md changed; cm "$R"
run "$R" main allow
expect G05-AC-1 "without --allow, AGENTS.md is outside the default list" 1 "NOT SPEC AGENTS.md"
run "$R" --allow AGENTS.md main allow
expect G05-AC-1 "--allow AGENTS.md adds the path (exit 0)" 0 ""
br "$R" allow2
put "$R" AGENTS.md "changed"; put "$R" scripts/run.sh changed; put "$R" t/a.test.sh changed; cm "$R"
run "$R" --allow AGENTS.md --allow t/a.test.sh main allow2
expect G05-AC-1 "--allow may repeat; other paths are still named" 1 "NOT SPEC scripts/run.sh"

# ---- a squash commit is checked as <sha>^ <sha>
g "$R" checkout -q main
put "$R" SPEC.md squash1; put "$R" nodes/N01-x.md squash1; cm "$R"
s1=$(git -C "$R" rev-parse HEAD 2>/dev/null)
put "$R" SPEC.md squash2; put "$R" scripts/run.sh squash2; put "$R" t/b.test.sh new; cm "$R"
s2=$(git -C "$R" rev-parse HEAD 2>/dev/null)
run "$R" "$s1^" "$s1"
expect G05-AC-1 "a squash commit of spec files only checks as <sha>^ <sha> (exit 0)" 0 ""
run "$R" "$s2^" "$s2"
expect G05-AC-1 "a squash commit with a script and a test checks as <sha>^ <sha> (exit 1)" 1 "NOT SPEC scripts/run.sh${nl}NOT SPEC t/b.test.sh"

# ---- a git failure exits 2 with nothing on stdout
run "$R" main no-such-branch-or-commit
if [ "$rc" = 2 ] && [ -z "$out" ]; then ok "G05-AC-1: an unknown commit exits 2 with empty stdout"
else bad "G05-AC-1: an unknown commit exits 2 with empty stdout (exit $rc, stdout [$out])"; fi
run "$d/not-a-repository" main spec-only
if [ "$rc" = 2 ] && [ -z "$out" ]; then ok "G05-AC-1: a directory that is no repository exits 2 with empty stdout"
else bad "G05-AC-1: a directory that is no repository exits 2 with empty stdout (exit $rc, stdout [$out])"; fi

# ---- the script names no repository; this repository's AGENTS.md has the line
if [ ! -f "$chk" ]; then bad "G05-AC-1: the script names no repository (script missing)"
elif grep -iqE 'themonolith|tuckermclean|noodlebot|migration\.tsv' "$chk"; then bad "G05-AC-1: the script names no repository"
else ok "G05-AC-1: the script names no repository"; fi

sect=$(awk '/^## /{ if (on) exit; if (tolower($0) ~ /^## building a node/) on = 1 } on { print }' "$root/AGENTS.md")
line=$(printf '%s\n' "$sect" | grep -F '**Spec files:**' | head -n 1)
miss=""
for p in '`SPEC.md`' '`docs/graph.yaml`' '`nodes/`'; do
	case $line in *"$p"*) ;; *) miss="$miss $p" ;; esac
done
if [ -n "$line" ] && [ -z "$miss" ]; then ok "G05-AC-1: AGENTS.md's \"Building a node\" section has a **Spec files:** line naming SPEC.md, docs/graph.yaml, nodes/"
else bad "G05-AC-1: AGENTS.md's \"Building a node\" section has a **Spec files:** line naming SPEC.md, docs/graph.yaml, nodes/ (line: [$line], missing:$miss)"; fi

# ---- three-dot diff: a commit on main after the branch was cut is not the branch's change
mkrepo three ""
T="$d/three"
br "$T" spec-only
put "$T" SPEC.md changed; cm "$T"
g "$T" checkout -q main
put "$T" scripts/run.sh main-moved-on; cm "$T"
run "$T" main spec-only
expect G05-AC-1 "three-dot diff: a script changed on main after the branch was cut is not named (exit 0)" 0 ""
if grep -q 'scripts/run.sh' "$d/err"; then bad "G05-AC-1: three-dot diff: no error output naming main's script"; fi

# ---- this repository's Spec files line has exactly the three backticked items
items=$(printf '%s\n' "$line" | grep -o '`[^`]*`' | tr '\n' ' ')
if [ -n "$line" ] && [ "$items" = '`SPEC.md` `docs/graph.yaml` `nodes/` ' ]; then ok "G05-AC-1: AGENTS.md's Spec files line has exactly the backticked items SPEC.md, docs/graph.yaml, nodes/"
else bad "G05-AC-1: AGENTS.md's Spec files line has exactly the backticked items SPEC.md, docs/graph.yaml, nodes/ (got: $items)"; fi

# ---- a changed path that is not valid UTF-8
mkrepo u8 ""
U="$d/u8"
br "$U" bad-outside
badname=$(printf 'scripts/bad\377name.sh')
if ! { printf 'x\n' >"$U/$badname"; } 2>/dev/null || [ ! -f "$U/$badname" ]; then
	bad "G05-AC-1: non-UTF-8 path: the filesystem refused to create a file named with byte 0xff"
else
	cm "$U"
	run "$U" main bad-outside
	cnt=$(printf '%s\n' "$out" | LC_ALL=C grep -a -c '^NOT SPEC ')
	if [ "$rc" = 1 ] && [ "$cnt" = 1 ] && ! grep -q Traceback "$d/err"; then ok "G05-AC-1: a non-UTF-8 path outside the spec files exits 1 with one NOT SPEC line, no traceback"
	else bad "G05-AC-1: a non-UTF-8 path outside the spec files exits 1 with one NOT SPEC line, no traceback (exit $rc, NOT SPEC lines $cnt, stderr: $(head -c 300 "$d/err" | tail -n 1))"; fi
	br "$U" bad-inside
	mkdir -p "$U/nodes"; printf 'x\n' >"$U/nodes/$(printf 'bad\377name.md')"; cm "$U"
	run "$U" main bad-inside
	cnt=$(printf '%s\n' "$out" | LC_ALL=C grep -a -c '^NOT SPEC ')
	if [ "$rc" = 0 ] && [ "$cnt" = 0 ] && ! grep -q Traceback "$d/err"; then ok "G05-AC-1: a non-UTF-8 path inside nodes/ exits 0"
	else bad "G05-AC-1: a non-UTF-8 path inside nodes/ exits 0 (exit $rc, NOT SPEC lines $cnt, stderr: $(head -c 300 "$d/err" | tail -n 1))"; fi
fi

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all check-spec-diff checks passed"
