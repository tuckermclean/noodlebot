# SPEC: wrapit

## What this is
wrapit folds lines of text to a width: `bin/wrap [-w N] [file]` reads a file or standard input and prints
each line broken at spaces so that no line is longer than N characters (default 20). It is not a text
formatter: no hyphenation, no justification, no languages.

## Principles
- POSIX sh and awk only; no new dependencies.
- Every behaviour gets a test in `tests/`.

## State
Folding at spaces and `-w` are done and tested. Splitting a word longer than the width is not started; its test
`t_narrow` fails today and is listed as known red in the graph's gate until a change fixes it.

## Architecture
`bin/wrap` reads the options and calls `wrap_line` from `lib/wrap.sh`, an awk filter. The tests in `tests/` are
run by `sh tests/run.sh` (`make test`). Third-party code in `vendor/` is out of scope.

## The regime
The graph (`docs/graph.yaml`) holds the gate (the test command and the failures it already had), the paths out of
scope, and the adoption areas: `wrap`, `tests` and `build`. It lists no node yet: the areas are mapped into
nodes, and open issues become nodes, in later pull requests.

## Node spec template
A node spec `nodes/<ID>-<name>.md` has the headings Purpose, Tests, Changes, Gate and Risks, a header row
`| Track | Deps | Unlocks | Size |`, an **Owns:** line, and criteria `- **<ID>-AC-<n>** — … *Verify:* …`.

## Open decisions
None.

## Conventions
Branches `node/<ID>-<name>` and `spec/<topic>`; sizes S (under a day), M (two or three), L (more); a node is done
when its gate passes in CI and its PR is merged.
