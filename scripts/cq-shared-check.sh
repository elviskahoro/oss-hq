#!/usr/bin/env bash
# Check this sandbox is configured to share cq knowledge units via a remote.
# Never prints the API key. See skills/cq/SKILL.md ("Sharing KUs across sandboxes").
set -euo pipefail
command -v cq >/dev/null || { echo "cq not installed" >&2; exit 1; }
[ -n "${CQ_ADDR:-}" ] || { echo "CQ_ADDR unset: cq is local-only (per-sandbox)" >&2; exit 1; }
[ -n "${CQ_API_KEY:-}" ] || { echo "CQ_API_KEY unset: propose/confirm/flag will be rejected" >&2; exit 1; }
cq status >/dev/null && echo "remote reachable: $CQ_ADDR"
cq drain --dry-run >/dev/null && echo "data-plane key accepted (drain --dry-run ok)"
