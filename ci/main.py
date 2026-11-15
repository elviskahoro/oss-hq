"""Dagger program: report a finding to Linear (create or comment, deduped).

    LINEAR_API_KEY=... LINEAR_TEAM=AI REPORT_KEY=check-closed-issues \
    REPORT_TITLE="..." REPORT_BODY="..." uv run dagger run python ci/main.py linear-report

Dagger can't run in Conductor sandboxes; run it in RWX (.rwx/report-to-linear.yml).
The API key is passed as a Dagger Secret and never printed.
"""
from __future__ import annotations

import os
import sys

import anyio
import dagger
from dagger import dag

IMAGE = "python:3.12-slim"


async def linear_report() -> None:
    cfg = {k: os.environ[k] for k in ("LINEAR_TEAM", "REPORT_KEY", "REPORT_TITLE", "REPORT_BODY")}
    key = dag.set_secret("linear-api-key", os.environ["LINEAR_API_KEY"])
    script = dag.host().file("ci/linear_report.py")
    ctr = (
        dag.container().from_(IMAGE)
        .with_file("/ci/linear_report.py", script)
        .with_secret_variable("LINEAR_API_KEY", key)
    )
    for k, v in cfg.items():
        ctr = ctr.with_env_variable(k, v)
    print(await ctr.with_exec(["python", "/ci/linear_report.py"]).stdout())


COMMANDS = {"linear-report": linear_report}


async def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in COMMANDS:
        print(f"usage: main.py {{{'|'.join(COMMANDS)}}}", file=sys.stderr)
        return 2
    async with dagger.connection(dagger.Config(log_output=sys.stderr)):
        await COMMANDS[sys.argv[1]]()
    return 0


if __name__ == "__main__":
    sys.exit(anyio.run(main))
