---
name: roborev-rwx
description: Run roborev code review as a dispatch-only RWX pipeline, or copy that pipeline into another repo. Use when adding roborev to a repo, bumping the pipeline's roborev/pi pins, or debugging a failing roborev RWX run.
---

# roborev on RWX

[`.rwx/roborev.yml`](../../.rwx/roborev.yml) is dispatch-only (`on: cli`): not a PR check, no comment or status. Run it with `rwx run .rwx/roborev.yml --wait`; this is the only way to run roborev. It installs pinned roborev (`ROBOREV_VERSION`) and pi (`PI_VERSION`), commits any uncommitted local work so roborev sees it, reviews `merge-base(origin/main, HEAD)..HEAD`, and fails closed: `roborev ci review` exits 0 even with findings, so the task greps for `roborev: Review Passed` and exits 1 if absent.

The logic is the `elviskahoro/roborev` package (`rwx-packages/roborev`); `.rwx/roborev.yml` only clones the repo and passes `repository`, the token and the vault values (a package cannot read vaults). The pullfrog gate is the sibling `elviskahoro/pullfrog` package with `.rwx/pullfrog.yml` (pools, trigger and status check stay in the wrapper). To change shared logic, edit the package, bump its version, run `rwx package build --publish` in its directory, then bump `call:` in the wrappers. To adopt in a repo, copy the wrapper and change `repository`, the clone URL and the pool-id prefix.

## Copy it to another repo

1. Copy `.rwx/roborev.yml`; change the clone `repository:` and `GITHUB_REPOSITORY`.
2. Commit a `.roborev.toml` with `agent` and `model` (the `kilo/` prefix is required for pi; `.rwx/roborev.yml` overrides the model from the `KILO_MODEL` var).
3. Grant the repo access to the `roborev` RWX vault (secret `KILO_API_KEY`, vars `KILO_*`; allow public repositories for public repos). Never inline the key.
4. `rwx lint .rwx/roborev.yml`, then `rwx run .rwx/roborev.yml --wait`.

## Bump pins

Change `ROBOREV_VERSION` / `ROBOREV_SHA256` / `PI_VERSION` in `rwx-packages/roborev/rwx-package.yml` (then publish a new package version) and the roborev pin in the Flox manifests together; `scripts/validate-pins.sh` fails CI on roborev drift (the startup script no longer pins roborev or pi). Re-check the pipeline's `node-version` against pi's `engines` by hand: CI no longer enforces it.
