"""Weekly report of issue-label hygiene across our GitHub repos (read-only).

Two sections:
  1. Claims without a PR: open issues labeled `status::in_progress` with no open pull request that
     closes them, with the time since the last heartbeat. A claim with no PR is work nobody can see.
  2. Missing type label: open issues with no `type::*` label (the label pickup and triage rely on).

Prints Markdown. Exits 1 when either section has entries, so a failing RWX run notifies; exits 0
when clean. Needs GITHUB_TOKEN with read access to issues on every repo. Rules: AGENT-LABELS.md.
"""

from __future__ import annotations

import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import stale_claim_sweeper as sweeper  # noqa: E402

TYPE_PREFIX = "type::"

QUERY = """
query($q: String!, $cursor: String) {
  search(query: $q, type: ISSUE, first: 50, after: $cursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on Issue {
        number
        title
        url
        repository { nameWithOwner }
        labels(first: 30) { nodes { name } }
        comments(last: 20) { nodes { createdAt body } }
        timelineItems(last: 50, itemTypes: [LABELED_EVENT]) {
          nodes { ... on LabeledEvent { createdAt label { name } } }
        }
        closedByPullRequestsReferences(first: 1, includeClosedPrs: false) {
          nodes { number }
        }
      }
    }
  }
}
"""


def label_names(issue: dict[str, Any]) -> set[str]:
    return {n["name"] for n in issue["labels"]["nodes"] if n}


def claim_without_pr(issue: dict[str, Any]) -> bool:
    return sweeper.CLAIM_LABEL in label_names(issue) and not sweeper.has_open_pr(issue)


def missing_type(issue: dict[str, Any]) -> bool:
    return not any(name.startswith(TYPE_PREFIX) for name in label_names(issue))


def fetch(token: str, extra: str) -> list[dict[str, Any]]:
    owners = " ".join(f"user:{o}" for o in sweeper.OWNERS)
    q = f"is:issue is:open archived:false {extra} {owners}"
    issues: list[dict[str, Any]] = []
    cursor = None
    while True:
        payload = sweeper.request(
            "POST", f"{sweeper.API}/graphql", token, {"query": QUERY, "variables": {"q": q, "cursor": cursor}}
        )
        if "errors" in payload:
            raise RuntimeError(f"GraphQL errors: {payload['errors']}")
        page = payload["data"]["search"]
        issues.extend(n for n in page["nodes"] if n)
        if not page["pageInfo"]["hasNextPage"]:
            return issues
        cursor = page["pageInfo"]["endCursor"]


def ref(issue: dict[str, Any]) -> str:
    return f"[{issue['repository']['nameWithOwner']}#{issue['number']}]({issue['url']}) {issue['title']}"


def render(claims: list[dict[str, Any]], untyped: list[dict[str, Any]], now: datetime) -> str:
    lines = ["# Issue label report", ""]
    lines.append(f"## Claims without an open PR ({len(claims)})")
    lines.append("")
    for issue in claims:
        beat = sweeper.heartbeat(issue)
        age = f"{(now - beat).total_seconds() / 3600:.0f}h since last heartbeat" if beat else "no datable heartbeat"
        lines.append(f"- {ref(issue)} ({age})")
    if not claims:
        lines.append("None.")
    lines += ["", f"## Open issues missing a `{TYPE_PREFIX}*` label ({len(untyped)})", ""]
    for issue in untyped:
        other = ", ".join(sorted(label_names(issue))) or "no labels"
        lines.append(f"- {ref(issue)} ({other})")
    if not untyped:
        lines.append("None.")
    return "\n".join(lines)


def main() -> int:
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        print("GITHUB_TOKEN is not set", file=sys.stderr)
        return 2
    now = datetime.now(timezone.utc)
    claims = [i for i in fetch(token, f'label:"{sweeper.CLAIM_LABEL}"') if claim_without_pr(i)]
    untyped = [i for i in fetch(token, "") if missing_type(i)]
    print(render(claims, untyped, now))
    return 1 if claims or untyped else 0


if __name__ == "__main__":
    sys.exit(main())
