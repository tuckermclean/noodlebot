# Facts: the --area dry run (wrapit, area `wrap`)

Recorded offline on the baseline example's repository (the `wrapit` fixture, `testdata/baseline/repo/`; `example-baseline/` holds the drafts of its first PR), after its
first PR: the graph there has `nodes: []` and the areas still to map. The area `wrap` (`lib/`, `bin/` and
`README.md`) was mapped; the graph keeps the areas `tests` and `build`.

- **Input.** The fixture `testdata/baseline/repo/` copied to a scratch folder, `vendor/` added, `git init` and
  `git add -f -A`. The baseline's `docs/graph.yaml` (gate `make test`, `known_red: t_narrow`, `vendor/` out of
  scope) was the starting graph.
- **Commands.** `inventory.py --json --glob <glob> <copy>` for each of the area's globs, then
  `nodes.py`. Offline it prints an empty `ids in use:`, `IDs in open spec PRs: unknown ...; no next free ID`
  and exits 1: a dry run has no forge, so it cannot list the open spec PRs. A real run would stop there; the dry
  run assumes no open spec PR, and because the graph has `nodes: []` it picked the unused letter `W` for the
  area and numbered `W01`, `W02`. The nodes were written by reading `lib/wrap.sh`, `bin/wrap`, `README.md` and
  the tests; of the repository's commands none was run (no test, no gate); that
  `tests/t_narrow.sh`, which no *Verify:* names, fails is the baseline's `known_red`, not a result of this run.
- **Checks.** `check-regime.py --root <copy>` and `check-coverage.py --root <copy>` ended `PROBLEMS 0`. The first PR's drafts committed as `origin/main`, the area's drafts
  committed on top, `check-spec-diff.py origin/main HEAD` printed `spec files: SPEC.md docs/graph.yaml nodes/`,
  `from: AGENTS.md at origin/main` and exited 0.
- **Left unpinned.** The long-word behaviour (W01-AC-3), blank lines and collapsed spaces (W01-AC-4), the file
  argument, the README and the default width (W02-AC-3 to 5): no test shows them.
