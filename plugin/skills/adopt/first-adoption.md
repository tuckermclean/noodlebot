# The first adoption: tuckermclean/bosnia

The record of the first real run of `/noodlebot:adopt`, by the deployed loop, on a repository the owner chose. It
answers A09-AC-1 and A09-AC-2. All times are UTC. The facts come from bosnia's issue #3 and PRs #4 to #13 (bodies,
reviews, comments, merge commits), from bosnia's history, from the checkers run on its final `main`, and from the
owner's account of what went wrong. Where a fact rests on the owner's word alone, the text says so.

The repository is `github:tuckermclean/bosnia` (the forge CLI's `--repo` form). Every `#N` below is a bosnia PR or
issue number unless it says noodlebot. Each is checkable with the forge CLI and that `--repo`: `pr view --number N`
or `issue view --number N`. (The record gives no URLs: R02's rule keeps them out of files under `plugin/`.)

## Who did what

- The repository, `tuckermclean/bosnia` (a language-learning app: backend, content pipeline, Expo app, voice agent,
  deploy files), was the owner's choice. It had no `docs/graph.yaml`. The owner added it to the loop's list of
  repositories and started its loop.
- The loop's sessions drafted every PR. The bot's comments are signed by `n00dl3b0t[bot]`.
- Every review by `tuckermclean` on #4 to #13 was written by an agent session on the owner's account, not by
  the owner in person (owner's account). The owner merged #4 to #9. From #10 on the owner had that session merge each
  PR itself once its approving review covered the head and CI was green (the owner's decision of 2026-11-19). So the
  owner chose the repository, set the rules and decided how merging worked, and the reviewing and later merging were
  done by an agent session on the owner's behalf. The record does not hide this.

## The adoption, start to end

Issue: bosnia issue #3 ("Adopt bosnia", opened 2026-11-18T01:23Z, closed by the loop
at 2026-11-19T14:17Z after the plan PR merged). About 37 hours, 8 PRs. The base was bosnia's `main` at 460501b, with
no graph.

| bosnia PR | Step | Opened | Merged | Review rounds | Merge commit |
|---|---|---|---|---|---|
| #4 | first PR (scaffold) | 11-18 01:43 | 11-18 13:39 | 5, all changes requested | 969b2c9 |
| #6 | area repo-root | 11-18 13:42 | 11-18 16:06 | 4 (3 changes requested, approve) | 514280e |
| #7 | area content-pipeline | 11-18 16:11 | 11-18 17:29 | 4 (3, approve) | a5ea0c1 |
| #8 | area backend | 11-18 17:36 | 11-18 22:22 | 4 (3, approve) | 8fa9590 |
| #9 | area app | 11-18 22:28 | 11-18 23:39 | 3 (2, approve) | 416c509 |
| #10 | area voice-agent | 11-18 23:43 | 11-19 06:04 | 3 (2, approve) | 75052fe |
| #11 | area deploy | 11-19 06:07 | 11-19 13:52 | 2 (1, approve) | bcc48c9 |
| #13 | plan, ends the adoption | 11-19 13:54 | 11-19 14:16 | 1 (approve) | a6ba2b1 |

Numbers #2, #5 and #12 are not adoption PRs: they are the loop's daily log issues, "noodlebot log 2026-11-19" (#12)
and "noodlebot log 2026-11-18" (#5, opened 2026-11-18T08:01Z; #2 is the earlier one). Each PR was opened by the loop
within eight minutes of the previous merge, so the waiting was for review and merge, and for the throttle (below).
The final `main` of the adoption is a6ba2b1, the merge of #13.

## The areas and the nodes each gave

Areas were mapped in the owner's order, foundations first, so that each node's deps point at areas already mapped.
Every node is `imported`, `track: done`. Counts are from `nodes/*.md` at a6ba2b1, recounted for this record: 41
nodes, 241 criteria, 144 of them `unpinned` (their *Verify:* reads `unpinned`, no test shows them). They agree with
the checker's 41 nodes and 241 criteria and with #13's body.

| Order | Area (PR) | Nodes | Criteria | `unpinned` | Imported nodes |
|---|---|---|---|---|---|
| 1 | repo-root (#6) | 3 | 14 | 14 | R01 workspace, R02 repo-docs, R03 ignore-lists |
| 2 | content-pipeline (#7) | 8 | 51 | 26 | C01 content-package, C02 course-schema, C03 llm-provider, C04 generation, C05 validation, C06 reference-audio, C07 review-tooling, C08 seed-a1 |
| 3 | backend (#8) | 11 | 73 | 30 | B01 backend-package, B02 env-config, B03 database, B04 service-adapters, B05 auth, B06 course-seed, B07 lessons-progress, B08 pronunciation, B09 tutor-session, B10 api-server, B11 backend-image |
| 4 | app (#9) | 8 | 55 | 31 | A01 app-package, A02 design-system, A03 api-client, A04 app-shell, A05 pronunciation-ui, A06 lesson-runner, A07 home-profile, A08 voice-tutor-ui |
| 5 | voice-agent (#10) | 7 | 31 | 26 | V01 voice-package, V02 tutor-prompt, V03 agent-config, V04 turn-logger, V05 voice-worker, V06 latency-probe, V07 voice-image |
| 6 | deploy (#11) | 4 | 17 | 17 | D01 ci, D02 release, D03 k8s-manifests, D04 deploy-guide |
| | total | 41 | 241 | 144 | |

The first PR (#4) added `SPEC.md`, `AGENTS.md`, `docs/graph.yaml` (gate, `out_of_scope`, the six areas, `nodes: []`)
and `.noodlebot/roles.yaml`. Each area PR took its area off `adoption.areas`. The plan PR (#13) removed the
`adoption` key, which by then held an empty `areas` list. At a6ba2b1 `docs/graph.yaml` has no `adoption` key.
`out_of_scope` has three entries: `content/generated/`, `content/audio-out/`, `app/assets/`.

## The gate

From `docs/graph.yaml` at a6ba2b1:

```
command: npm test -w @bosanski/backend; b=$?; npm run test -w @bosanski/content; c=$?; (cd app && npx jest); a=$?; (cd voice-agent && python3 -m unittest discover -s tests -t .); v=$?; exit $((b|c|a|v))
fail_pattern: ^ FAIL  \S+ > |^  ● (?!Test suite failed to run|Console$)|^(FAIL|ERROR): test
known_red: []
```

The baseline run in the first PR passed: backend 51, content 26, app 25, voice-agent 9 tests, so `known_red` is
empty (from #4's body; CI's four jobs reported the same counts in the reviews). Installs (`npm ci` at the root and in
`app/`) are setup in AGENTS.md, not part of the gate. Typechecks and `py_compile` stay in CI and in AGENTS.md's
"Other checks", because they name no test.

How the `fail_pattern` changed during #4:

1. The owner's answer to Q6 accepted the one proposed in the question:
   `^ FAIL  \S+ > |^  ● .+ › |^(FAIL|ERROR): test`.
2. The first PR's first commit (ff13090) widened the jest part to `^  ● (?!Test suite failed to run)`,
   because `● .+ › ` missed a jest test written outside a `describe`.
3. After review round 3 (commit d7bb2a2) the pattern also skipped `Console$`: jest prints `  ● Console` above a test's
   console output in a multi-file run, even for a passing one, and the pattern matched it.
4. That is the final pattern. The AGENTS.md wording about CI output changed three times:
   - a552d15 (after round 2) said the failure lines "carry no colour codes (checked with probes)" and that
     `FORCE_COLOR` would colour them.
   - d7bb2a2 (after round 3) said vitest colours its output in GitHub Actions and is off only in an agent session,
     so a CI log's ANSI codes are stripped before matching. Jest's failure lines carry none.
   - 3cfdbcc (after round 4) added that every line of a fetched job log starts with a timestamp, so both the
     timestamp (`^\S+Z `) and the colour codes (`\x1b\[[0-9;]*m`) are stripped before matching, and made the agent
     variables examples.
   The earlier claim was wrong because the probes ran inside an agent session, where vitest turns colour off.

Round 2 also fixed AGENTS.md's app quick gate to `(cd app && npx jest --runTestsByPath <path>)`: without it jest
reads a path such as `app/(tabs)/__tests__/home.test.tsx` as a regular expression and finds no tests.

## The questions and the owner's answers

The first session (scaffold) asked nine questions in one comment on issue #3 (2026-11-18T01:23Z). The owner answered
in one comment (01:35Z), before the first PR was opened. The owner's answer opened with a rule: the adoption must
not reference the closed bosnia PR #1, the `old/adopt-2026-11-11` branch or anything on it, and everything is drafted
from `main` and from the answers (see "What went wrong", item 2).

| Q | Question | Owner's answer |
|---|---|---|
| Q1 | Scope: web app first, native later, content work is the owner's? | Yes. Web first (Expo web build, backend on the same origin), native later, no app-store work. Content writing and review are the owner's work. |
| Q2 | Priorities: there are no open issues; what does SPEC.md record? | A work order (hygiene and broken docs, dependencies, web build and CORS and hosting, auth hardening, web voice tutor and turns and reference audio, migrations and shutdown and review-tool tests, phoneme scoring later) plus the `FOLLOWUPS.md` items. The owner opens issues for what to build before `--plan`. |
| Q3 | Done vs planned content? | A1 to B2 content is done and unreviewed; the stale "A1 only" docs are a later node. |
| Q4 | Principles? | The eight proposed, restated in full: keys server-side; Azure bs-BA voice authenticity before latency; content `unreviewed` until a native speaker signs off; no Docker or keys for tests and local dev; voice-agent modules import with zero env vars; pinned dependencies; a missing key fails clearly; web first. |
| Q5 | Open decisions? | Find them in the code on `main`, each with a default and reason; written fresh, not copied from anywhere. |
| Q6 | The gate? | As recommended: the four CI test steps chained from the root, with installs as setup; the proposed `fail_pattern`, confirmed by the baseline run; the quick gate with the same runners and a file list. Typechecks and `py_compile` stay in CI. |
| Q7 | Out of scope? | `content/generated/`, `content/audio-out/`, `app/assets/`; lockfiles stay in scope with their package. |
| Q8 | Areas? | The six areas, mapped in the owner's order: repo-root, content-pipeline, backend, app, voice-agent, deploy. |
| Q9 | Unclear facts: (a) role guard misses test paths, (b) `seed-a1` documented but missing, (c) bring back `docs/AUDIT.md`? | (a) Yes, `.noodlebot/roles.yaml` lists `backend/test/**`, `content/test/**`, `app/**/__tests__/**`. (b) Yes, a later hygiene node. (c) No. |

Earlier, before bosnia's loop ran, two other answers shaped the run (these are in the noodlebot repository, not in
bosnia). The owner chose bosnia (2026-11-18 01:17Z) and cleared an old PR (next sections). The owner's rule that the
new adoption must not reference the old one was given first in noodlebot issue #181 (filed as #183) and then
repeated in the answer on bosnia's issue #3 above.

## The plan PR's result

Plan PR #13 found no open issue that asks for work: the only open issues were #3 (the adoption's own issue) and #12
(the daily log). So it added no planned node, and it removed the `adoption` key and two passages of `SPEC.md` that
still called the adoption in progress. The 41 imported nodes and the gate were unchanged. Its reviewer approved at
once and said the `AGENTS.md` wording "in an area or in a node" can wait for an issue: it is not wrong, just no longer
reachable. The PR's own body says why it left the wording: `AGENTS.md` is outside the PR's spec files.

After the adoption, issues #14 to #17 and #21 were filed; `git log a6ba2b1..origin/main` in the clone shows each
became a spec PR, then a node PR, on bosnia's `main` (now 96d3345):

| Issue | Node | Spec PR | Node PR |
|---|---|---|---|
| #14 | B12 jwt-secret-guard | #18 | #24 |
| #15 | D05 kustomize-images | #19 | not found in the log (D05's branch `node/D05-kustomize-images` exists) |
| #16 | B13 doc-scripts | #20 | #25 |
| #17 | D06 pr-image-build | #22 | #26 |
| #21 | B14 start-script | #23 | #27 |

The issue numbers come from the commit subjects ("for issue #15", "for #16", ...). The owner's answer says the same
(B12 to B14, D05, D06). The log shows no commit for D05's node PR, only its spec PR; that is not checked further.

## The checkers on the final main

The clone's `HEAD` was a6ba2b1. Run from this repository, as `check-regime.py --root <clone>` and
`check-coverage.py --root <clone>` of the node skill (rerun for this record; the same output is in the run's log):

```
$ python3 -I plugin/skills/node/check-regime.py --root <bosnia clone at a6ba2b1>
41 nodes, 241 criteria
PROBLEMS 0
$ python3 -I plugin/skills/node/check-coverage.py --root <bosnia clone at a6ba2b1>
PROBLEMS 0
```

Both exit 0. On bosnia's main at 96d3345 (after B12 to B14, D05 and D06 were added): 46 nodes, 273 criteria, and
`PROBLEMS 0` from both checkers.

## What went wrong

The adoption wrote specs only, and `main` passes both checkers. Of the eight PRs, seven had an approving review
before they merged; #4 merged after five review rounds that were all "changes requested", with no approving review
(the owner merged it). The adoption cost many review rounds, and the record lists why.

1. **The old PR #1, and how it was cleared.** bosnia had an open PR #1, "Spec: adopt the repository into the graph
   regime" (bosnia PR #1, opened 2026-11-11, branch `spec/adopt` at e6dbe18). It came
   from the earlier one-shot `/adopt` and held a full 15-node plan with no `adoption` key. With it open, the loop
   would have taken it for the scaffold's own PR and never started the scaffold. Merging it would have skipped the
   area PRs. The owner closed it unmerged and renamed its branch to `old/adopt-2026-11-11` (still at e6dbe18), before
   bosnia's loop first started. `spec/adopt` was free for the first PR. The follow-up is noodlebot issue #184: the
   loop should report an open `spec/adopt` PR it did not open, not wait on it silently.
2. **The owner's rule, and the references to the old adoption that were found.** The owner's rule is above: the
   new adoption does not mention, link or draw on the old one, and a reference is a defect to fix in that PR.
   The first scaffold session (before the rule arrived) read PR #1's drafts and built most of its nine questions on
   them. References found in the adoption's own text:
   - Issue #3's question comment (2026-11-18T01:23Z): seven passages, among them "The closed PR #1 (branch
     `old/adopt-2026-11-11`) recorded your answers of 2026-11-11", "as on 2026-11-11", "carry OD1-OD10 from the
     closed PR's SPEC.md" and "Should `docs/AUDIT.md` from the closed PR come back?". They are still in that comment.
   - PR #10's bot comment (2026-11-19T02:13:57Z): "The two clauses that echoed PR #1".
   - PR #9's squash commit message (416c509): "A03's upload risk drops the abandoned adoption's wording". This is in
     bosnia's history.
   - Review findings of phrases that echoed the old drafts, removed in the PRs: #4 (rounds 2 and 3), #9 (rounds 1
     and 2) and #10 (round 2, two clauses). The owner's account counts three in #4 and two in #10.
   - None of this reached a file on `main`: `git grep` for `old/adopt`, `AUDIT.md`, `PR #1` and `2026-11-11` finds
     nothing at a6ba2b1 or at 96d3345, apart from an unrelated code comment "Provider seam #1" and a binary icon.
     This record checked the final PR bodies and bot comments of #4 to #13, not the histories of body edits.
3. **Reviews and merges** were by an agent session on the owner's account (see the top). The owner's account
   lists this as item 1.
4. **The area PRs overclaimed what their tests prove** (owner's item 3). The owner's account says
   mutation checks found criteria whose named test still passed with the behaviour broken in every area PR. The
   reviews show it in #7, #8, #9 and #10, a note about freezing another area's tests in #6, and a false criterion
   in #11, as the table below has it. #8 had nine in its first round. Each round
   narrowed the wording or marked the criterion `unpinned`. Some of the reviewer's own suggested wordings overclaimed
   too and were corrected next round.
5. **The `fail_pattern` evidence ran in an agent session** (owner's item 4). See the gate's history: vitest turns
   colour off in an agent session, so the check that CI's FAIL lines are uncoloured passed locally while #4's real CI
   log had 41 coloured lines. This cost four rounds on #4.
6. **The usage throttle stalled feedback rounds** (owner's item 5, not checked against the loop's own logs): sessions
   were held on the night of 2026-11-18 (about 23:43 to 01:13) and again on the afternoon of 2026-11-19. Running
   sessions continued.
7. **Misses on the reviewer's side** (owner's item 6): the reviewer's watcher followed only noodlebot and themonolith
   at first, so #4's round-3 push went unnoticed for two hours; a review agent filled `/tmp`, a 3.8 GB RAM disk, by
   copying a bosnia clone with `node_modules`. Neither touched bosnia's history.
8. **The plan step had nothing to plan** (owner's item 7): no open work issue, so no planned node. The gaps filed
   afterwards became B12 to B14, D05 and D06.
9. **#13's body ends with an attribution line after the bot's signature.** The template says every PR body ends with
   the signature line; the other adoption PR bodies do. No reviewer raised it.

Recurring review findings, by kind and the PRs that had them (classified from the reviews of #4 to #13; a PR counts
once per kind):

| Kind | PRs |
|---|---|
| Criterion's *Verify* names a test that does not fail when the claim breaks (found by mutation); including naming another area's tests, which freezes them | #7, #8, #9, #10 (the freezing note in #6) |
| False facts about the code in Purpose, Risks or criteria | #4, #6, #7, #8, #9, #10, #11 |
| Line wrapping (over 120 characters, one-word last lines, underfilled lines); two whole rounds for it alone (#7 round 3, #8 round 3) | #4, #6, #7, #8, #9, #10 |
| Missed risks | #6, #8, #9, #10 |
| The reviewer's own suggested wording, applied as given, caused the next round's finding | #7, #8, #9, #10 |
| References to or echoes of the old adoption | issue #3, #4, #9, #10 |
| Lists that read as complete but are not | #6, #8, #9 |
| PR body out of step with the files after a fix | #4, #6, #10 |
| Drafts that state the adoption's in-progress state and go stale ("lists no node yet", "in an area or in a node") | #6, #13 |
| `fail_pattern` does not match CI's output | #4 (four rounds) |
| Dependencies missing or not imports | #9, #10 |

False facts and missed risks are session content quality: the bulk of every round, and not a wording problem in the
skill. This record reports them and leaves them (see the last section).

## App bugs the adoption recorded as risks

These are real bugs in bosnia's code that the adoption did not fix (it writes specs only). They are risks in the node
specs for later nodes (owner's account; the reviews of #8 and #9 raise some of them as missed risks):

- `.env` precedence is backwards.
- Malformed requests give a 500 instead of a 4xx.
- The streak test fails between 00:00 and 01:00 UTC.
- The sign-in form stays on screen after a sign-in.

## Fixes this node makes

Each is a wording change in `plugin/skills/adopt/SKILL.md` (or the template), with its case in
`plugin/skills/adopt/adopt.test.sh` under the heading "A09 F<n>" (RED in fa1488c, GREEN in a9f1301).

- **F1**, criteria claim only what their test asserts (SKILL.md section 7, step 2, the Gate bullet): each pinned
  criterion is checked by breaking the behaviour in a scratch edit and restoring it; a clause no test catches is
  `unpinned`. Case: "A09 F1".
- **F2**, the first PR draws on no earlier attempt (section 1, next to "Read the issues, closed ones too"): a closed
  unmerged PR or a non-default branch is not the owner's intent, and is not read, recommended from, cited or copied.
  Case: "A09 F2".
- **F3**, the owner's first answers bind later steps (sections 7, 8 and 9, and `scheduler/unattended-adopt.md`, which
  names `@DIR@/../scaffold/answered/`). Case: "A09 F3".
- **F4**, `fail_pattern` must read CI's output (sections 1 and 3): probe with `CI=true` and the agent-session
  variables unset; AGENTS.md records the colour codes and the timestamp prefix a CI log adds. Case: "A09 F4".
- **F5**, the PR's title and body are updated wherever feedback makes them wrong (section 9, `--feedback`). Case:
  "A09 F5/F6".
- **F6**, a wording the feedback suggests is checked against the code before it is applied (section 9). Case:
  "A09 F5/F6".
- **F7**, the drafts state nothing the area or plan PRs make false (section 3, the drafts). Case: "A09 F7".
- **Review 1** (RED 071e3b3, GREEN ee29b2d): the prohibitions (the Never paragraph, section 7 step 5, section 9)
  except the scratch edits of section 7's check, reverted before any commit, and section 7 says how to undo one;
  the `Adopt <name>` issue is named where the owner's answers are; CI's colour codes and timestamp prefix are
  examples of what its lines may add; the branch this run works on is exempt from the earlier-attempt rule.
- **Review 2** (RED b6434f7 and the earlier ones, GREEN = 3a0433f, plus the rewrap 3c79dd9): the drafts come from the
  default branch, its merged PRs, the issues and the owner's answers, and from nothing else; CI's colour codes and
  timestamp prefix are examples, not facts about every repository; before the commit `git status` shows only spec
  files modified or staged (untracked files the gate run leaves do not count).
- **Review 3**: review 3 found clause reversals of F1, F4, F5 and F7 that the cases still let pass; commit 4c6ffa3
  adds cases that pass at the skill's current wording and fail under each of 59 mutations.

Problems reported elsewhere, not fixed here:

- The node skill's pass condition judges CI job logs whose lines carry a timestamp and colour codes, and the forge CLI
  cannot fetch a job log, so an adopt session cannot check a real CI log. Reported as noodlebot issue #211.
- `plugin/skills/adopt/example-baseline/SPEC.md` and `AGENTS.md` (the example of the earlier recorded run) carry the
  in-progress wording F7 forbids ("lists no node yet", "in an area or in a node"). bosnia's drafts took both phrases
  verbatim. Reported with the previous item.
- Session quality (false code facts, missed risks, line wrapping), the throttle stalls and the reviewer-side misses
  are left to this record. A larger change, an independent reviewer before each area PR is pushed, is not made here.
  Whether to add a line-width rule (no line over 120 characters) is the owner's decision; no rule exists in the skill.

## Not verified

- The record names PRs and issues in forge form (`github:tuckermclean/bosnia`, `#N`), not as links, because R02's
  rule (`scheduler/agnostic.test.sh`) forbids URLs under `plugin/`. This deviates from the usual PR links.
- The reviewer, merger and throttle statements are the owner's account; the PR data has no merger name.
- Merge times follow the forge's `merged_at`; the "about 37 hours" is the owner's figure and matches the first and
  last timestamps above.
- D05's node PR was not found in the data this record used. (#5 is the loop's daily log issue of 2026-11-18, checked
  with `issue view`.)
- That #4 had no approving review rests on its five reviews in the data, all "changes requested"; a review given
  outside the forge's review list would not show there.
- The owner's earlier answers (bosnia chosen, PR #1 cleared) are quoted from noodlebot's state, not from bosnia.
