---
name: paper-compute-sandbox
description: Use when capturing Claude Code sessions to Paper Compute from a Conductor cloud sandbox (paperctl/paperd install, headless login, routing claude through the 127.0.0.1:51539 proxy), or when `paperctl status` says "not logged in" or "blocked: no active org".
---

# Paper Compute session capture in a cloud sandbox

Source: issue #86. Paper routes `claude` requests through a local proxy so sessions show up in the Paper console. Docs: https://papercompute.com/docs/paper/cli/conductor

## Install and start the daemon

```bash
curl -fsSL https://download.papercompute.com/install | bash   # paperctl + paperd
setsid nohup paperd >/dev/null 2>&1 &                          # no systemd in the sandbox
paperctl status                                                # proxy 127.0.0.1:51539
```

## Authenticate

- `paperctl login --no-browser` prints a device code and URL. It needs a human to approve it in a browser, so it only works if the user approves it.
- Headless: `printf '%s' "$KEY" | paperctl login --org <org> --agent-key-stdin`. The key **must start with `paper_agent_`**. A key starting with anything else (e.g. `paper_c2tf…`) is a different credential type and is rejected with "not a Paper agent key". Create an agent key in https://console.papercompute.com.
- Keep the key in a Conductor env var (never inline in a script, never echoed or committed).

Healthy `paperctl status`: logged in, `gateway` not "blocked: no active org".

## Route Claude through the proxy

- Sandbox agents: run `paperctl start claude` instead of `claude`.
- Conductor app: set `ANTHROPIC_BASE_URL=http://127.0.0.1:51539` in Settings -> Environment.

## Known blocker (issue #86)

Capture stays off until a valid `paper_agent_*` key exists for the org. The startup script does not install Paper; do it per sandbox.
