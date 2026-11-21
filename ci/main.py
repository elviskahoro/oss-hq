"""Dagger program: dispatch open issues to Conductor workspaces.

    GITHUB_TOKEN=... uv run dagger run python ci/main.py dispatch-issues

Dagger can't run in Conductor sandboxes; run it in RWX (.rwx/dispatch-issues.yml).
"""
from __future__ import annotations

import os
import sys

import anyio
import dagger
from dagger import dag

IMAGE = "python:3.12-slim"


async def dispatch_issues() -> None:
    """List open issues and open a Conductor workspace per issue (dry-run unless DISPATCH_RUN=1)."""
    ctr = (
        dag.container().from_(IMAGE)
        .with_file("/ci/issues_manifest.py", dag.host().file("ci/issues_manifest.py"))
        .with_file("/ci/dispatch_issues.py", dag.host().file("ci/dispatch_issues.py"))
        .with_file("/ci/create-pr.md", dag.host().file("prompts/conductor/create-pr.md"))
        .with_secret_variable("GITHUB_TOKEN", dag.set_secret("github-token", os.environ["GITHUB_TOKEN"]))
        .with_env_variable("PR_TEMPLATE", "/ci/create-pr.md")
        .with_workdir("/ci")
    )
    for k in ("ISSUE_REPOS", "ISSUE_LABEL", "ISSUE_LIMIT", "DISPATCH_RUN", "SKIP_LABELS", "SKIP_NUMBERS"):
        ctr = ctr.with_env_variable(k, os.environ.get(k, ""))
    if os.environ.get("DISPATCH_RUN") == "1":
        key = dag.set_secret("conductor-api-key", os.environ["CONDUCTOR_API_KEY"])
        ctr = ctr.with_secret_variable("CONDUCTOR_API_KEY", key)
    print(await ctr.with_exec(["python", "/ci/dispatch_issues.py"]).stdout())


COMMANDS = {"dispatch-issues": dispatch_issues}


async def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in COMMANDS:
        print(f"usage: main.py {{{'|'.join(COMMANDS)}}}", file=sys.stderr)
        return 2
    async with dagger.connection(dagger.Config(log_output=sys.stderr)):
        await COMMANDS[sys.argv[1]]()
    return 0


if __name__ == "__main__":
    sys.exit(anyio.run(main))
