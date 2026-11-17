# Shared by scheduler/loop-a07-e2e.test.sh (source after loop-a07.sh, never changing its lines): the end-to-end fixture of the
# A07 adoption. The repository is A06's fixture repository (plugin/skills/adopt/testdata/baseline/repo) with no graph on
# main; the fake claude acts as each adoption session would, from A06/A07's recorded drafts (example-baseline: SPEC.md,
# AGENTS.md; example-area: the nodes of the wrap area) trimmed to two areas:
#   scaffold  SPEC.md, AGENTS.md, docs/graph.yaml (gate, out_of_scope, adoption.areas wrap and tests, nodes: [])  on spec/adopt
#   wrap      nodes W01, W02 (bin/, lib/, README.md), the area removed                                            on spec/adopt-wrap
#   tests     node W03 (tests/, Makefile, .github/), the area removed (adoption.areas: [])                         on spec/adopt-tests
#   plan      `adoption` removed                                                                                  on spec/adopt-plan
# Each session logs "start <key>" and "end <key>" to $A07/e2e.log, holds 1 s (a second session at the same time would show),
# commits its files on the branch it was started on, pushes it to the fake forge, opens the PR (numbers 21..24) and writes
# WAITING-PR. a07e_merge <key> <pr>: the owner merges the PR: main of the fake forge is fast-forwarded to the unit's branch.
#   a07e_seed <name>     the fixture repository's files on main of the fake forge a07_fork made (still no docs/graph.yaml)
#   a07e_merge <name> <key> <pr>
A07E=$A07/e2e
ad=$src/../plugin/skills/adopt
mkdir -p "$A07E"
a07e_graph() {
	cat <<'EOF3'
template: {headings: [Purpose, Tests, Changes, Gate, Risks]}
gate:
  command: make test
  fail_pattern: '^FAIL '
  known_red:
    - t_narrow
out_of_scope:
  - {glob: "vendor/", reason: "vendored third-party code, not ours, never changed here"}
EOF3
	case $1 in
	scaffold) printf 'adoption:\n  areas:\n    - {name: wrap, globs: ["bin/", "lib/", "README.md"]}\n    - {name: tests, globs: ["tests/", "Makefile", ".github/"]}\nnodes: []\n' ;;
	wrap) printf 'adoption:\n  areas:\n    - {name: tests, globs: ["tests/", "Makefile", ".github/"]}\n' ;;
	tests) printf 'adoption:\n  areas: []\n' ;;
	plan) ;;
	esac
	case $1 in
	scaffold) return 0 ;;
	esac
	cat <<'EOF3'
nodes:
  - id: W01
    name: wrap-lib
    deps: []
    track: done
    status: imported
    owns: ["lib/wrap.sh"]
    summary: "wrap_line folds standard input at spaces so that no line exceeds a width, except a single word longer than the width."
  - id: W02
    name: wrap-command
    deps: [W01]
    track: done
    status: imported
    owns: ["bin/wrap", "README.md"]
    summary: "bin/wrap [-w N] [file] reads a file or standard input and prints it folded to N characters (default 20), and the README that documents it."
EOF3
	case $1 in
	wrap) return 0 ;;
	esac
	cat <<'EOF3'
  - id: W03
    name: wrap-tests
    deps: []
    track: done
    status: imported
    owns: ["tests/", "Makefile", ".github/"]
    summary: "the test runner and the three tests, make test, and the CI workflow that runs it."
EOF3
}
a07e_w03() {
	cat <<'EOF3'
# W03 — wrap-tests

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| done | none | none | S |

**Owns:** `tests/`, `Makefile`, `.github/`

## Purpose

Imported from the code. `tests/run.sh` runs the test files `tests/t_*.sh`, `make test` runs it, and the `ci` workflow
runs `make test` on a pull request.

## Tests

Existing: `tests/t_basic.sh`, `tests/t_fold.sh` and `tests/t_narrow.sh` (it fails today and is listed in the graph's `known_red`).

## Changes

none: imported

## Gate

- **W03-AC-1** — `make test` runs every test file under `tests/` and prints `FAIL <name>` for each that fails. *Verify:* `make test`.

## Risks

- `tests/t_narrow.sh` fails today; a node that fixes it removes it from `known_red`.
EOF3
}
# a07e_files <key> <checkout>: the unit's files laid into the checkout.
a07e_files() {
	local k=$1 w=$2
	mkdir -p "$w/docs" "$w/nodes"
	a07e_graph "$k" >"$w/docs/graph.yaml"
	case $k in
	scaffold) cp "$ad/example-baseline/SPEC.md" "$ad/example-baseline/AGENTS.md" "$w/" ;;
	wrap) cp "$ad/example-area/nodes/W01-wrap-lib.md" "$ad/example-area/nodes/W02-wrap-command.md" "$w/nodes/" ;;
	tests) a07e_w03 >"$w/nodes/W03-wrap-tests.md" ;;
	esac
}
export A07E_AD=$ad
a07e_fixture() {
	{ declare -f a07e_graph a07e_w03 a07e_files; echo "ad=$ad"; } >"$A07E/files.sh"
}
a07e_fixture
cat >"$G04/bin/claude" <<'EOF2'
#!/bin/bash
p=$2
case "$p" in
"/noodlebot:adopt --area "*) k=${p#/noodlebot:adopt --area }; k=${k%% *} ;;
"/noodlebot:adopt --plan"*) k=plan ;;
"/noodlebot:adopt "*) k=scaffold ;;
*) k=other ;;
esac
echo "$k run $(( $(grep -c "^$k run" "$A07_DIR/claude.log" 2>/dev/null) + 1 )) $p | $(pwd -P) | $(git branch --show-current 2>/dev/null)" >>"$A07_DIR/claude.log"
echo "start $k" >>"$A07_DIR/e2e.log"
case $k in scaffold) head=spec/adopt; num=21 ;; wrap) head=spec/adopt-wrap; num=22 ;; tests) head=spec/adopt-tests; num=23 ;; plan) head=spec/adopt-plan; num=24 ;; *) exit 0 ;; esac
. "$A07_DIR/e2e/files.sh"
sleep 1
a07e_files "$k" "$(pwd -P)"
git add -A
git -c user.name=t -c user.email=t@t commit -q -m "adopt $k"
git push -q origin "HEAD:$head"
python3 "$A07_DIR/forge.py" pr "$A07_FK" "$num" "$head"
echo "$num" >"$A07_STATE/adopt/$k/WAITING-PR"
echo "end $k" >>"$A07_DIR/e2e.log"
exit 0
EOF2
chmod +x "$G04/bin/claude"
a07e_seed() {
	local w=$A07/w.seed
	rm -rf "$w"; git clone -q "$G04/fk/$1/repo.git" "$w" 2>/dev/null
	cp -R "$ad/testdata/baseline/repo/." "$w/"
	git -C "$w" add -A
	git -C "$w" -c user.name=t -c user.email=t@t commit -q -m "the fixture repository"
	git -C "$w" push -q origin HEAD:main
	rm -rf "$w"
}
# a07e_merge <name> <key> <pr>: fast-forward main of the fake forge to the unit's branch, then mark the PR merged.
a07e_merge() {
	local r=$G04/fk/$1/repo.git br=spec/adopt-$2
	[ "$2" = scaffold ] && br=spec/adopt
	git -C "$r" merge-base --is-ancestor refs/heads/main "refs/heads/$br" || return 1
	git -C "$r" update-ref refs/heads/main "refs/heads/$br" && a07_merge "$1" "$3"
}
