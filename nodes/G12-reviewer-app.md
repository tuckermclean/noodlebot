# G12 — reviewer-app

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G04, G11 | G13, S16 | M |

**Owns:** in `scheduler/forge.py`, the reviewer profile (`NOODLEBOT_FORGE_PROFILE=reviewer`, its token script variable
`NOODLEBOT_FORGE_REVIEWER_TOKEN_SCRIPT`, its login, its write allowlist and the refusal of any other write, and the
choice of profile), the operations `pr review`, `pr dismiss-review` and `pr head-ref` (their entries in the operation
table and the accepted forms of their arguments in G11's check) and the `draft` and `fork` keys of `pr view` and
`pr list`; in the GitHub backend (`scheduler/forges/github_review.py`, `scheduler/forges/github_pr.py`,
or a new part file that `scheduler/forges/github.py` compiles), those operations' calls; their rows in
`scheduler/forges/README.md`; in the fake forge `scheduler/testdata/forge/` (the world, `fake.py`, the fake `gh`
`fakegh.py` and their fixtures), reviews with a head and inline comments, dismissals, the draft flag, a PR's head ref
and a second identity; `scheduler/forge-g12.test.sh` (new) and its line in the `Makefile`'s `TESTS`; in `README.md`,
a new section "The reviewer App" (its settings, its install steps, `~/.config/noodlebot/reviewer-token` and
`~/.config/noodlebot/reviewer-login`);
`scheduler/readme-g12.test.sh` (new) and its line in the `Makefile`'s `TESTS`.
**Resolves:** #259

## Purpose
After this node the forge interface can act as a second identity, the reviewer App, which is a GitHub App separate
from `n00dl3b0t`. Its token comes from its own token script, and its client can do nothing but review. The interface
also gets the operations a reviewer needs and that core lacks today: posting one review at a given head with inline
comments, dismissing a review, a PR's draft and fork flags, and the ref that holds a PR's head. `n00dl3b0t`'s default profile is
unchanged. The README tells the owner how to create and install the App.

## Tests
- `scheduler/forge-g12.test.sh` (new), run against both backends as G04's conformance suite is (the GitHub backend
  over the fake `gh`, and the fake forge), through the Python interface and the CLI's JSON:
  - `pr review --number N --commit SHA --event APPROVE|REQUEST_CHANGES|COMMENT --body-file F [--comments-file C]`
    creates one review whose `commit_id` is `SHA`, with one inline comment per entry of `C` (`path`, `line`, `side`,
    `body`), and returns its id, state, head and URL. `pr reviews` then reads it back with its `commit` and state.
  - An inline comment on a line outside the PR's diff is a failed call (exit 1) naming the comment, and no review is
    left half posted.
  - `pr dismiss-review --number N --review ID --message M` dismisses that review.
  - `pr view` and `pr list` give `draft` (true or false) and `fork` (true when the PR's head branch is in another
    repository than the base, for GitHub `isCrossRepository`).
  - `pr head-ref --number N` gives a ref on the base repository that `git fetch` reads the PR's head from (for
    GitHub `refs/pull/<N>/head`, a fork's PR included).
  - With `NOODLEBOT_FORGE_PROFILE=reviewer`, the token comes from the script named by
    `NOODLEBOT_FORGE_REVIEWER_TOKEN_SCRIPT` and never from `NOODLEBOT_FORGE_TOKEN_SCRIPT` or a `GH_TOKEN` in the
    caller's environment. The token is in no argv, output, log or error text (G04-AC-3's check, with a marker token).
  - Under the reviewer profile, every write outside the allowlist exits 4 with `reviewer profile refuses <op>` before
    anything is sent: the fake `gh` records no call and the fake forge's world is unchanged. That covers `pr create`,
    `pr edit`, `pr close`, `pr comment`, `issue create`, `issue edit`, `issue comment`, `issue close`, `label add`,
    `label ensure`, `branch push`, `ci rerun` and every other write in the operation table. The allowlist is
    `pr review`, `pr reply`, `pr resolve-thread` and `pr dismiss-review`. A read is allowed.
  - Under the reviewer profile, `pr reply` and `pr resolve-thread` on a thread the reviewer did not start, and
    `pr dismiss-review` on a review by another author, exit 4 before the write is sent. The thread's or review's author
    is read first and compared with the login in `~/.config/noodlebot/reviewer-login` (a path the profile takes from
    `NOODLEBOT_FORGE_REVIEWER_LOGIN`). With that file missing or empty, `pr reply`, `pr resolve-thread` and
    `pr dismiss-review` exit 4 with `reviewer profile has no login` before anything is read or sent.
  - `NOODLEBOT_FORGE_PROFILE` unset or empty is the default profile; any value other than `reviewer` exits 2 with
    `unknown forge profile <value>` before any call, on both backends.
  - The new arguments (`pr review --commit`, `pr dismiss-review --review`, `pr head-ref --number` and the others of
    the new operations) each have an accepted form in G11's check, so G11's sweep, which reads the operation table,
    finds no hostile value reaching a request path through them.
  - The reviewer profile with no token script, or with a script that fails, exits 1 with `no reviewer App token` and
    never falls back to the default profile's token.
  - The default profile's behaviour and the existing conformance cases are unchanged.
  - The README rows of the new operations have four filled cells (G04-AC-8's check).
- `scheduler/readme-g12.test.sh` (new): `README.md`'s "The reviewer App" section names the App's permissions exactly
  (Pull requests read and write; Contents, Checks, Commit statuses, Actions, Issues and Metadata read; nothing else),
  the install on the repositories in `~/.config/noodlebot/repos`, the token script `~/.config/noodlebot/reviewer-token`
  (mode 700, printing the installation token for `<owner/name>` as the existing token script does), the login file
  `~/.config/noodlebot/reviewer-login` (holding the App's `<slug>[bot]` login), and what the reviewer does until the
  script works and until the login file exists. The "Reviewing and merging
  PRs" section's principle line (written by #259's spec change) carries principle 1's wording as `SPEC.md` §1 has it, so
  the two cannot drift apart. Each case checks one statement within one sentence
  or one window of lines.

## Changes
1. **The operations.** `forge.py` gets `pr review` (number, commit, event, body, comments), `pr dismiss-review`
   (number, review, message) and `pr head-ref` (number), and `draft` and `fork` in a PR's keys. Each new argument gets
   its accepted form in G11's check (`commit checks --sha`'s form, 4 to 64 hex digits, for `--commit`, a positive number for `--number`
   and `--review`, the event's three words for `--event`). The GitHub backend posts the review in one call with
   `commit_id` and its inline comments, so a refused inline comment leaves no review behind. *G12-AC-1.*
2. **The reviewer profile.** `NOODLEBOT_FORGE_PROFILE=reviewer` selects the reviewer's token script
   (`NOODLEBOT_FORGE_REVIEWER_TOKEN_SCRIPT`) and login file (`NOODLEBOT_FORGE_REVIEWER_LOGIN`). The profile holds a
   fixed write allowlist, checked in `forge.py` before the backend is called, so every backend gets it. A reply,
   resolve or dismiss is checked against the item's author first, and refused without the login file. The profile is
   never chosen by default: an unset or empty `NOODLEBOT_FORGE_PROFILE` is the default profile and any other value but
   `reviewer` exits 2. Nothing in the profile reads `NOODLEBOT_FORGE_TOKEN_SCRIPT`. *G12-AC-2, G12-AC-3, G12-AC-5.*
3. **The fake forge.** Its world holds reviews with a head and inline comments, dismissals, draft PRs, head refs and a
   second identity (the reviewer's login), and the fake `gh` serves the matching endpoints and records every call.
   *G12-AC-1, G12-AC-2.*
4. **The README.** A section "The reviewer App" gives the App's exact settings (name of the owner's choice, no
   webhook, the permissions above), its install on the repositories in `~/.config/noodlebot/repos`, the token script
   and the login file, which holds the App's `<slug>[bot]` login. It says that until the script works the reviewer
   logs `no reviewer App token; nothing reviewed`, and until the login file exists `no reviewer App login; nothing
   reviewed`, and nothing else is held up. *G12-AC-4.*

## Gate
- **G12-AC-1** — `pr review` creates one review at the given head with its inline comments and `pr reviews` reads it back with that head; an inline comment outside the diff fails the call and leaves no review; `pr dismiss-review` dismisses a review; `pr view` and `pr list` give `draft` and `fork`; `pr head-ref` gives a ref `git fetch` reads the PR's head from; the same from the GitHub backend over the fake `gh` and from the fake forge, through the interface and the CLI, with the README's rows filled; and every argument of the new operations has its accepted form in G11's check, so G11's sweep passes over them. *Verify:* `sh scheduler/forge-g12.test.sh` and `sh scheduler/forge-g11.test.sh`.
- **G12-AC-2** — Under `NOODLEBOT_FORGE_PROFILE=reviewer` every write outside `pr review`, `pr reply`, `pr resolve-thread` and `pr dismiss-review` (merge, push, label, issue, PR edit or comment, CI rerun among them) exits 4 naming the operation with no call sent and the fake world unchanged, and a reply, resolve or dismiss of an item the reviewer's login did not write, or any reply, resolve or dismiss while the login file is missing or empty, exits 4 the same way. *Verify:* `sh scheduler/forge-g12.test.sh`.
- **G12-AC-3** — The reviewer profile's token comes only from its own token script, appears in no argv, output, log or error text, and a missing or failing script exits 1 with `no reviewer App token` without using the default profile's token; the default profile and the existing conformance suite are unchanged. *Verify:* `sh scheduler/forge-g12.test.sh` and `sh scheduler/forge.test.sh`.
- **G12-AC-4** — `README.md` gives the reviewer App's exact permissions, its install steps, its token script and login file (holding the App's `<slug>[bot]` login) and what happens until the script and the login file are there, and its "Reviewing and merging PRs" line carries principle 1 as `SPEC.md` §1 has it. *Verify:* `sh scheduler/readme-g12.test.sh`.
- **G12-AC-5** — An unset or empty `NOODLEBOT_FORGE_PROFILE` is the default profile, and any other value but `reviewer` exits 2 with `unknown forge profile <value>` before any call, on the GitHub backend over the fake `gh` and on the fake forge. *Verify:* `sh scheduler/forge-g12.test.sh`.

## Risks
- GitHub's review API rejects the whole review when one inline comment's position is not in the diff. Change 1 keeps
  that all-or-nothing behaviour, and S16 places only diff lines inline. The fake `gh` must reject the same way, or the
  tests pass on a behaviour GitHub does not have.
- The allowlist checks the author of a thread or review with a read before the write, so a race (the item's author
  changing) cannot happen on GitHub, but it costs one call per write.
- The App's settings and install are the owner's steps. The README can be wrong about GitHub's settings page, and
  only the owner's first install shows it.
- A GitHub App's review is expected to count toward branch protection's required approvals, even with Contents read
  only; issue #175 verifies it on the owner's first install. This node changes no branch protection
  (principle 1). Under principle 1 the reviewer's approval at a head is one point of the auto-gate (issue #175), which
  this node does not build: until that gate exists an approval merges nothing.
