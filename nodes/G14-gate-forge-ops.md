# G14 — gate-forge-ops

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G04, G11 | G15 | M |

**Owns:** in `scheduler/forge.py`, the operations `pr auto-merge`, `pr auto-merge-off`, `pr files`, `commit status`,
`commit statuses` and `branch protection`, the capabilities `auto_merge` and `commit_status` (their entries in the
operation table and in `CAPABILITIES`), the `auto_merge` and `labels` keys of `pr view` and `pr list`, and the accepted
forms of the new arguments in G11's check; in the GitHub backend (`scheduler/forges/github_pr.py`,
`scheduler/forges/github_issue.py`, or a new part file that `scheduler/forges/github.py` compiles), those operations'
calls and the mapping of a refusal to the capability off; their rows in `scheduler/forges/README.md`; in the fake forge
`scheduler/testdata/forge/` (the world, `fake.py`, the fake `gh` `fakegh.py` and their fixtures), a PR's auto-merge
state, labels and changed files, commit statuses with their creator, and a branch's required checks and reviews;
`scheduler/forge-g14.test.sh` (new) and its line in the `Makefile`'s `TESTS`; the recorded run of G14-AC-6 in the node
PR.
**Resolves:** #175

## Purpose
After this node the forge interface can do what an auto-gate needs (G15) and core lacks today. It can turn a PR's squash
auto-merge on only while the PR's head is a given commit, and turn it off. It can list a PR's changed files and its
labels, and say whether auto-merge is on. It can set a commit status on one commit and read a commit's statuses with
who set them. It can say what the base branch requires before a merge: the status checks (and which App must set each
one), the approving reviews, whether a push dismisses them, and whether the repository allows squash auto-merge.
Nothing here merges a PR or changes a setting: the forge merges, under the rules the owner sets.

