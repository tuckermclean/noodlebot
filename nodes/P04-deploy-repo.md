# P04 — deploy-repo

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | P01, D07 | none | S |

**Owns:** in `scheduler/api.py`, the `repo` of `/v1/deploy`'s `last_deploy` and `last_failed` (`last_status_lines`)
and its description in `scheduler/api-schema/v1/deploy.json`; their cases in a new `scheduler/api-p04.test.sh` and its
line in the `Makefile`'s `TESTS`.
**Resolves:** #139

## Purpose
After this node `/v1/deploy` says which repository a deploy was of. The self-deploy is of the live checkout, whichever
loop's tick ran `deploy.sh`, but `last_deploy.repo` and `last_failed.repo` give the repository of the loop whose status
log holds the line: a failed noodlebot commit showed as `tuckermclean/themonolith`. Afterwards `repo` names the live
checkout's repository.

## Tests
- `scheduler/api-p04.test.sh` (new): two listed repositories, the live checkout's being the second; a `not deployed:`
  line and a `deployed` line in the first repository's status log give `last_failed.repo` and `last_deploy.repo` equal
  to the live checkout's repository; a live checkout whose repository cannot be read gives the repository as before
  (the loop's), and the response still meets the schema.

## Changes
1. **The deployed repository.** `api.py` reads the live checkout's repository once (its `origin` remote, in the forge's
   `owner/name` form, through the forge interface's URL parsing where it has one) and uses it as `repo` of both
   entries. When it cannot be read, `repo` stays the repository whose status log holds the line. The schema's
   description of `repo` says so. *P04-AC-1.*

## Gate
- **P04-AC-1** — `/v1/deploy`'s `last_deploy.repo` and `last_failed.repo` name the live checkout's repository whichever listed loop logged the line, fall back to that loop's repository when the live checkout's cannot be read, and meet the schema; the existing P01 and D07 deploy cases pass unchanged. *Verify:* `sh scheduler/api-p04.test.sh`, `sh scheduler/api-sessions.test.sh`, `sh scheduler/api-events.test.sh` and `sh scheduler/api-d07.test.sh`.

## Risks
- The existing deploy cases (P01-AC-6, D07-AC-7) expect `acme/alpha`, the logging loop's repository; they hold only
  where the test's live checkout gives no repository or gives that one. If they cannot hold, changing their expectation
  is a frozen-test change the owner approves first.
- The API runs from the live checkout, so the repository it reads is the one deployed; an API started from another
  checkout would name that one.
