# S09 — pickup-agent

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | U03, S08, G04 | none | L |

**Owns:** `scheduler/pickup.py` (finding the items, the run budget, checking and carrying out the decisions, the handled record), `scheduler/pickup.test.sh` and its line in the `Makefile`'s `TESTS`, the fixtures `scheduler/testdata/pickup/`; the agent's prompt `scheduler/pickup.md`; the small-model, no-tools start in `scheduler/harness.py`, its Claude Code backend and the fake harness, and their conformance cases in `scheduler/harness.test.sh`; in `scheduler/loop.sh`, the pickup step and the settings `PICKUP`, `PICKUP_RUNS` and `PICKUP_CEILING`; the reading of pickup runs in `scheduler/usage.py`; in `scheduler/report.py`, leaving to the pickup step the owner comments it cannot place while the step is on; in `scheduler/feedback.py`, handing over an item that came from outside the PR; the new test `scheduler/loop-s09.test.sh` and its line in the `Makefile`'s `TESTS`; their cases in `scheduler/usage.test.sh`, `scheduler/report.test.sh` and `scheduler/feedback.test.sh`.
**Resolves:** #87

## Purpose
After this node an owner's comment that the deterministic code cannot place is picked up within a tick, even while the throttle holds. Examples are a comment on a unit's issue when no question is open, an unprefixed reply on the log issue, or a request written on a PR's home issue. A small agent on the harness's small model (Haiku on Claude Code) reads these comments and decides what each one is: an answer to a unit's question, feedback on a bot PR, a new request, or a note. The loop, not the agent, carries out the decision with the markers it already acts on, and replies once to each comment. The agent has no tools. It never commits, pushes, opens PRs, edits specs or changes labels, so every change to the repository still comes from a full session at its turn.

