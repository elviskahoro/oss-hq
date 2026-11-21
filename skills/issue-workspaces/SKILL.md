---
name: issue-workspaces
description: Go through open issues for a subset of repos and open one Conductor workspace per issue with the create-pr prompt attached, all in an RWX + Dagger run. Use when asked to fan issues out to Conductor workspaces or work through open issues across repos.
---

# Issues -> Conductor workspaces

[`.rwx/dispatch-issues.yml`](../../.rwx/dispatch-issues.yml) runs `ci/main.py dispatch-issues` (Dagger). In a container it lists open issues (PRs excluded) per repo via the GitHub API ([`ci/issues_manifest.py`](../../ci/issues_manifest.py)), then creates one workspace per issue ([`ci/dispatch_issues.py`](../../ci/dispatch_issues.py)). Each starting message is the issue plus [`prompts/conductor/create-pr.md`](../../prompts/conductor/create-pr.md).

There is no installable `conductor` CLI in RWX (it's injected into Conductor workspaces). The pipeline calls the same endpoint the CLI wraps instead: `POST https://api.conductor.build/v0/workspaces` with `Authorization: Bearer $CONDUCTOR_API_KEY` and body `{repositoryUrl, name, agent, message}`. This is read from the CLI bundle, not a documented public API; if it breaks, compare with `/conductor/bin/conductor-cli.js` in a workspace.

## Secrets (RWX vault)

`GITHUB_ISSUES_TOKEN` (issues read on the repos) and `CONDUCTOR_API_KEY` (the value of `$CONDUCTOR_API_KEY` in a workspace). Export the right `RWX_ACCESS_TOKEN` first (see [`rwx`](../rwx/SKILL.md)).

## Steps

1. Confirm the repo subset with the user (`owner/name` list). Don't guess it.
2. Dry-run (default, no workspaces): `rwx run .rwx/dispatch-issues.yml --init repos="owner/a,owner/b" --wait`. Check the count and names in the logs.
3. Try one: add `--init limit=1 --init run=1`; check the workspace opened.
4. Fan out: `--init run=1` (optionally `--init label=<label>`).

## Untrusted issues

The issue text becomes the agent's starting message, so an outsider's issue could carry instructions for the agent. Only issues whose author is the repo `OWNER`, an org `MEMBER`, a `COLLABORATOR`, or an allowed bot (`TRUSTED_BOTS` in `ci/dispatch_issues.py`: `detail-app[bot]`) are dispatched (printed as `skip repo#n (author: NONE)` otherwise), and the message marks the issue title and body as data, not instructions.

## Skipped labels

Issues carrying any of these are skipped (printed as `skip repo#n (label: x)`): any `status::*` label, `needs-human`, `gas-city`. These are the "don't pick up" labels from [`AGENT-LABELS.md`](../../AGENT-LABELS.md). Override with `--init skip_labels=a,b*` (trailing `*` is a prefix match); the override replaces the defaults. `limit` applies after skipping.

## Notes

- Workspace names are `<repo>-issue-<n>`. A rerun creates duplicates, so track what has been dispatched.
- Many workspaces run agents in parallel and cost money; use `limit` and `label` to keep batches small.
- Unit tests: `rwx run .rwx/test-prompts.yml --wait --fail-fast` (`tests/test_issues_manifest.py`).
