---
name: roborev-rwx
description: Run roborev code review as an RWX CI pipeline, or copy that pipeline into another repo. Use when adding roborev to a repo's CI, bumping the pipeline's roborev/pi pins, or debugging a failing roborev RWX run.
---

# roborev on RWX

[`.rwx/roborev.yml`](../../.rwx/roborev.yml) installs pinned, checksum-verified roborev and pi (the same pins as `scripts/conductor-startup-script-cloud.sh`), then runs `roborev review --branch --wait` against the PR's base branch and fails the run if its output lists medium-or-higher findings. Fork PRs are unsupported: the clone only sees same-repo branches.

## Copy it to another repo

1. Copy `.rwx/roborev.yml` into the repo's `.rwx/`.
2. Change the `git/clone` `repository:` line and the CLI `base-branch` default if it is not `main` (both marked `CHANGE ME`). For a private repo, also add a `github-token` to that `git/clone` (see `rwx docs pull /docs/github-triggers`).
3. Commit a `.roborev.toml` with `agent` and `model` (copy this repo's; the `fireworks/` model prefix is required for pi).
4. Add RWX secret `FIREWORKS_API_KEY` in the repo's org (never inline it).
5. `rwx lint .rwx/roborev.yml`, then `rwx run .rwx/roborev.yml --wait --fail-fast`.

Using a different agent: change `agent` in `.roborev.toml`, drop or replace the `install-pi` task, and pass that agent's credentials in the `review` task's `env`.

## Bump pins

Change `ROBOREV_PIN` + sha256s in the install task, in the startup script, and in the Flox manifests together; `scripts/validate-pins.sh` fails CI if the pipeline's roborev pin/sha256s or pi pin/integrity drift from the startup script. Pi: new `PI_PIN` + `PI_INTEGRITY` from `npm view @earendil-works/pi-coding-agent@<v> dist`, and re-check the `node-version` floor against its `engines`.
