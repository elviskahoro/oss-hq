#!/usr/bin/env python3
"""Create or comment on a Linear issue, deduped by a stable key.

Env: LINEAR_API_KEY (never printed), LINEAR_TEAM (key, e.g. AI),
REPORT_KEY (stable dedupe key), REPORT_TITLE, REPORT_BODY.
The issue title is "[<REPORT_KEY>] <REPORT_TITLE>"; an open issue whose title
starts with "[<REPORT_KEY>]" gets a comment, otherwise a new issue is created.
"""
import json
import os
import sys
import urllib.request

API = "https://api.linear.app/graphql"


def gql(query, variables):
    req = urllib.request.Request(
        API,
        data=json.dumps({"query": query, "variables": variables}).encode(),
        headers={"Content-Type": "application/json", "Authorization": os.environ["LINEAR_API_KEY"]},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.load(r)
    if out.get("errors"):
        raise RuntimeError(f"Linear API error: {out['errors']}")
    return out["data"]


def find_open(team, key):
    data = gql(
        """query($team: String!, $q: String!) { issues(first: 10, filter: {
            team: {key: {eq: $team}}, title: {startsWith: $q},
            state: {type: {nin: ["completed", "canceled"]}}}) { nodes { id identifier url } } }""",
        {"team": team, "q": f"[{key}]"},
    )
    nodes = data["issues"]["nodes"]
    return nodes[0] if nodes else None


def report(team, key, title, body):
    existing = find_open(team, key)
    if existing:
        gql("mutation($id: String!, $b: String!) { commentCreate(input: {issueId: $id, body: $b}) { success } }",
            {"id": existing["id"], "b": body})
        return f"commented on {existing['identifier']} {existing['url']}"
    teams = gql("query($k: String!) { teams(filter: {key: {eq: $k}}) { nodes { id } } }", {"k": team})
    tid = teams["teams"]["nodes"][0]["id"]
    res = gql(
        """mutation($t: String!, $title: String!, $d: String!) { issueCreate(input:
            {teamId: $t, title: $title, description: $d}) { issue { identifier url } } }""",
        {"t": tid, "title": f"[{key}] {title}", "d": body},
    )["issueCreate"]["issue"]
    return f"created {res['identifier']} {res['url']}"


if __name__ == "__main__":
    e = os.environ
    print(report(e["LINEAR_TEAM"], e["REPORT_KEY"], e["REPORT_TITLE"], e["REPORT_BODY"]))
    sys.exit(0)
