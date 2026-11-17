# A08 — pin-commit

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | A05 | A09 | M |

**Owns:** in `plugin/skills/node/SKILL.md`, the pin step, the checks of a pin commit, their evidence rows, and the dep
amendments in step 7's small-amendment rule; the pin instructions in `plugin/agents/tester.md` and the pin checks in
`plugin/agents/reviewer.md`; the dep-amendment line of the SMALL SPEC AMENDMENTS rule and its lines in A05's
keep-both-sides exception (the MERGE CONFLICTS rule, the `--update` step and `scheduler/unattended-node-update.md`) in
`scheduler/unattended.md`, `scheduler/unattended-followup.md` and the node skill; their cases in `plugin/skills/node/skill.test.sh`.

## Purpose
After this node a node can change imported code safely. Before it relies on behaviour of an imported node that no test
shows yet (an `unpinned` criterion), its tester first writes a test that pins today's behaviour. A pin passes as soon
as it is written, so it cannot be a RED commit; it gets its own commit type, `pin(<ID>):`, and has to prove it would
catch a change: the orchestrator applies a deliberate break the tester proposes, shows the pin fails, and takes the
break out again. The dep's criterion then names the pin, and a node whose criteria are all pinned becomes `pinned`. A
dep criterion the node itself changes is not pinned: the node's own criterion supersedes it.

## Tests
- `plugin/skills/node/skill.test.sh` (extended): the skill's, the tester's and the reviewer's text and the session
  templates' amendment rule, as below.

## Changes
1. **Which criteria.** In a repository whose graph has imported nodes, before the node's first RED commit, the
   orchestrator lists the `unpinned` criteria of its imported deps whose files the node's change touches (from the
   node's **Changes** and the deps' `owns`). A criterion whose behaviour the node keeps is pinned; one the node changes
   is superseded by the node's own criterion that states the new behaviour (change 5), and is not pinned. The test its
   *Verify* names is frozen (A05): changing it to the new behaviour is a change to a frozen test, made on the node
   branch only with the owner's approval asked for at step 7 and recorded in the answer. *A08-AC-1.*
2. **The commit.** A tester writes the pins: a commit with the subject `pin(<ID>): …` that touches only test and
   fixture paths (new test files placed as A05 allows: at a path a dep's glob matches, or in the node's own `owns` only where no
   other node's glob matches) and carries
   one `Pin-Mutation: <DEP>-AC-<n>: <path>: <what is broken> -> <the case that fails>` trailer per pinned criterion,
   naming the criterion it pins. The tester
   returns each mutation as a diff in its handoff; it does not edit the code. *A08-AC-1.*
3. **Verified, not claimed.** The orchestrator writes each mutation to `out/node/<ID>/pin-<n>.patch` and checks it:
   the pinned cases pass at the pin commit; with the patch applied the named case fails; with it reverted they pass
   again. It keeps the three runs as `out/node/<ID>/pin-<n>.log`. A pin that passes with its mutation applied goes back
   to a new tester. *A08-AC-2.*
4. **Frozen.** A pin's test lines are frozen like a RED commit's: a later commit may add cases, never change or remove
   one, without the owner's approval. *A08-AC-2.*
5. **The dep's spec.** In the node PR, as small amendments named in its **Spec amendments** section: replacing
   `unpinned` in a pinned dep criterion with the pin's test; replacing a changed dep criterion's *Verify* with
   `superseded by <ID>-AC-<n>`; and setting the dep's `status` to `pinned` in the graph when no `unpinned` criterion is
   left. Like A05's `owns` and `known_red` lines, these are exceptions to "another node's spec or the graph needs a
   spec PR", and a conflict with `main` in them is resolved by keeping both sides as A05 says. *A08-AC-3.*
6. **The reviewer** checks every pin commit's paths and trailers, the patches and logs, the pinned and superseded
   choices, and the dep amendments. *A08-AC-2.*

## Gate
- **A08-AC-1** — The skill and the tester say which dep criteria are pinned and which are superseded (a superseded criterion's frozen test changed only with the owner's approval), and what a `pin(<ID>):` commit contains: test and fixture paths only, a `Pin-Mutation:` trailer naming each pinned criterion, and each mutation returned as a diff. *Verify:* `sh plugin/skills/node/skill.test.sh`.
- **A08-AC-2** — The skill requires the orchestrator's three-run check of each pin with its patch and log, freezes pin lines like RED lines, and the reviewer checks both. *Verify:* `sh plugin/skills/node/skill.test.sh`.
- **A08-AC-3** — The skill and both session templates allow, as small amendments in the node PR, naming the pin in a dep's criterion, marking a changed one `superseded by <ID>-AC-<n>`, and setting the dep `pinned` when none is left unpinned, resolving a conflict in those lines by keeping both sides. *Verify:* `sh plugin/skills/node/skill.test.sh`.

## Risks
- Which criteria a change touches, and whether it keeps or changes each, is the orchestrator's judgement from the
  specs; the reviewer checks it, and a missed pin shows as a behaviour change no test caught.
- A mutation can be too gentle to matter; the reviewer reads each one with its failing case.
- Pinning adds work before the first RED commit of nodes that change imported code; that is the price of changing code
  no test describes, paid once per criterion.