## Tests
- `scheduler/forge-g14.test.sh` (new), run against both backends as G04's conformance suite is (the GitHub backend over
  the fake `gh`, and the fake forge), through the Python interface and the CLI's JSON:
  - `pr auto-merge --number N --head <sha>` on a PR whose head is `<sha>` and that is not yet mergeable turns squash
    auto-merge on and prints `{"number": N, "auto_merge": {"method": "squash", "enabled_by": "<login>"}}`; `pr view`
    then gives the same `auto_merge`. The fake `gh` recorded one GraphQL `enablePullRequestAutoMerge` call with
    `mergeMethod: SQUASH` and `expectedHeadOid` set to `<sha>`, the PR's node id and the sha as GraphQL variables (no
    value spliced into the query text). A PR whose head is another sha exits 1 with one stderr line naming both shas,
    and auto-merge stays off. A PR the forge reports as already mergeable (GitHub's "clean status") exits 1 with the
    forge's message and no result. A repository that does not allow auto-merge, and a fake forge configured without
    `auto_merge`, exit 3 with `forge <name> lacks auto_merge` and change nothing.
  - `pr auto-merge-off --number N` turns it off and prints `{"number": N, "auto_merge": null}`; on a PR with auto-merge
    off it prints the same and exits 0.
  - `pr view` and `pr list` give `auto_merge` (null when off) and `labels` (the label names, sorted) for each PR; the
    keys every caller reads today are unchanged.
  - `pr files --number N` gives `{"files": [{"path", "status", "previous_path"}], "complete": true}` over every page of
    the forge's answer; a rename gives both paths; a PR whose file count passes what the forge lists (GitHub: 3000)
    gives `complete` false.
  - `commit status --sha <sha> --context <c> --state success|failure|pending|error --description <d>` sets one status
    and prints it; `commit statuses --sha <sha>` gives the latest status of each context with `context`, `state`,
    `description`, `created_at` and `creator` (login and the forge's bot flag). A status refused with 403, and a fake
    forge configured without `commit_status`, exit 3 with `forge <name> lacks commit_status`.
  - `branch protection --branch <b>` gives `required_checks` (each `context` with the `app` that must set it, or null
    when any source may), `required_approvals`, `dismiss_stale`, `allow_auto_merge` and `allow_squash_merge`, read from
    the branch's active rules (`rules/branches/<b>`) and the repository's settings; a rule the token may not read gives
    the field `"unknown"`, never a guess.
  - A `--sha` that is not 7 to 40 hex characters, a `--context` outside `[A-Za-z0-9._/-]{1,100}`, a `--state` outside
    the four, a `--description` over 140 characters or holding a control character, and a `--branch` that G11's branch
    check refuses each exit 2 from the CLI with one stderr line naming the option and nothing on stdout, and raise from
    the Python interface, with no call to either backend; G11's sweep passes over the new operations.
  - G04's, G08's, G10's and G11's cases pass unchanged.
- The recorded run of G14-AC-6.

## Changes
1. **The operations.** `forge.py` gets `("pr auto-merge", "auto_merge", {"number": "int!", "head": "str!"})`,
   `("pr auto-merge-off", "auto_merge", {"number": "int!"})`, `("pr files", None, {"number": "int!"})`,
   `("commit status", "commit_status", {"sha": "str!", "context": "str!", "state": "str!", "description": "str!"})`,
   `("commit statuses", None, {"sha": "str!"})` and `("branch protection", None, {"branch": "str!"})`, `auto_merge` and
   `commit_status` in `CAPABILITIES`, and the accepted forms above in G11's check table. There is no merge operation,
   and auto-merge has no method option: it is always squash, as the repository's conventions merge node PRs.
   *G14-AC-1, G14-AC-4, G14-AC-5.*
2. **The GitHub backend.** Auto-merge on and off are the GraphQL mutations `enablePullRequestAutoMerge` (with
   `mergeMethod: SQUASH` and `expectedHeadOid`, so GitHub itself refuses another head) and
   `disablePullRequestAutoMerge`, with every value passed as a variable. A refusal because the repository does not allow
   auto-merge is the capability off (exit 3); any other refusal, "clean status" included, is a failed call (exit 1)
   carrying the forge's message. `pr view` and `pr list` read `auto_merge` and `labels` from the PR's REST answer.
   `pr files` pages `pulls/<N>/files`. `commit status` posts to `statuses/<sha>`; `commit statuses` reads
   `commits/<sha>/status` and keeps each context's latest status with its creator. `branch protection` reads
   `rules/branches/<b>` (the `required_status_checks` rule's contexts and `integration_id`, the `pull_request` rule's
   `required_approving_review_count` and `dismiss_stale_reviews_on_push`) and the repository's `allow_auto_merge` and
   `allow_squash_merge`. The README's rows give GitHub's, GitLab's, Gitea's and Forgejo's calls, each linked to its API
   documentation. *G14-AC-1, G14-AC-2, G14-AC-3, G14-AC-4.*
3. **The fake forge.** Its world holds a PR's auto-merge state, labels and changed files, commit statuses with their
   creator, a branch's rules and the repository's merge settings, and can refuse auto-merge (not allowed, clean status)
   and statuses. The fake `gh` serves the GraphQL mutations and the REST endpoints above from fixtures and records each
   call with its variables and fields. *G14-AC-1 to G14-AC-5.*
4. **The live record.** Through the session's forge CLI on this repository: `branch protection --branch main`,
   `commit statuses` on the node PR's head, and `pr view` of the node PR with its `auto_merge` and `labels`; each
   command, exit code and output is recorded in the PR. No auto-merge is turned on and no status is set live: G15's
   own run is the first that does. *G14-AC-6.*

## Gate
- **G14-AC-1** — `pr auto-merge --number N --head <sha>` turns squash auto-merge on for a PR whose head is `<sha>`, through one GraphQL `enablePullRequestAutoMerge` call with `mergeMethod: SQUASH`, `expectedHeadOid` `<sha>` and every value as a variable, and prints the PR's `auto_merge`; a PR at another head exits 1 naming both shas with auto-merge still off; a PR the forge reports as already mergeable exits 1 with the forge's message and no result; `pr auto-merge-off` turns it off and prints `auto_merge` null, also for a PR with it already off; the same from the GitHub backend over the fake `gh` and from the fake forge, through the interface and the CLI, with the README's rows filled. *Verify:* `sh scheduler/forge-g14.test.sh`.
- **G14-AC-2** — `pr view` and `pr list` give `auto_merge` (null when off, else its method and who turned it on) and `labels` (sorted names) for every PR, and `pr files` gives every changed path over all pages, both paths of a rename, and `complete` false when the forge lists fewer files than the PR changes; the keys the loop and its helpers read today are unchanged. *Verify:* `sh scheduler/forge-g14.test.sh`.
- **G14-AC-3** — `commit status` sets one status on the given sha and prints it, and `commit statuses` gives each context's latest status at a sha with its state, description, time and creator (login and bot flag); `branch protection` gives the branch's required checks with the App each must come from, its required approving reviews, whether a push dismisses them and whether the repository allows auto-merge and squash merges, and `"unknown"` for a part the token may not read. *Verify:* `sh scheduler/forge-g14.test.sh`.
- **G14-AC-4** — A repository that does not allow auto-merge, a status the forge refuses with 403, and a fake forge configured without `auto_merge` or `commit_status` each exit 3 naming the capability, change nothing and print no result; and G04's, G08's, G10's and G11's cases pass unchanged. *Verify:* `sh scheduler/forge-g14.test.sh` and `sh scheduler/forge.test.sh`.
- **G14-AC-5** — A `--sha` that is not 7 to 40 hex characters, a `--context` outside `[A-Za-z0-9._/-]{1,100}`, a `--state` other than `success`, `failure`, `pending` or `error`, a `--description` over 140 characters or holding a control character, and a `--branch` G11's branch check refuses each exit 2 from the CLI with one stderr line naming the option and nothing on stdout, and raise from the Python interface, with no call to either backend; and G11's sweep of every operation's arguments passes with the new operations in it. *Verify:* `sh scheduler/forge-g14.test.sh` and `sh scheduler/forge-g11.test.sh`.
- **G14-AC-6** — Through the session's forge CLI (the App token) on this repository, `branch protection --branch main`, `commit statuses --sha <the node PR's head>` and `pr view --number <the node PR>` exit 0 with the fields G14-AC-2 and G14-AC-3 name, or a field is `"unknown"` because the token may not read it, and that output is recorded with the permission the owner would grant; no auto-merge is turned on and no status is set. *Verify:* the recorded commands, exit codes and outputs in the PR.

## Risks
- GitHub accepts `enablePullRequestAutoMerge` only for a PR that cannot merge yet; a clean PR is refused. G15 relies on
  a required status that only it sets, so the PR is never clean when it turns auto-merge on.
- `expectedHeadOid` makes GitHub refuse the call when the head moved, but a push after the call is not covered by it: a
  new head keeps auto-merge on. G15 turns it off when the head moves, and the required status, set per sha, keeps a new
  head from merging meanwhile.
- The App's token needs "Commit statuses: Read and write" to set a status, and reading the rules needs "Metadata" and
  "Administration: Read" for classic branch protection, which this node does not read (rules only). G14-AC-6 records
  what the token reads today.
- The new writes (`pr auto-merge`, `pr auto-merge-off`, `commit status`) must be refused under any narrower forge
  profile a later or parallel node adds (the reviewer App's, #259); if such a profile is on `main` when this node is
  built, its refusal covers them.
- `scheduler/agnostic.test.sh` keeps every `gh` call and GitHub URL in the backend (R02-AC-2).
