# Facts: tallyho

Read offline from the directory; `issues.json` stood in for `gh issue list --state all` (it holds four
open issues; no closed issues or merged PRs, there being no GitHub). No credential check: a dry run
pushes nothing.

- **Layout.** `bin/tallyho` calls `count_stream` from `lib/count.sh` for each file, or for stdin when no
  file is given. Each row is `lines words bytes name`. `README.md` says it prints "a total row"; the
  code prints none.
- **Tests.** One file, `tests/test_count.sh`, plain POSIX sh. `make test` runs only that file.
- **Commands.** `make test`: passes today. No linter. No `AGENTS.md`/`CLAUDE.md`.
- **CI.** `.github/workflows/ci.yml` runs `make test` on push and pull request (not run here: no CI
  offline; the workflow is read, not observed).
- **Issues.** #1 `--json`, #2 `--top N`, #3 binary files counted as text (bug), #4 `~/.tallyhorc`
  (the body does not say shell or key=value).
- **Test paths vs the guard's defaults.** Tests live in `tests/`, which the defaults (`**/tests/**`)
  match. There is no `fixtures/` directory and no `tests.py`. No `.noodlebot/roles.yaml` is needed.
- **Could not tell.** Scope, order, what is done, constraints, the formats the issues leave open.
