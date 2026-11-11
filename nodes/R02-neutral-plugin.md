# R02 — neutral-plugin

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G04, S08 | none | M |

**Owns:** the forge and harness wording of the skills `plugin/skills/*/SKILL.md` (and their fixtures, such as `plugin/skills/adopt/example/`), of the role agents `plugin/agents/*.md` and of the session templates `scheduler/unattended*.md` and `scheduler/limit-resume.md`; the role guard's split into a neutral rule check (`plugin/hooks/guard.py`) and the Claude Code adapter (`plugin/hooks/claude_code.py`, Claude Code's hook input and exit convention), with `plugin/hooks/hooks.json` and `plugin/.claude-plugin/` as the adapter's other files; the plugin rules of `scheduler/agnostic.test.sh`; the plugin's line in `AGENTS.md`'s "Where things are" and the README's plugin wording; their cases in the existing `*.test.sh` files.
**Resolves:** #84

## Purpose
After this node the plugin and the session prompts are neutral too. Every forge operation they ask of a session goes through the forge CLI that G04 gives sessions, and no skill, agent or session template names GitHub, `gh`, Claude Code or Claude Code's tools. `plugin/` holds neutral content plus a small Claude Code adapter, so a backend for another harness adds its own adapter beside it. With R02, a loop on another forge or harness gets working skills, not only a working scheduler.

## Tests
- `scheduler/agnostic.test.sh` (extended): the plugin rules of change 4 pass on the tree and fail, naming file and line, on each planted form in a skill, an agent and a session template.
- `plugin/hooks/guard.test.sh`, `guard-git.test.sh`, `guard-shell.test.sh` (extended): the existing cases pass with their expectations unchanged through the Claude Code adapter, and the same decisions come from calling the neutral check directly with a role, a tool kind (write or shell) and its paths or command.
- The existing tests that check skill and template text (`loop*.test.sh` on rendered prompts, `plugin/skills/adopt/adopt.test.sh`, `plugin/skills/triage/nodes.test.sh`) pass with expectations unchanged except where an expectation names a `gh` command or a Claude Code tool the text no longer has (change 5).
- The recorded dry run of R02-AC-5, in the PR.

## Changes
1. **Forge operations in the texts.** Every `gh` command and `github.com` URL in the skills, the adopt skill's fixtures and the session templates becomes the matching forge CLI command (`"$NOODLEBOT_FORGE" pr create ...`, `... issue view ...`, `... push`), and the rule "a fresh token per command" becomes "every forge operation goes through the forge CLI, which fetches credentials itself". The closing-keyword rule stays, worded for any forge. *R02-AC-1, R02-AC-2.*
2. **Harness wording in the texts.** The skills and agents say what to do in role terms ("start the tester role", "in the background", "a fresh reviewer"), not in a harness's tool names (`Agent tool`, `subagent_type`, `run_in_background`, `SendMessage`, `TaskStop`), and name no harness. Skill commands in the templates come from S08's `skill_command`. Paths a harness reserves (`CLAUDE.md`, `.claude/`) are named only where they are the repository's own facts, read from its `AGENTS.md` or from the role configuration (`.noodlebot/roles.yaml`), not as fixed text. *R02-AC-2.*
3. **The guard's split.** `plugin/hooks/guard.py` becomes the neutral check: given a role (`tester`, `implementer`, `reviewer`), a tool kind and its paths or command, it allows or returns the reason, with the rules and `.noodlebot/roles.yaml` as today. `plugin/hooks/claude_code.py` turns Claude Code's `PreToolUse` input (`agent_type`, `tool_name`, `tool_input`) into that call and its answer into exit 2 with the reason on stderr; `hooks.json` runs the adapter. *R02-AC-3.*
4. **The plugin rules of the core check.** `scheduler/agnostic.test.sh` also scans the tracked files under `plugin/` and the templates `scheduler/unattended*.md` and `scheduler/limit-resume.md`, outside the adapter's files (`plugin/.claude-plugin/`, `plugin/hooks/hooks.json`, `plugin/hooks/claude_code.py`) and tests, and fails, naming file and line, on: a `gh` command, a `github.com` URL, a `claude` command, `Claude Code`, `CLAUDE_PLUGIN_ROOT`, `PreToolUse`, and the tool names of change 2. *R02-AC-4.*
5. **Frozen test text.** Where an existing test expects text that change 1 or 2 replaces (a `gh` command in a rendered prompt, say), the new expectation checks the forge CLI command instead, each such change listed in the PR; no other expectation changes. A test that cannot be changed that way is a question for the owner. *R02-AC-1.*

## Gate
- **R02-AC-1** — Every prompt the loop renders (node, follow-up, triage, update, feedback, limit resume) tells the session to reach the forge through `NOODLEBOT_FORGE` and holds no `gh` command or `github.com` URL; it keeps the rules of questions, closing keywords, never merging or approving, and the signature. Each test expectation changed for this is listed in the PR. *Verify:* `scheduler/loop.test.sh`.
- **R02-AC-2** — No skill, skill fixture, agent or session template holds a `gh` command, a `github.com` URL, a `claude` command, `Claude Code` or a tool name of change 2. *Verify:* `scheduler/agnostic.test.sh`.
- **R02-AC-3** — The role guard's existing cases pass unchanged through the Claude Code adapter, and calling the neutral check directly with a role, tool kind and paths or command gives the same decisions. *Verify:* `plugin/hooks/guard.test.sh`, `plugin/hooks/guard-git.test.sh`, `plugin/hooks/guard-shell.test.sh`.
- **R02-AC-4** — The core check passes on the tree and fails, naming file and line, on each planted form of change 4 in a skill, an agent and a session template; the adapter's files are exempt. *Verify:* `scheduler/agnostic.test.sh`.
- **R02-AC-5** — A recorded unattended dry run of `/noodlebot:triage <N> --dry-run` on a fixture repository served by G04's fake forge, with a `gh` on `PATH` that logs and fails on any call, writes its `result.md` with the issue read and `nodes.py`'s output, and the `gh` log is empty. *Verify:* the recorded run, its `result.md` and the empty `gh` log, in the PR.

## Risks
- Sessions follow the skills by reading them; replacing familiar `gh` commands with the forge CLI may make a session reach for `gh` anyway out of habit. The core check covers the texts, not the session's behaviour; the dry run of R02-AC-5 is the only behavioural check.
- Describing subagent work in role terms loses some precision that Claude Code's tool names gave (background runs, model overrides). If a skill loses a behaviour, it is put back as a harness capability in S08's interface rather than as tool names in the text.
- `.claude/agents/` is where this repository's own role agents live (`AGENTS.md`); that is the repository's fact, and stays in `AGENTS.md`, not in the plugin.
- The skills' `SKILL.md` format is the Agent Skills format several harnesses read; a harness that does not read it needs its adapter to load them, which is that backend's node.
