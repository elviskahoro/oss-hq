#!/usr/bin/env python3
"""List open issues (pull requests excluded) for owner/name repos via the GitHub API.

Used by dispatch_issues.py. Each issue is {repo, number, title, url, labels, body}.
"""
import json
import re
import urllib.parse
import urllib.request

API = "https://api.github.com"


def parse_repos(raw):
    repos = [r for r in re.split(r"[,\s]+", raw) if r]
    bad = [r for r in repos if not re.fullmatch(r"[\w.-]+/[\w.-]+", r)]
    if bad or not repos:
        raise ValueError(f"need owner/name repos, got: {bad or raw!r}")
    return repos


def normalize(repo, item):
    return {
        "repo": repo,
        "number": item["number"],
        "title": item["title"],
        "url": item["html_url"],
        "labels": [lbl["name"] for lbl in item.get("labels", [])],
        "body": item.get("body") or "",
    }


def keep(item):
    return "pull_request" not in item


def fetch_page(url, token):
    req = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r), r.headers.get("Link", "")


def list_issues(repo, token, label=""):
    url = f"{API}/repos/{repo}/issues?state=open&per_page=100" + (f"&labels={urllib.parse.quote(label)}" if label else "")
    out = []
    while url:
        items, link = fetch_page(url, token)
        out += [normalize(repo, i) for i in items if keep(i)]
        m = re.search(r'<([^>]+)>;\s*rel="next"', link)
        url = m.group(1) if m else None
    return out
