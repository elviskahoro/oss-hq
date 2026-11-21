---
name: github-issue-claims
description: Use before starting work on a GitHub issue, or when asked how sandbox agents signal that an issue is already being worked on. Defines the claim/status labels (`status::in_progress`, `status::blocked-external`, `needs-human`, `stale-claim`), the claim-then-verify protocol, heartbeats, and stale-claim reclaim.
---

# GitHub issue claims for sandbox agents

Canonical, repo-adoptable version: [`AGENT-LABELS.md`](../../AGENT-LABELS.md).

Sandbox agents can't see each other. The only shared state is the issue: labels, comments, linked PRs. Labels are a **signal, not a lock**: GitHub has no compare-and-swap, so claim then verify.

Design follows [beads](https://github.com/gastownhall/beads) (claim = status + holder; `status::*` scoped labels as in its GitHub sync, `internal/github/mapping.go`) and Gas City (`hold:*` and `human` gate dispatch, `internal/beadmeta/hold_labels.go`; we fold its holds into `status::*` rather than keeping a second family). Studied at beads `126b30a` and gascity `e8547dc`. The label protocol itself is new; neither project implements it on GitHub.

## Labels

| Label | Meaning |
| --- | --- |
| `status::in_progress` | Claimed and being worked on. Don't pick up. Holder is in the claim comment. |
| `status::blocked` | Waiting on another issue. Body or comment must say `blocked by #N`. |
| `status::deferred` | Parked on purpose. Put the revisit date in a comment. |
| `needs-human` | A person must decide. Agents must not pick these up on their own; when dispatched onto one at the user's direction, ask the user for the decision before proceeding. |
| `status::blocked-external` | Waiting on something outside the repo (another repo, upstream, a vendor). |
| `gas-city` | Routed to Gas City; Conductor dispatch skips it. |
| `stale-claim` | Set by the reaper when a claim has no recent heartbeat. Claim is reclaimable. |
| `type::*` | One per issue, named after its Conventional Commits type (`type::feat`, `type::fix`, `type::ci`, ...). Never gates pickup. |

Open/closed is GitHub's native state. A linked open PR also means "in progress".

## Protocol

1. **Pick.** Open issue, none of `status::*`, `needs-human`, `gas-city`, no linked open PR. (Autonomous pickup only; a user-directed dispatch onto `needs-human` asks the user first.)
2. **Claim.** Add `status::in_progress`, then comment `claim: <id> <branch> <UTC time>` as the first line (heartbeats must not start with `claim:`).
3. **Verify.** Re-read the comments. If another claim comment predates yours, the earliest wins (claim comments older than the latest `stale-claim` `labeled` or `status::in_progress` `unlabeled` (release) event are void, see `gh api --paginate repos/{o}/{r}/issues/{n}/timeline`; a timestamp tie goes to the lexicographically smallest id). Losers remove nothing and pick another issue. Re-claiming with your own id is success. Best-effort: timestamps have 1-second resolution.
4. **Heartbeat.** Comment about every 15 minutes (the reaper's threshold is 48h). Before each, confirm `status::in_progress` is still there and your claim comment is still the winning, non-void claim; if not, stop.
5. **Stale.** A scheduled reaper (not peer agents), `.rwx/stale-claim-sweeper.yml`, flags a claim stale after 48h with no heartbeat (claim label event or newest comment) and no open PR that closes the issue. It comments, adds `stale-claim`, and removes `status::in_progress`. An agent may take over a `stale-claim` issue: do steps 2 and 3. If your own claim was flagged and you are still working, re-add `status::in_progress`, remove `stale-claim`, and comment.
6. **Release.** On finish, remove `status::in_progress`; the PR's `Closes #N` is the done signal. On failure, remove it and add `needs-human` or leave a comment with what was tried.

Queries: `gh issue list --state open --search '-label:"status::in_progress" -label:"status::blocked" -label:"status::blocked-external" -label:"status::deferred" -label:"needs-human" -label:"gas-city"'`. Search can't wildcard prefixes, so also reject any candidate with another `status::` label. `stale-claim` issues are also pickable (`gh issue list --state open --label stale-claim`); take over per step 5.

Create the shared labels (see `AGENT-LABELS.md` §1) in a repo only when asked; check `gh label list` first.
