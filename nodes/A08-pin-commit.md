# A08 — pin-commit

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | A02 | none | M |

**Owns:** in `plugin/skills/node/SKILL.md`, the pin step, the checks of a pin commit and its evidence rows; the pin
instructions in `plugin/agents/tester.md` and the pin checks in `plugin/agents/reviewer.md`; the pin line of the SMALL
SPEC AMENDMENTS rule in `scheduler/unattended.md` and `scheduler/unattended-followup.md`; their cases in
`plugin/skills/node/skill.test.sh`.

## Purpose
After this node a node can change imported code safely. Before it changes behaviour of an imported node that no test
shows yet (an `unpinned` criterion), its tester first writes a test that pins today's behaviour. A pin passes as soon
as it is written, so it cannot be a RED commit; it gets its own commit type, `pin(<ID>):`, and has to prove it would
catch a change: the session breaks the code on purpose, shows the pin fails, and puts the code back. The dep's
criterion then names the pin instead of `unpinned`, and a node whose criteria are all pinned becomes `pinned`.

## Tests
- `plugin/skills/node/skill.test.sh` (extended): the skill's, the tester's and the reviewer's text and the session
  templates' amendment rule, as below.

## Changes
1. **When.** In a repository whose graph has imported nodes, before the node's first RED commit, the orchestrator lists
   the `unpinned` criteria of its imported deps whose files the node's change touches (from the node's **Changes**
   and the deps' `owns`) and has a tester pin each one. *A08-AC-1.*
2. **The commit.** A pin commit has the subject `pin(<ID>): …`, touches only test and fixture paths, and carries one
   `Pin-Mutation: <path>: <what was broken> -> <the case that failed>` trailer per pinned criterion. The tester leaves
   each mutation as a patch, `out/node/<ID>/pin-<n>.patch`. *A08-AC-1.*
3. **Verified, not claimed.** The orchestrator checks each pin: the pinned cases pass at the pin commit; with the
   patch applied the named case fails; with it reverted they pass again. It keeps the three runs as
   `out/node/<ID>/pin-<n>.log`. A pin that passes with its mutation applied goes back to a new tester. *A08-AC-2.*
4. **Frozen.** A pin's test lines are frozen like a RED commit's: a later commit may add cases, never change or remove
   one, without the owner's approval. *A08-AC-2.*
5. **The dep's spec.** Replacing `unpinned` in a dep's criterion with the pin's test, and changing the dep's `status`
   to `pinned` when no `unpinned` criterion is left, are small amendments in the node PR (the one exception to "another
   node's spec needs a spec PR"), listed in its **Spec amendments** section. *A08-AC-3.*
6. **The reviewer** checks every pin commit's paths, trailers, patches and logs, and the dep amendments. *A08-AC-2.*

## Gate
- **A08-AC-1** — The skill and the tester say when a pin is required and what a `pin(<ID>):` commit contains: test and fixture paths only, a `Pin-Mutation:` trailer per criterion, and the mutation as a patch. *Verify:* `sh plugin/skills/node/skill.test.sh`.
- **A08-AC-2** — The skill requires the three-run check of each pin with its log, freezes pin lines like RED lines, and the reviewer checks both. *Verify:* `sh plugin/skills/node/skill.test.sh`.
- **A08-AC-3** — The skill and both session templates allow, as a small amendment, replacing `unpinned` in a dep's criterion with its pin and setting the dep `pinned` when none is left. *Verify:* `sh plugin/skills/node/skill.test.sh`.

## Risks
- Which criteria a change touches is the orchestrator's judgement from the specs; the reviewer checks it, and a missed
  pin shows as a behaviour change no test caught.
- A mutation can be too gentle to matter; the reviewer reads each one with its failing case.
- Pinning adds work before the first RED commit of nodes that change imported code; that is the price of changing code
  no test describes, paid once per criterion.
