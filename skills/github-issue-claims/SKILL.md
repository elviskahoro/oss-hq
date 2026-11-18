---
name: github-issue-claims
description: Use before starting work on a GitHub issue, or when asked how sandbox agents signal that an issue is already being worked on. Defines the claim/status labels (`status::in_progress`, `claimed-by::<id>`, `needs-human`, `hold::*`, `stale-claim`), the claim-then-verify protocol, heartbeats, and stale-claim reclaim.
---

# GitHub issue claims for sandbox agents

Canonical, repo-adoptable version: [`AGENT-LABELS.md`](../../AGENT-LABELS.md).

Sandbox agents can't see each other. The only shared state is the issue: labels, comments, linked PRs. Labels are a **signal, not a lock**: GitHub has no compare-and-swap, so claim then verify.

Design follows [beads](https://github.com/gastownhall/beads) (claim = status + holder; `status::*` scoped labels as in its GitHub sync, `internal/github/mapping.go`) and Gas City (`hold:*` and `human` gate dispatch, `internal/beadmeta/hold_labels.go`). Studied at beads `126b30a` and gascity `e8547dc`. The label protocol itself is new; neither project implements it on GitHub.

## Labels

| Label | Meaning |
| --- | --- |
| `status::in_progress` | Claimed and being worked on. Don't pick up. |
| `claimed-by::<agent-id>` | Who holds the claim. Exactly one per issue. |
| `status::blocked` | Waiting on another issue. Body or comment must say `blocked by #N`. |
| `status::deferred` | Parked on purpose. Put the revisit date in a comment. |
| `needs-human` | A person must decide. Agents must not pick up. |
| `hold::external` | Do not dispatch (waiting on something outside the repo). |
| `agent-ready` | Optional: triaged, unblocked, safe to pick up. |
| `stale-claim` | Set by the reaper when a claim has no recent heartbeat. Claim is reclaimable. |

Open/closed is GitHub's native state. A linked open PR also means "in progress".

## Protocol

1. **Pick.** Open issue, none of `status::*`, `claimed-by::*`, `needs-human`, `hold::*`, no linked open PR. Prefer `agent-ready`.
2. **Claim.** Create `claimed-by::<id>` if missing (`gh label create "claimed-by::<id>" --color ededed --force`), add it and `status::in_progress`, then comment: id, branch, UTC time.
3. **Verify.** Re-read the issue. If more than one `claimed-by::*` exists, the winner is the claim whose current `labeled` event is earliest (per label, take its latest `labeled` event unless followed by `unlabeled`; a timestamp tie goes to the lexicographically smallest id; read `gh api --paginate repos/{o}/{r}/issues/{n}/timeline`). Losers remove only their own `claimed-by::<id>` label (leave `status::in_progress` for the winner) and pick another issue. Re-claiming with your own id is success.
4. **Heartbeat.** Comment about every 15 minutes. Before each, confirm your `claimed-by::` label is still there; if not, stop.
5. **Stale.** A scheduled reaper (not peer agents; not implemented yet, so ask a human about dead claims) marks `stale-claim` with a recovery comment after about 1 hour without activity, leaving the claim labels. An agent may take over a `stale-claim` issue: remove the old `claimed-by::<id>` and `stale-claim`, then use the claim steps.
6. **Release.** On finish, remove claim labels; the PR's `Closes #N` is the done signal. On failure, remove them and add `needs-human` or leave a comment with what was tried.

Queries: `gh issue list --state open --search '-label:"status::in_progress" -label:"status::blocked" -label:"status::deferred" -label:"needs-human" -label:"hold::external"'`. Search can't wildcard prefixes, so also reject any candidate with a `claimed-by::` or `hold::` label unless `stale-claim` is set. `stale-claim` issues are also pickable (`gh issue list --state open --label stale-claim`); take over per step 5.

Create the shared labels (see `AGENT-LABELS.md` §1) in a repo only when asked; check `gh label list` first. Creating your own `claimed-by::<id>` at claim time (step 2) is always allowed.
