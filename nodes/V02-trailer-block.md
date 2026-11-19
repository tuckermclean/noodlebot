# V02 — trailer-block

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | V01, A08 | none | S |

**Owns:** in `scheduler/loop.sh`, the text of the `commit-msg` hook (`hook_text`) and its header comment; `scheduler/loop-v02.test.sh` (new) and its line in the `Makefile`'s `TESTS`; in `plugin/agents/tester.md` and `.claude/agents/noodlebot-tester.md`, where the RED commit's `TDD-Red-Target:` trailer and a pin commit's `Pin-Mutation:` trailers go; the cases for that wording added to `plugin/skills/node/skill.test.sh`.
**Resolves:** #180

## Purpose
The tester agents put `TDD-Red-Target: <command>` "in the final paragraph" of a RED commit, so that Git reads it as a trailer. In practice the session then adds a `Co-Authored-By:` line as a paragraph of its own, and the `commit-msg` hook V01 installs adds `Noodlebot-Version:` to that last paragraph. `TDD-Red-Target:` ends up in the paragraph before the trailer block, and `git interpret-trailers --parse` and `git log --format='%(trailers:key=TDD-Red-Target)'` do not find it (A08's 8a1d5f3 and A07's RED commits, issue #180). The same happens to a pin commit's `Pin-Mutation:` trailers. Nothing breaks today, because the one reader (`plugin/skills/node/SKILL.md`'s update step) greps the text of `git log`, but the trailer contract is false. After this node, the hook joins the paragraphs made only of trailer lines at the end of a session's commit message into one final trailer block, so every trailer the session wrote is a Git trailer whatever the order of the paragraphs, and the tester agents say that the trailers go in that one final paragraph, with `Co-Authored-By` and no blank line between them. Squash-merged commits on `main` are not changed: their messages are the forge's.

## Tests
- `scheduler/loop-v02.test.sh` (new, in the `Makefile`'s `TESTS`): a loop started as `scheduler/loop-v01.test.sh` starts it, with a fake session that commits in its worktree messages of these shapes, then reads each commit with `git interpret-trailers --parse` and `git log --format='%B'`:
  - a RED commit: subject, a prose paragraph, `TDD-Red-Target: <command>` as a paragraph of its own, then `Co-Authored-By: …` as a paragraph of its own;
  - the same with a `Noodlebot-Version:` of another value in the `TDD-Red-Target:` paragraph;
  - a pin commit: two `Pin-Mutation: <DEP>-AC-<n>: <path>: <what is broken> -> <the case that fails>` lines as one paragraph, then `Co-Authored-By: …`;
  - `TDD-Red-Target:` and `Co-Authored-By:` already in one paragraph, and `TDD-Red-Target:` alone as the last paragraph;
  - messages whose paragraphs must not be joined: a prose paragraph directly before the trailers, a paragraph with one trailer-shaped line among prose lines directly before them, and a subject of the form `fix: <text>` followed only by a trailer paragraph;
  - a commit in the clone outside any session (no `NOODLEBOT_VERSION`) with the RED shape.
  The file stays under `TEST_FILE_BUDGET`.
- `plugin/skills/node/skill.test.sh` (cases added): the wording of V02-AC-3 in both tester agents.
- `scheduler/loop-v01.test.sh` (unchanged): every V01 case still passes.

## Changes
1. **The hook joins the trailing trailer paragraphs.** When `NOODLEBOT_VERSION` is set, the `commit-msg` hook in `hook_text`, before it drops and adds `Noodlebot-Version:` as V01 made it, takes the paragraphs at the end of the message (ignoring trailing blank and `#` comment lines) that consist only of trailer lines, a line of the form `<token>: <value>` with a token of letters, digits and hyphens, and removes the blank lines between them, so they form one last paragraph. It stops at the first paragraph, going backwards, that holds any other line, and never joins the subject paragraph. Every line other than those blank lines is kept, in its order. The `Noodlebot-Version:` step then works on that one paragraph, so the message ends with exactly one `Noodlebot-Version:` trailer as V01-AC-6 requires. Without `NOODLEBOT_VERSION` the hook still does nothing. The hook text changes in `loop.sh`, which is rewritten as a new file renamed over the old one (`AGENTS.md`); `install_hook` writes the new hook at the next loop start. *V02-AC-1, V02-AC-2.*
2. **The tester agents say where the trailers go.** `plugin/agents/tester.md` and `.claude/agents/noodlebot-tester.md` say that `TDD-Red-Target: <command>` (and a pin's `Pin-Mutation:` lines) go in the message's trailer block: the final paragraph, together with `Co-Authored-By:` and any other trailer, with no blank line between them. *V02-AC-3.*
3. **The test.** `scheduler/loop-v02.test.sh` as in Tests, and its line in the `Makefile`'s `TESTS`. *V02-AC-1, V02-AC-2.*

## Gate
- **V02-AC-1** — A commit made during a session whose message ends with trailer-only paragraphs separated by blank lines (`TDD-Red-Target: <command>`, then `Co-Authored-By: …`; with another `Noodlebot-Version:` among them; two `Pin-Mutation:` lines, then `Co-Authored-By: …`) has one final trailer block: `git interpret-trailers --parse` of its message lists every one of those trailers and exactly one `Noodlebot-Version: <the session's version>`, `git log --format='%(trailers:key=TDD-Red-Target,valueonly)'` prints the command, and every other line of the message is kept, in its order. A message whose trailers are already in one last paragraph gets the same result. *Verify:* `scheduler/loop-v02.test.sh`.
- **V02-AC-2** — The hook joins no paragraph that holds a line other than a trailer line: a prose paragraph, or a paragraph with one trailer-shaped line among prose, directly before the trailers keeps its blank line and is not listed by `git interpret-trailers --parse`, and a `fix: <text>` subject stays the subject. A commit in the clone outside any session is left as written, with no `Noodlebot-Version:` trailer. Every case of `scheduler/loop-v01.test.sh` passes. *Verify:* `scheduler/loop-v02.test.sh` and `scheduler/loop-v01.test.sh`.
- **V02-AC-3** — `plugin/agents/tester.md` and `.claude/agents/noodlebot-tester.md` say that the `TDD-Red-Target:` trailer and a pin's `Pin-Mutation:` trailers go in the message's final paragraph together with `Co-Authored-By:` and any other trailer, with no blank line between them. *Verify:* `plugin/skills/node/skill.test.sh`.

## Risks
- A one-line prose paragraph that looks like a trailer (`Note: <text>`) directly before the trailer block is joined into it and becomes a trailer. Its text is kept; only the blank line before it goes.
- A session that commits with `--no-verify`, or a clone with `core.hooksPath` set, bypasses the hook, as V01's Risks say; the tester's wording (change 2) is then the only guard.
- The hook is installed at a loop start, so a running loop keeps the old hook until its next start (a deploy re-execs the loop).
- `plugin/skills/node/SKILL.md`'s update step still greps the `git log` text for `TDD-Red-Target:`, which keeps working on the commits made before this node.
- Loop tests cost 10-25 s each; the new file holds one loop run with all the commit shapes made by one fake session, to stay under `TEST_FILE_BUDGET`.
