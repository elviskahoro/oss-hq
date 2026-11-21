#!/usr/bin/env python3
"""Open one Conductor workspace per open issue, with the create-pr prompt attached.

Env: GITHUB_TOKEN, CONDUCTOR_API_KEY (never printed), ISSUE_REPOS, ISSUE_LABEL
(optional), ISSUE_LIMIT (0 = all), SKIP_LABELS (comma list, trailing * = prefix; default DEFAULT_SKIP_LABELS), DISPATCH_RUN ("1" to create; default dry-run),
PR_TEMPLATE (path to prompts/conductor/create-pr.md).
Uses the same endpoint as the `conductor` CLI: POST /v0/workspaces.
"""
import json
import os
import sys
import urllib.request

from issues_manifest import list_issues, parse_repos

# Labels meaning "don't pick up" (AGENT-LABELS.md). A trailing * is a prefix match.
DEFAULT_SKIP_LABELS = (
    "status::in_progress,status::blocked,status::blocked-external,status::deferred,needs-human,gas-city"
)


def skip_reason(issue, patterns):
    """Return the first label matching a skip pattern, or None."""
    for label in issue["labels"]:
        for pat in patterns:
            if label == pat or (pat.endswith("*") and label.startswith(pat[:-1])):
                return label
    return None


API = os.environ.get("CONDUCTOR_API_URL", "https://api.conductor.build")


def build_message(issue, template):
    return (
        f"Work on {issue['repo']}#{issue['number']}: {issue['title']}\n{issue['url']}\n\n"
        f"Issue body:\n\n{issue['body']}\n\n"
        "Read the issue and the repo's own instructions first. Fix it, verify, then open a PR "
        f"that closes #{issue['number']} following the PR template below.\n\n---\n\n{template}"
    )


def build_payload(issue, template):
    return {
        "repositoryUrl": f"https://github.com/{issue['repo']}",
        "name": f"{issue['repo'].split('/')[1]}-issue-{issue['number']}",
        "agent": "claude",
        "message": build_message(issue, template),
    }


def create_workspace(payload, key):
    req = urllib.request.Request(
        f"{API}/v0/workspaces",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json", "Accept": "application/json",
                 "User-Agent": "oss-hq-dispatch/1.0"},  # default Python-urllib UA is blocked (Cloudflare 1010)
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def main():
    template = open(os.environ["PR_TEMPLATE"]).read()
    gh, run = os.environ["GITHUB_TOKEN"], os.environ.get("DISPATCH_RUN") == "1"
    limit = int(os.environ.get("ISSUE_LIMIT") or 0)
    skip = [p.strip() for p in (os.environ.get("SKIP_LABELS") or DEFAULT_SKIP_LABELS).split(",") if p.strip()]
    issues = []
    for repo in parse_repos(os.environ["ISSUE_REPOS"]):
        issues += list_issues(repo, gh, os.environ.get("ISSUE_LABEL", ""))
    kept = []
    for issue in issues:
        why = skip_reason(issue, skip)
        if why:
            print(f"skip {issue['repo']}#{issue['number']} (label: {why})")
        else:
            kept.append(issue)
    issues = kept[:limit] if limit else kept
    failed = 0
    for issue in issues:
        payload = build_payload(issue, template)
        tag = f"{issue['repo']}#{issue['number']}"
        if not run:
            print(f"dry-run: would create {payload['name']} for {tag}")
            continue
        try:
            out = create_workspace(payload, os.environ["CONDUCTOR_API_KEY"])
            print(f"created {tag}: {out.get('deepLink') or out.get('workspaceId')}")
        except Exception as e:  # keep going; report at the end
            failed += 1
            detail = e.read().decode()[:300] if hasattr(e, "read") else ""
            print(f"error: {tag}: {e} {detail}", file=sys.stderr)
    print(f"{len(issues)} issues, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
