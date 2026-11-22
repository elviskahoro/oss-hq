---
name: conductor-startup-script
description: Use when provisioning a Conductor cloud workspace with scripts/conductor-startup-script-cloud.sh, pasting it into another repo's setup field, setting its env vars (RWX_ACCESS_TOKEN), bumping a pin, or diagnosing a workspace that came up missing rwx/infisical/resend/railway/entire/uv. Code-dev tools (roborev, pytest, ruff, pyright, reflex) are not provisioned; they run on RWX.
---

# The Conductor startup script

`scripts/conductor-startup-script-cloud.sh` is the single provisioning script for every repo's cloud workspaces. It installs only the CLIs agents call directly (pinned, checksum-verified): rwx (plus token validation), infisical, resend, railway, entire (with `git-remote-entire`), and uv, plus the gws CLI (npm `@googleworkspace/cli`, credentials written from `GWS_CREDENTIALS` to `~/.config/gws/credentials.json`) and `gtm-linear`/`gtm-attio` (uv pip, version floors, not checksum-pinned; SKIP without npm/uv/sudo), plus Python 3.13 on the AL2023 sandbox class (its system python3 is 3.9; 3.13 is installed alongside it via dnf). Every stage failure is fatal: a missing CLI fails setup loudly (after all stages report). Code-dev tooling runs as RWX tasks (issue #185); see "Where the moved tools run".

For snapshot-build 403s or paste failures, use `conductor-cloud-startup-script-debugging`. To run the container test, use `run-startup-script-tests`.

## Where fixes land: here, never in the consuming repo

- This repo runs the script from its committed `.conductor/settings.toml`.
- Every other repo (gtm-sdk included) gets the script only because an operator pasted it into that repo's Conductor setup field. Conductor has no API for that field, so pasting is the only way in.
- gtm-sdk deliberately has no provisioning of its own (gtm-sdk#944 removed it). Never add a setup script there.
- A workspace that comes up missing tools is always a problem on this side of the paste: the pasted copy is stale, or an env var is unset. Fix it here, then re-paste or set the variable.

Diagnosing a sick pasted workspace:

| Symptom | Cause |
| --- | --- |
| Nothing resolves (`rwx`, `infisical`, …) | The paste is missing or stale. Re-paste the current script. |
| `rwx` resolves but is unauthenticated | `RWX_ACCESS_TOKEN` is unset or invalid (a WARN/FAIL row). |
| `pytest`/`ruff`/`roborev` missing | By design: run them on RWX. |

Paste-safety: the file must contain no triple double quotes and no backslash line continuations, because Conductor's TOML serialization breaks on them. `scripts/validate-pins.sh` enforces this in CI.

## Environment variables

Set these in the repo's Conductor environment variables, never inline in the script. `.env.cloud` is a template you can fill in and copy over.

- `RWX_ACCESS_TOKEN`: validated before it's written atomically to `~/.config/rwx/accesstoken`, so a bad token never overwrites a good one.

## Where the moved tools run

| Tool | Command |
| --- | --- |
| roborev | `rwx run .rwx/roborev.yml --wait` (needs secret `FIREWORKS_API_KEY`; pins live in that file) |
| pytest and the prompts/pin checks | `rwx run .rwx/test-prompts.yml --wait --fail-fast`, `rwx run .rwx/conductor-startup-script-cloud.yml --wait --fail-fast` |
| lint, type check, format (trunk, ruff, pyright, pyrefly) | trunk runs inside RWX tasks, never as a local launcher |
| one-off commands | `rwx sandbox exec -- <cmd>` |

Also in this repo: `.conductor/settings.toml` calls the script with no flags; `STARTUP_BEST_EFFORT`, `STARTUP_PY_DEV_TOOLS`, `ROBOREV_AGENT`, `ROBOREV_MODEL` and the sandbox's `FIREWORKS_API_KEY` are gone.

## Entire

`entire` and `git-remote-entire` land on PATH, and that's all. The script never runs `entire enable`, because that writes `.entire/settings.json` plus agent hook files, and committing those is a per-repo decision. To enable a repo, run `entire enable --agent <agent>` once and commit `.entire/settings.json` and `.entire/.gitignore`. For headless login, see `entire-device-login`.

Useful read-only queries: `entire status`, `entire checkpoint list`, `entire trail list --project gh/<owner>/<repo>`, `entire trail show <trail>`, `entire review --list`.

## uv and Python

- `uv` (and `uvx`) is the pinned release binary, installed in `/usr/local/bin`, with a `~/.local/bin` fallback when sudo isn't available. The Flox manifests' uv only exists inside an activation, so it doesn't count.
- Python 3.13 goes in alongside the system 3.9 and shadows only PATH lookups (`/usr/local/bin/python3`); dnf's absolute shebang keeps using 3.9. The container test asserts this.

## Pins

Pins live in the script's pins block. Always read the current values there, never from docs.

- A uv bump must change three things together: the startup script, `envs/prebuilt`, and `envs/floxhub-provision` (and their locks). `scripts/validate-pins.sh` cross-checks them.
- resend: `RESEND_PIN` plus per-platform sha256s from the release's `checksums.txt`; `validate-pins.sh` checks the shape.
- railway: `RAILWAY_PIN` plus per-platform sha256s from the release asset digests (`gh release view v<pin> -R railwayapp/cli --json assets`); `validate-pins.sh` checks the shape.
- roborev's pin lives in `.rwx/roborev.yml` and must match the two Flox manifests (`validate-pins.sh`).
- A working uv is reused as-is on re-runs, so a `UV_PIN` bump applies to fresh installs.
- Entire: `ENTIRE_PIN` plus a per-platform `ENTIRE_SHA256_*` constant for each platform. The re-pin runbook is in the pins block.

## Deferred stages (issue #40): proven, not wired in yet

| Stage | Executable reference |
| --- | --- |
| Flox bootstrap on Linux (dnf rpm, `/dev/fd`, hand-started `nix-daemon`, `~/.bashrc` self-heal) | `scripts/sandbox-test.sh` Stage 1; `FLOX_BOOTSTRAP_CMD` in `scripts/dagger_provision_test.py` |
| FloxHub token → `FLOX_FLOXHUB_TOKEN` | `scripts/floxhub-provision.sh` (see `floxhub-auth`) |
| Activate the host repo's committed Flox env | `FLOXHUB_ACTIVATE_DIR=<repo> bash scripts/floxhub-provision.sh` |

Until these are wired in, run the helpers by hand after the startup script.
