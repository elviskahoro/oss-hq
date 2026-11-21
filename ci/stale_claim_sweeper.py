"""Flag abandoned agent claims across our GitHub repos.

Finds open issues labeled `status::in_progress` in the configured owners. A claim is stale when
it has had no heartbeat for STALE_HOURS and has no open pull request that closes the issue.
A stale claim is swapped from `status::in_progress` to `stale-claim` (so gh-dash surfaces it)
and gets one explanatory comment.

Heartbeat = latest of: the moment `status::in_progress` was applied, the newest comment, and the
newest commit on any branch linked to the issue. Label edits and reactions do not count.
Limits: only the last 50 label events and first 10 linked branches are read; an issue whose claim
event falls outside that window with no comments is treated as undatable and never flagged.
Race: activity landing between the fetch and the label swap is not seen; the posted comment tells the
claimant how to take the claim back.

Dry run by default; pass --apply to write. Needs GITHUB_TOKEN with issues:write on every repo.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from typing import Any

OWNERS = ("elviskahoro", "SanhedrinTech")
CLAIM_LABEL = "status::in_progress"
STALE_LABEL = "stale-claim"
STALE_HOURS = 48

API = "https://api.github.com"

QUERY = """
query($q: String!, $cursor: String) {
  search(query: $q, type: ISSUE, first: 50, after: $cursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on Issue {
        number
        url
        repository { nameWithOwner }
        comments(last: 1) { nodes { createdAt } }
        timelineItems(last: 50, itemTypes: [LABELED_EVENT]) {
          nodes { ... on LabeledEvent { createdAt label { name } } }
        }
        linkedBranches(first: 10) {
          nodes { ref { target { ... on Commit { committedDate } } } }
        }
        closedByPullRequestsReferences(first: 1, includeClosedPrs: false) {
          nodes { number }
        }
      }
    }
  }
}
"""


def parse_ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def heartbeat(issue: dict[str, Any]) -> datetime | None:
    """Newest sign of life on a claim, or None when nothing can be dated."""
    stamps: list[datetime] = []
    for event in issue["timelineItems"]["nodes"]:
        if event and event.get("label", {}).get("name") == CLAIM_LABEL:
            stamps.append(parse_ts(event["createdAt"]))
    for comment in issue["comments"]["nodes"]:
        stamps.append(parse_ts(comment["createdAt"]))
    for branch in issue["linkedBranches"]["nodes"]:
        target = ((branch or {}).get("ref") or {}).get("target") or {}
        if target.get("committedDate"):
            stamps.append(parse_ts(target["committedDate"]))
    return max(stamps) if stamps else None


def has_open_pr(issue: dict[str, Any]) -> bool:
    return bool(issue["closedByPullRequestsReferences"]["nodes"])


def is_stale(issue: dict[str, Any], now: datetime, stale_hours: int = STALE_HOURS) -> bool:
    if has_open_pr(issue):
        return False
    beat = heartbeat(issue)
    # Undatable claim: leave it alone rather than steal a possibly live one.
    return beat is not None and now - beat > timedelta(hours=stale_hours)


def request(method: str, url: str, token: str, body: dict[str, Any] | None = None) -> Any:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else None


def fetch_claims(token: str) -> list[dict[str, Any]]:
    owners = " ".join(f"user:{o}" for o in OWNERS)
    q = f'is:issue is:open label:"{CLAIM_LABEL}" {owners}'
    issues: list[dict[str, Any]] = []
    cursor = None
    while True:
        payload = request("POST", f"{API}/graphql", token, {"query": QUERY, "variables": {"q": q, "cursor": cursor}})
        if "errors" in payload:
            raise RuntimeError(f"GraphQL errors: {payload['errors']}")
        page = payload["data"]["search"]
        issues.extend(n for n in page["nodes"] if n)
        if not page["pageInfo"]["hasNextPage"]:
            return issues
        cursor = page["pageInfo"]["endCursor"]


def mark_stale(issue: dict[str, Any], beat: datetime, token: str) -> None:
    repo, number = issue["repository"]["nameWithOwner"], issue["number"]
    base = f"{API}/repos/{repo}/issues/{number}"
    # Comment first: if it fails nothing is flagged and the next run retries. If a later step fails
    # the retry re-comments (duplicate comment is the accepted cost; a missed flag would be worse).
    request(
        "POST",
        f"{base}/comments",
        token,
        {
            "body": (
                f"No activity since {beat:%Y-%m-%d %H:%M} UTC (over {STALE_HOURS}h) and no open PR "
                f"closes this issue. Swapped `{CLAIM_LABEL}` for `{STALE_LABEL}`: it is reclaimable. "
                f"If the previous claimant is still working, re-add `{CLAIM_LABEL}`, remove "
                f"`{STALE_LABEL}`, and comment."
            )
        },
    )
    request("POST", f"{base}/labels", token, {"labels": [STALE_LABEL]})
    try:
        request("DELETE", f"{base}/labels/{urllib.request.quote(CLAIM_LABEL, safe='')}", token)
    except urllib.error.HTTPError as err:
        if err.code != 404:  # already removed by someone else
            raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--apply", action="store_true", help="write changes (default is a dry run)")
    args = parser.parse_args()
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        print("GITHUB_TOKEN is not set", file=sys.stderr)
        return 2

    now = datetime.now(timezone.utc)
    claims = fetch_claims(token)
    failures = 0
    stale = 0
    for issue in claims:
        if not is_stale(issue, now):
            continue
        stale += 1
        beat = heartbeat(issue)
        assert beat is not None
        label = f"{issue['repository']['nameWithOwner']}#{issue['number']}"
        if not args.apply:
            print(f"would flag {label} (last heartbeat {beat:%Y-%m-%d %H:%M} UTC)")
            continue
        try:
            mark_stale(issue, beat, token)
            print(f"flagged {label}")
        except (urllib.error.URLError, OSError) as err:
            failures += 1
            print(f"FAILED {label}: {err}", file=sys.stderr)
    print(f"{len(claims)} claims checked, {stale} stale, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
