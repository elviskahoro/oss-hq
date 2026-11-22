# AGENTS.md

Sandbox for provisioning Conductor cloud workspaces and the agent tooling around them (roborev, trunk, RWX, Flox). See [README.md](README.md) for the overview and the skill index; each task has a skill under [`skills/`](skills/). `CLAUDE.md` is a symlink to this file.

## Commits

After a change is verified (tests, `rwx run` for CI or lint config, render checks), commit it without waiting to be asked.

- Use Conventional Commits and end the message with the attribution line the session supplies (a system-reminder from the harness); if none is given, omit it.
- Do not push, merge, or open a PR unless asked.
- Never commit build output, caches, or secrets.
- This replaces the default "commit or push only when the user asks" for commits only; pushing still needs a request.

## RWX

Agents run CI on [RWX](https://www.rwx.com) before opening a PR. Full detail: [`skills/rwx/SKILL.md`](skills/rwx/SKILL.md).

### Authentication

- Check first: `rwx whoami`. The CLI reads `--access-token`, then `$RWX_ACCESS_TOKEN`, then `~/.config/rwx/accesstoken`. The cloud startup script validates `RWX_ACCESS_TOKEN` and writes that file ([`conductor-startup-script`](skills/conductor-startup-script/SKILL.md)).
- Tokens are scoped to one RWX organization. Injected vars are named `RWX_ACCESS_TOKEN_<OWNER>` / `RWC_ACCESS_TOKEN_<OWNER>`; list names only with `env | grep -E '^RW[XC]_ACCESS_TOKEN_.' | cut -d= -f1`. Before the first `rwx` command in a session, export the one matching the repo owner as `RWX_ACCESS_TOKEN` (snippet in the skill). A 403 or unauthorized means the token is unset or for the wrong org: re-export the right one and retry. IDs only resolve in the owning org, so switch tokens on not-found/unauthorized.
- Never print, log, or commit a token.

### What you can do

- Tests run on RWX, not locally: pytest isn't installed in Conductor sandboxes, so don't install it or skip tests. Export the owner's `RWX_ACCESS_TOKEN_<OWNER>` as `RWX_ACCESS_TOKEN`, then `rwx run .rwx/<file>.yml --wait --fail-fast` (e.g. `.rwx/test-prompts.yml` runs the pytest suite and the prompts-drift check); `rwx logs <task-id>` for failures. These are not a pre-push gate: the only pipeline required before a push is roborev; tests, trunk-check and integration run on the PR and are watched after the push (`gh pr checks <n> --watch`).
- `rwx run .rwx/<file>.yml --wait --fail-fast`: run CI on the working tree, uncommitted changes included, with no commit or push. `--target <task>` runs one task.
- `rwx results` / `rwx runs list` / `rwx logs`: see what failed and pull the logs. Fix and re-run until green, then open the PR.
- `rwx lint .rwx/<file>.yml`: validate after every edit to `.rwx/*.yml`.
- `rwx sandbox exec -- <cmd>`: persistent cloud sandbox for the inner loop.
- `rwx artifacts download`: fetch outputs, e.g. Dagger results (Dagger can't run in Conductor sandboxes; run it in an RWX task).
- `rwx image build|push`: build container images natively.
- `rwx docs search "<q>"` / `rwx docs pull <path>`: current docs. Use Bash, not WebFetch. Don't write `.rwx` YAML from memory; `rwx docs pull /migrating/rwx-reference` first.
- Migrating GitHub Actions: [`migrate-from-gha`](skills/migrate-from-gha/SKILL.md), then [`review-gha-migration`](skills/review-gha-migration/SKILL.md).

### Roborev pipeline

[`.rwx/roborev.yml`](.rwx/roborev.yml) is dispatch-only (`on: cli`; no PR check, comment or status) and needs secret `FIREWORKS_API_KEY`. The only way to run roborev: `rwx run .rwx/roborev.yml --wait`. It must match gtm-sdk's `.rwx/roborev.yml` (only repo name, clone URL, `GITHUB_REPOSITORY` differ); change both together. See [`skills/roborev-rwx/SKILL.md`](skills/roborev-rwx/SKILL.md).

### No-attribution check

[`.rwx/check-no-attribution.yml`](.rwx/check-no-attribution.yml) runs on PRs (and `rwx run`) and fails if the PR body or any commit has an AI attribution line (`🤖 Generated with Claude Code`, `Co-Authored-By: Claude`). Logic: [`scripts/check-no-attribution.sh`](scripts/check-no-attribution.sh).

### Fan-out across repos

[`scripts/dispatch-rwx-clone-repo.sh`](scripts/dispatch-rwx-clone-repo.sh) finds owner repos whose `.rwx/*.yml` use a task keyed `code` and dispatches one Conductor workspace per repo to rename it to `clone-repo` (PR via `prompts/conductor/create-pr.md`).

- Dry-run by default; `--run` creates workspaces. Pass explicit `repo` (or `repo=branch` for a `code` task only on an unmerged branch) to target one repo, e.g. `--run cmu-database-group-lectures`. Test on one repo before fanning out.
- Workspace names are `<short-repo>-rename_rwx_code_task` (`sdk-python-attio` -> `attio`, `cmu-database-group-lectures` -> `cmu`); add shortenings by the "Short repo label" comment in the script.
- Discovery scans default branches only and the pattern is loose; review matches before `--run`.

### Propagating prompt changes

Repos should hold pointers, not copies: `install-conductor-prompts.py --pointers` writes short stubs into a repo's `.conductor/settings.toml` that fetch `prompts/conductor/*.md` from oss-hq `main`, so a merge here reaches them with no re-install (the agent follows `main` unless a workspace sets `CONDUCTOR_PROMPTS_REF` to a SHA or tag, e.g. in `[environment_variables]`). Repos still holding embedded copies need a one-time migration: [`scripts/dispatch-conductor-prompts.sh`](scripts/dispatch-conductor-prompts.sh) opens one workspace per repo to run `--pointers` and PR it. Dry-run by default; `--run` creates workspaces (the `conductor` CLI is at `/Applications/Conductor.app/Contents/Resources/bin`). Discovery finds only default-branch settings with `create_pr`; pass repos to target some. oss-hq itself keeps embedded copies (self-hosting drift check).

### PR issue-link check

[`.rwx/check-pr-issue-link.yml`](.rwx/check-pr-issue-link.yml) (script [`scripts/check-pr-issue-link.sh`](scripts/check-pr-issue-link.sh)) fails a PR whose body has no `Closes|Fixes|Resolves #N`, `Refs #N` (partial work) or `No issue: <reason>`; bot PRs are skipped. It is what makes the claim release in the create-pr prompt hold. Other repos adopt it by copying the file with their own clone URL.

### Weekly label report

[`.rwx/claims-report.yml`](.rwx/claims-report.yml) (script [`ci/claims_report.py`](ci/claims_report.py), read-only, secret `GITHUB_ISSUES_TOKEN`) runs Mondays 14:00 UTC across our three owners and lists claims with no open PR and open issues with no `type::*` label as Markdown in the task log. It fails the run when anything is listed so the RWX failed-cron notification delivers it. On demand: `rwx run .rwx/claims-report.yml --wait`.

### Issues to workspaces

[`.rwx/dispatch-issues.yml`](.rwx/dispatch-issues.yml) (Dagger; secrets `GITHUB_ISSUES_TOKEN`, `CONDUCTOR_API_KEY`) lists open issues for given repos and opens a workspace per issue with the create-pr prompt via the Conductor API; dry-run unless `run=1`. See [`skills/issue-workspaces/SKILL.md`](skills/issue-workspaces/SKILL.md).

"Dispatch a workspace for every open issue" means the GitHub pipeline above, not the Linear inbox (the Linear MSG team's Triage is emails, not coding tasks). Confirm the repo list first, dry-run, try `limit=1`, then fan out. Skips: `status::*`, `gas-city`, untrusted authors; `needs-human` is dispatched plan-first for this user (see the skill).

### Tracking upstream issues

"Track this issue" (an issue in another repo we're waiting on) means: add it to the watchlist [`watched-issues.json`](watched-issues.json) as `{ "repo", "number", "why" }`. The `check-closed-issues` cron ([`.rwx/check-closed-issues.yml`](.rwx/check-closed-issues.yml)) fails when a watched item closes, and RWX notifies (see [`skills/rwx/SKILL.md`](skills/rwx/SKILL.md)). Do **not** open a tracking issue in this repo or use claim labels for this. Past mistake: an agent opened a redundant tracking issue (#189) because the instructions didn't say this. Filing the upstream issue itself is separate and only on request. Check the script with `python3 scripts/check-closed-issues.py watched-issues.json 2099-01-01T00:00:00Z`.

### Reporting to Linear

Reporting findings to Linear moved to the `ai` repo: `.rwx/report-to-linear.yml` there (`rwx run` it from `SanhedrinTech/ai`, with `--init repo=oss-hq`).

## Working issues and labels

Claim an issue before any work. Labels are a signal, not a lock. Canonical protocol (claim comment format `claim: <id> <branch> <UTC time>`, verify, takeover): [`AGENT-LABELS.md`](AGENT-LABELS.md); short version: [`skills/github-issue-claims`](skills/github-issue-claims/SKILL.md).

| Label | Meaning |
| --- | --- |
| `status::in_progress` | Claimed and being worked on by an agent. Do not pick up. |
| `status::blocked` | Waiting on another issue in this repo ("blocked by #N"). |
| `status::blocked-external` | Waiting on something outside the repo (another repo, upstream, a vendor). |
| `status::deferred` | Parked on purpose; revisit date is in a comment. |
| `needs-human` | A person must decide. Agents must not pick up. |
| `gas-city` | Routed to Gas City. Conductor dispatch must not pick up. |
| `stale-claim` | Claim has no recent heartbeat; reclaimable. |

### Picking up work

1. Never pick up an issue labeled `needs-human`, `status::in_progress`, `status::blocked`, `status::blocked-external`, `status::deferred`, or `gas-city`.
2. An issue labeled `stale-claim` may be reclaimed. Re-claim it and comment that you took over.

### Claiming (required before any work)

3. Claim first: add `status::in_progress`, assign yourself, and leave a one-line "starting" comment.
4. If `status::in_progress` is already present, stop. Two agents must never work one issue.
5. Re-read the labels right after claiming. If another agent claimed at the same moment, back off.
6. For long-running work, comment periodically so the claim does not become a `stale-claim`.

### Releasing

7. When done, put `Closes #N` in the PR body and remove `status::in_progress` once the PR is open. Merge closes the issue.
8. If you abandon or fail, remove `status::in_progress` and comment what happened and what remains. Never leave a dead claim.
9. If you need a decision you cannot make, remove `status::in_progress`, add `needs-human`, and comment the exact question. Do not guess. Never remove `needs-human` yourself.

### Blocked and deferred

10. Blocked by another issue in this repo: add `status::blocked`, comment "blocked by #N", and release the claim.
11. Blocked by something outside the repo: add `status::blocked-external`, comment what you are waiting on, and release the claim.
12. Never set `status::deferred` yourself. Only a human parks work.

### Visibility

13. gh-dash hides issues labeled `status::*` and `gas-city`, so label hygiene decides what humans see.
