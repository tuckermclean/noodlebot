# L01 — labels

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | none | none | S |

**Owns:** `scheduler/labels.py`, `scheduler/labels.test.sh`, its line in the `Makefile`'s `test` target, the label step at the start of `scheduler/loop.sh`, its cases in `scheduler/loop.test.sh`.
**Resolves:** #5

## Purpose
After this node a repository needs no hand setup before the owner can hand it an issue: each loop, when it starts, makes sure the three labels it relies on exist in its repository: `noodlebot` (the owner hands an issue to the bot), `noodlebot-triaged` (`issues.py done`) and `noodlebot-status` (`report.py`'s status issue). Missing labels are created with a colour and a description; existing ones are left as they are. This happens once per loop start, not on every tick, and a failure never stops the loop (SPEC §1.2).

## Tests
- `scheduler/labels.test.sh` (new): a fake `gh api` serving a repository's labels and recording every call; a repository with none of the three labels, one with all three, one with some, and one whose `gh` fails.
- `scheduler/loop.test.sh` (extended): the loop's fake `gh` records label calls; the label step runs once at start and not again on later ticks, and a failing label step leaves the loop ticking.

## Changes
1. **`labels.py ensure --repo <owner/name>`.** Lists the repository's labels (`GET repos/<repo>/labels`, every page) and creates each of `noodlebot`, `noodlebot-triaged` and `noodlebot-status` that is missing (`POST repos/<repo>/labels`), with a colour and a description: `noodlebot` fbca04, "Hand this issue to the n00dl3b0t: it triages it into the graph (only the owner's label counts)"; `noodlebot-triaged` c5def5 and `noodlebot-status` 5319e7 with the descriptions `issues.py` and `report.py` give them. An existing label gets no write, whatever its colour or description; a create that reports the label already exists counts as success. It prints one line per label created, and exits non-zero with the error on stderr when `gh` fails. *AC-1, AC-2, AC-3.*
2. **The loop runs it once at start.** After taking its lock and making sure its clone exists, and before its first tick, `loop.sh` fetches a token and runs `labels.py ensure` for its repository. Success with labels created is one status-log event naming them; a failure (no token, or `labels.py` non-zero) is one status-log event, its stderr goes to `report.log`, and the loop goes on to its first tick. Ticks never run it. *AC-4, AC-5.*
3. **`make test` runs `labels.test.sh`.** *AC-1.*

## Gate
- **L01-AC-1** — For a repository with none of the three labels, `labels.py ensure` creates `noodlebot`, `noodlebot-triaged` and `noodlebot-status`, each with a colour and a non-empty description. *Verify:* `scheduler/labels.test.sh`, run by `make test`.
- **L01-AC-2** — For a repository that has all three labels (with any colour or description), `labels.py ensure` makes no write call (no POST, PATCH or DELETE) and exits 0; for one with some of them, it creates only the missing ones. *Verify:* `scheduler/labels.test.sh`.
- **L01-AC-3** — When `gh` fails, `labels.py ensure` exits non-zero with the error on stderr, and a create rejected because the label already exists is not a failure. *Verify:* `scheduler/labels.test.sh`.
- **L01-AC-4** — A loop runs the label step once when it starts and not on later ticks. *Verify:* `scheduler/loop.test.sh`.
- **L01-AC-5** — When the label step fails, the loop logs one status-log event and still ticks and starts ready work. *Verify:* `scheduler/loop.test.sh`.

## Risks
- A loop restart (or a re-exec after a deploy, D01) runs the step again; with all labels present that is one read and no write.
- The App needs write access to the repository's issues to create labels; without it the step fails every start, is logged, and the owner creates the labels by hand as before.
- `issues.py` and `report.py` still create their own label when it is missing, so a failed start-up step is covered for those two; only `noodlebot` depends on this node.
- D01, D02 and M01 also change `scheduler/loop.sh` and `scheduler/loop.test.sh`; whichever merges second rebases. Under D02 the label step's logs go to the state folder under the runtime root, like every other loop log.
