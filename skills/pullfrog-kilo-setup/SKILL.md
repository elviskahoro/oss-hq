---
name: pullfrog-kilo-setup
description: Use when configuring Pullfrog to run on the Kilo gateway via its OpenAI-compatible provider, choosing a model, or debugging a Pullfrog run that cannot reach the model.
---

# Pullfrog + Kilo (OpenAI-compatible endpoint)

Pullfrog runs on RWX (`.rwx/pullfrog.yml`) with `INPUT_MODEL: openai-compatible/byok`. The endpoint settings are RWX vault vars in the `roborev` vault, shared with roborev, so switching model needs no repo change.

| Pullfrog env | Source |
|---|---|
| `OPENAI_COMPATIBLE_BASE_URL` | `vaults.roborev.vars.KILO_BASE_URL` (base only; do **not** append `/chat/completions`) |
| `OPENAI_COMPATIBLE_API_KEY` | `vaults.roborev.secrets.KILO_API_KEY` (exported in `run:`, not `env:`, so Semgrep's workflow-env-secret passes) |
| `OPENAI_COMPATIBLE_MODEL` | `vaults.roborev.vars.KILO_MODEL` (e.g. `deepseek/deepseek-v4-flash`) |
| `OPENAI_COMPATIBLE_HEADERS` | `X-KiloCode-OrganizationId: <vars.KILO_ORG_ID>` (bills the Kilo organization) |
| `OPENAI_COMPATIBLE_CONTEXT` / `_MAX_OUTPUT` | `vars.KILO_CONTEXT` / `vars.KILO_MAX_OUTPUT`; must be the model's real limits |

Reference implementation: elviskahoro/gtm-sdk `.rwx/pullfrog.yml` and `.rwx/roborev.yml`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Empty `KILO_API_KEY` on PR runs | the repo has no grant on the `roborev` vault for `main`, `refs/pull/**`, `refs/heads/**` |
| "agent did not call set_output" | model too weak or limits wrong; check `KILO_MODEL`, context and max-output |
| `GH_TOKEN` 403 on a private repo | vault GitHub App not installed there; use RWX `github.token` |
