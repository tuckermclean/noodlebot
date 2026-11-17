# Facts: the --area dry run (wrapit, area `wrap`)

Recorded offline on the baseline example's repository (`example-baseline/`, the `wrapit` fixture), after its
first PR: the graph there has `nodes: []` and the areas still to map. The area `wrap` (`lib/`, `bin/` and
`README.md`) was mapped; the graph keeps the areas `tests` and `build`.

- **Input.** The fixture `testdata/baseline/repo/` copied to a scratch folder, `vendor/` added, `git init` and
  `git add -f -A`. The baseline's `docs/graph.yaml` (gate `make test`, `known_red: t_narrow`, `vendor/` out of
  scope) was the starting graph.
- **Commands.** `inventory.py --json --glob <glob> <copy>` for each of the area's globs, then
  `nodes.py` (no letter in use, so the letter `W` was picked for the area and numbered `W01`, `W02`).
  The nodes were written by reading `lib/wrap.sh`, `bin/wrap`, `README.md` and the tests; nothing was run
  but the tests named in each *Verify:*, and `tests/t_narrow.sh` fails as the graph's `known_red` says.
- **Checks.** `check-regime.py --root <copy>` and `check-coverage.py --root <copy>` ended `PROBLEMS 0`.
- **Left unpinned.** The long-word behaviour (W01-AC-3), blank lines and collapsed spaces (W01-AC-4), the file
  argument, the README and the default width (W02-AC-3 to 5): no test shows them.
