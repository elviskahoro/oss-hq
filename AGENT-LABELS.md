# Issue claim labels for agents

Read this from any repository to adopt the oss-hq issue-claim convention. Sandbox agents can't see each other; the only shared state is the issue (labels, comments, linked PRs). Labels are a **signal, not a lock**: GitHub has no compare-and-swap, so claim, then verify.

Canonical source: this file on oss-hq `main`; copies in other repos are snapshots, so link rather than copy. The skill [`skills/github-issue-claims`](skills/github-issue-claims/SKILL.md) is the short agent-facing version. Design basis: [beads](https://github.com/gastownhall/beads) (`status::*` scoped labels, claim = status + holder) and Gas City (`hold` and `human` gate dispatch). The GitHub protocol itself is new; neither project implements it.

## 1. Adopt it in your repo

Run once per repo. `--force` makes it idempotent (updates the color and description if the label exists). Do not delete a repo's existing labels unless its owner asks.

```bash
mk() { gh label create "$1" --color "$2" --description "$3" --force; }
mk "status::in_progress" fbca04 "Claimed and being worked on by an agent. Do not pick up."
mk "status::blocked"     b60205 "Waiting on another issue (see 'blocked by #N')."
mk "status::deferred"    c5def5 "Parked on purpose; revisit date in a comment."
mk "needs-human"         d93f0b "A person must decide. Agents must not pick up."
mk "hold::external"      5319e7 "Do not dispatch: waiting on something outside the repo."
mk "agent-ready"         0e8a16 "Triaged and safe for an agent to pick up."
mk "stale-claim"         e99695 "Claim has no recent heartbeat; reclaimable."
```

Then add this to the repo's `AGENTS.md`:

```markdown
## Issue claims
Before starting work on an issue, follow
https://github.com/elviskahoro/oss-hq/blob/main/AGENT-LABELS.md
```

## 2. Labels

| Label | Meaning |
| --- | --- |
| `status::in_progress` | Claimed and being worked on. Don't pick up. The holder (id, branch, UTC time) is in the claim comment. |
| `status::blocked` | Waiting on another issue. Body or comment must say `blocked by #N`. |
| `status::deferred` | Parked on purpose. Revisit date goes in a comment. |
| `needs-human` | A person must decide. Don't pick up. |
| `hold::external` | Do not dispatch; waiting on something outside the repo. |
| `agent-ready` | Optional: triaged, unblocked, safe to pick up. |
| `stale-claim` | Claim has no recent heartbeat; reclaimable. |

Open/closed is GitHub's native state. A linked open PR also means "in progress".

## 3. Protocol

1. **Pick.** Open issue with none of `status::*`, `needs-human`, `hold::*`, and no linked open PR. Prefer `agent-ready`.
   `gh issue list --state open --search '-label:"status::in_progress" -label:"status::blocked" -label:"status::deferred" -label:"needs-human" -label:"hold::external"'`
   Search can't wildcard prefixes, so also reject any candidate whose labels include a `hold::` entry. Issues labelled `stale-claim` are also pickable (`gh issue list --state open --label stale-claim`) even though they still carry `status::in_progress`; see step 5 for takeover.
2. **Claim.** Add `status::in_progress`, then comment `claim: <id> <branch> <UTC time>` as the first line. That comment records the holder; heartbeats must not start with `claim:`.
3. **Verify.** Re-read the issue's comments. If another claim comment predates yours, the earliest claim comment wins (claim comments older than the latest `stale-claim` `labeled` or `status::in_progress` `unlabeled` (release) event are void, so a takeover is judged only against claims made after it; read it with `gh api --paginate repos/{owner}/{repo}/issues/{n}/timeline`); if timestamps tie (1-second resolution), the lexicographically smallest id wins. Losers remove nothing (`status::in_progress` belongs to the winner) and pick something else. Re-claiming with your own id is success.
4. **Heartbeat.** Comment about every 15 minutes. First confirm `status::in_progress` is still present and your claim comment is still the winning, non-void claim; if not, stop.
5. **Stale.** A scheduled reaper (not peer agents) adds `stale-claim` and a recovery comment when the issue has `status::in_progress` and its last comment is about 1 hour old, leaving `status::in_progress` in place. An agent may take over a `stale-claim` issue: remove `stale-claim`, then do steps 2 and 3. The reaper is not implemented yet.
6. **Release.** On finish, remove `status::in_progress`; the PR's `Closes #N` is the done signal. On failure, remove it and add `needs-human` or comment what was tried.

## 4. Limits

- Two agents can briefly both claim; step 3 resolves it by comment order, which is best-effort (1-second timestamps, no atomicity). Keep work idempotent until verify passes.
- Heartbeats are comments, so they cost API calls and notifications. Keep the interval coarse.
- Nothing here is enforced by GitHub. Agents that don't read this file will ignore it.
