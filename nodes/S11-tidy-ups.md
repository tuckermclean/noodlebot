# S11 — tidy-ups

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | R02, S03, D06 | none | S |

**Owns:** the "Read the PR's comments" line of `scheduler/unattended.md` and `scheduler/unattended-followup.md`, and
the rule for a forge's name in a session template in `scheduler/agnostic.test.sh` (its cases there); the reads of a
file that may be missing, written `<"<file>" 2>/dev/null`, in `scheduler/loop.sh` (`fu_branch` among them),
`scheduler/deploy.sh`, `scheduler/loops.sh` and `scheduler/status.sh`, with their cases in a new
`scheduler/quiet-reads.test.sh` and its line in the `Makefile`'s `TESTS`; the README references in
`container/compose.yaml` and `container/k8s/kustomization.yaml`, with their case in `container/container.test.sh`.
**Resolves:** #139

## Purpose
After this node three small faults are gone. The build templates still tell a session to read a closed PR's comments
"on GitHub", though R02 made the templates forge-neutral. A missing optional file makes the shell print an error on
every tick: in `cmd <"$f" 2>/dev/null` the input redirection fails before `2>/dev/null` applies (`fu_branch` in
`scheduler/loop.sh` reads `FOLLOWUP` that way for every node). And the container files point to the README section
"Container", now "Running it in a container".

## Tests
- `scheduler/agnostic.test.sh` (extended): no session template (`scheduler/unattended*.md`,
  `scheduler/limit-resume.md`) names a forge (`GitHub`, `GitLab`, `Gitea`, `Forgejo`); a planted "on GitHub" in a copy of
  a template fails the check, naming file and line.
- `scheduler/quiet-reads.test.sh` (new): no non-test script under `scheduler/` has an input redirection followed by
  `2>/dev/null` on the same command (a planted one in a copy fails the check, naming file and line); `fu_branch` on a node
  folder without `FOLLOWUP` fails and writes nothing to stderr, and with a `FOLLOWUP` prints its branch as before.
- `container/container.test.sh` (extended): every README section a file under `container/` names in the form
  `(README, section "<title>")` is a heading of `README.md`.

## Changes
1. **No forge in the templates.** The line becomes "Read the PR's comments for why" (the forge CLI's `pr comments` where
   the template names commands), and `agnostic.test.sh` fails on a forge's name in a session template. *S11-AC-1.*
2. **Quiet reads.** Each read of a file that may be missing silences its own failure: `2>/dev/null` before the input
   redirection, or a test for the file first, keeping what the command returns when the file is there and when it is
   not. *S11-AC-2.*
3. **README references.** `container/compose.yaml` and `container/k8s/kustomization.yaml` name the section "Running it in
   a container". *S11-AC-3.*

## Gate
- **S11-AC-1** — `scheduler/unattended.md` and `scheduler/unattended-followup.md` name no forge, and the core check fails, naming file and line, on a forge's name planted in a session template. *Verify:* `sh scheduler/agnostic.test.sh`.
- **S11-AC-2** — No non-test script under `scheduler/` puts `2>/dev/null` after an input redirection on one command, a planted one fails the check, and `fu_branch` on a node without `FOLLOWUP` writes nothing to stderr and returns as before. *Verify:* `sh scheduler/quiet-reads.test.sh`.
- **S11-AC-3** — Every README section named by a file under `container/` is a heading of `README.md`. *Verify:* `sh container/container.test.sh`.

## Risks
- The pattern check is textual: a redirection split across lines or built in a variable escapes it; the reviewer reads
  the scripts' reads of optional files.
- Each script changed is one a running loop may execute; it is replaced, not edited in place (principle 6), as every
  node's change is when deployed.