## Tests
- `scheduler/pickup.test.sh` (new), with the fake `gh api` of `scheduler/report.test.sh`, a fake forge where G04 needs one, and fixtures under `scheduler/testdata/pickup/` (home issues, the log issue, bot PRs, units' state folders, `usage.json`). Cases:
  - Finding items: what `report.py` left to it (no question open, two units waiting and no prefix, an unprefixed log-issue comment) is listed; a comment already recorded as an answer or as G03 feedback, another user's comment, the bot's own and an item already handled are not.
  - Each decision kind is carried out once over three runs:
    - an answer: `ANSWER.md`, the `+1` and the answer-received milestone, as U01 records it;
    - feedback: the PR unit's `FEEDBACK.md` through `feedback.py`;
    - a request: a new issue quoting and linking the comment, with no label;
    - a note: nothing.
  - Each comment gets exactly one reply, saying what was done and U03's start clause.
  - A decision naming a unit with no open question, an unknown PR, an action outside the four, malformed output, or a session that used a tool is refused. The comment then gets `report.py`'s deterministic reply, and the refusal is logged.
  - The budget: a sixth run past `PICKUP_RUNS=5` in one 5-hour window does not start. A window rejecting requests, or one at `PICKUP_CEILING`, starts no run. A pace hold alone does not stop a run. Two loops share one budget record under `flock`.
- `scheduler/harness.test.sh` (extended): a small-model, no-tools start through the Claude Code backend (over the fake `claude`) and through the fake harness. Its arguments name the small model and allow no tool; a backend without the capability reports it off.
- `scheduler/loop-s09.test.sh` (new), with the fake harness and a fake `usage.py`:
  - with the throttle on a pace hold, a tick with one unplaceable owner comment runs one pickup session and records its decision, and no unit session starts;
  - a tick with no items runs none;
  - `PICKUP=0`, or a harness lacking the capability, runs none, with one status-log line per loop start, and every existing `report*` case passes unchanged;
  - each run is one status-log event (items, decisions, cost).
- `scheduler/usage.test.sh` (extended): a pickup run's usage readings count in the windows like a session's.
- The recorded live run of S09-AC-7.

## Changes
1. **Items.** `pickup.py items` lists the owner comments of the tick that the deterministic code did not place. These are the comments `report.py` would answer "Not recorded as an answer" (U01-AC-4: no question open, or several units waiting with no prefix) and the unprefixed owner comments on the log issue. Each item carries its URL, its issue or PR, its text, and the open questions, open bot PRs and units of the repository, as short lines. Comments already recorded as answers or as feedback, others' comments, the bot's own and anything in the handled record `state/<name>/pickup/handled` are not items. While the step is on, `report.py` leaves these comments to it and does not reply to them. *S09-AC-1.*
2. **The run.** When there are items, the loop starts one pickup run per tick through the harness interface, with the backend's small model and no tools. The prompt is `scheduler/pickup.md` plus the items. The agent's whole output is a JSON list with one decision per item: `answer <unit>`, `feedback <PR>`, `request <title>` or `note`, each with a one-line reason. A run takes no S07 turn, no start and no slot of `SCHED_MAX`. Its log goes to `state/<name>/pickup/<ts>/` and is read by `usage.py` like a session's. *S09-AC-2.*
3. **Decisions are carried out by the loop.** `pickup.py apply` checks each decision against the state and refuses one that names a unit with no open question, an unknown PR or another action. It also refuses all decisions of a run that used a tool, and of malformed output. An accepted decision is carried out:
   - an answer: written as U01 records it (`ANSWER.md` with the comment's URL, `+1`, the answer-received milestone);
   - feedback: handed to the PR's unit through `feedback.py`, so G03 starts its session at its turn;
   - a request: a new issue quoting and linking the comment, with no label, so only the owner hands it to the bot;
   - a note: nothing.

   Every item then gets one reply on its thread: what was done, and U03's start clause. A refused item gets `report.py`'s deterministic reply. Each item goes into the handled record once its reply is posted, so a failed post is retried and nothing is posted twice. *S09-AC-3, S09-AC-4.*
4. **Throttle and budget.** The pickup run is exempt from the throttle's pace holds (the 5-hour projection and the 7-day pace). It does not start when any window is rejecting requests or its utilisation is at or above `PICKUP_CEILING` (default 90%). The machine has one budget record, `$NOODLEBOT_DATA/state/pickup.json`, written under `flock`: at most `PICKUP_RUNS` runs (default 12) per 5-hour window across all loops. Each run is capped at one turn. With the budget spent or the ceiling reached, items get `report.py`'s deterministic replies. One status-log line says so the first time in each window. *S09-AC-5.*
5. **Off switch.** `PICKUP=0`, or a harness lacking the small-model, no-tools capability (S08's capability rule), turns the step off, with one status-log line per loop start. `report.py` then replies to every comment as before this node. *S09-AC-6.*

## Gate
- **S09-AC-1** — `pickup.py items` lists exactly the owner comments `report.py` cannot place, as change 1 lists them. Recorded answers, recorded feedback, other users' comments, the bot's own and handled items are not listed. While the step is on, `report.py` posts no "Not recorded" reply to a listed comment. *Verify:* `scheduler/pickup.test.sh`.
- **S09-AC-2** — A tick with items starts exactly one pickup run, through the harness interface, with the small model and no tools; a tick without items starts none. The run takes no S07 turn and no start, and counts for no `SCHED_MAX` slot. Its usage counts in `usage.py`'s windows. Each run is one status-log event naming its items, its decisions and its cost. *Verify:* `scheduler/loop-s09.test.sh`, `scheduler/harness.test.sh`, `scheduler/usage.test.sh`.
- **S09-AC-3** — Each accepted decision is carried out exactly once over any number of runs: `answer` writes the unit's `ANSWER.md` with the comment's URL, the `+1` and the answer-received milestone; `feedback` puts the item in the PR unit's `FEEDBACK.md` through `feedback.py`; `request` opens one issue quoting and linking the comment, with no label; `note` changes nothing. Each item gets exactly one reply, with what was done and U03's start clause. *Verify:* `scheduler/pickup.test.sh`.
- **S09-AC-4** — The pickup run never changes the repository except through those four actions. A decision naming a unit with no open question, an unknown PR or any other action is refused. A run that used a tool, or whose output is not a valid decision list, has all its decisions refused. A refused item gets `report.py`'s deterministic reply, and the refusal is logged. No commit, push, PR, label change or file outside `state/` comes from a pickup run. *Verify:* `scheduler/pickup.test.sh`.
- **S09-AC-5** — A pace hold alone does not stop a pickup run. A window rejecting requests, or one at or above `PICKUP_CEILING`, does. No more than `PICKUP_RUNS` runs start in one 5-hour window across all loops, and two loops asking at once share the record without exceeding it. Items left by the budget or the ceiling get the deterministic reply, and the first such tick in a window logs one line. *Verify:* `scheduler/pickup.test.sh`, `scheduler/loop-s09.test.sh`.
- **S09-AC-6** — With `PICKUP=0` or a harness lacking the capability, no pickup run starts, one status-log line per loop start says so, and every existing `report*` and U03 case passes unchanged. *Verify:* `scheduler/loop-s09.test.sh`, `make test`.
- **S09-AC-7** — One live run on the real small model with a fixture of five owner comments: an answer to an open question, feedback on a bot PR written on a home issue, a new request, a note, and a comment naming no unit while two are waiting. The decisions are the expected ones; any miss is listed with the reason the agent gave. *Verify:* the recorded run (items, output, decisions, cost) in the PR.

## Risks
- The agent's judgment can be wrong: an aside can be taken as an answer, or a request as feedback. Every action is one the owner can undo with a new comment, and every reply says what was done, but a wrong answer starts a session on it.
- The defaults (12 runs per 5-hour window, a 90% ceiling, one turn per run) are first guesses, not measured. Haiku's cost per run has not been read from a real plan window.
- The pickup run draws on the same plan windows as the sessions. Through a pace hold it spends a little of what the hold was saving.
- G03's feedback held by the throttle is not itself an item: it is placed already, and its session starts at its turn. Acknowledging such feedback while it is held is left out of this node.
- G04 and S08 must be merged first: this node uses the forge interface for its replies and new issues, and the harness interface for its run. If R02 is merged first, `scheduler/pickup.md` must pass its neutral-wording check.
