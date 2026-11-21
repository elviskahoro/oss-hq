from __future__ import annotations

import importlib.util
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

_SPEC = importlib.util.spec_from_file_location(
    "claims_report", Path(__file__).resolve().parents[1] / "ci" / "claims_report.py"
)
assert _SPEC is not None and _SPEC.loader is not None
_MOD = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_MOD)

NOW = datetime(2026, 11, 22, 12, 0, tzinfo=timezone.utc)


def issue(labels: list[str], open_pr: bool = False, claimed_hours_ago: float | None = 5) -> dict[str, Any]:
    stamp = (NOW - timedelta(hours=claimed_hours_ago or 0)).isoformat().replace("+00:00", "Z")
    events = [{"createdAt": stamp, "label": {"name": "status::in_progress"}}] if claimed_hours_ago else []
    return {
        "number": 7,
        "title": "t",
        "url": "https://github.com/o/r/issues/7",
        "repository": {"nameWithOwner": "o/r"},
        "labels": {"nodes": [{"name": n} for n in labels]},
        "comments": {"nodes": []},
        "timelineItems": {"nodes": events},
        "closedByPullRequestsReferences": {"nodes": [{"number": 1}] if open_pr else []},
    }


def test_claim_without_pr():
    assert _MOD.claim_without_pr(issue(["status::in_progress"]))


def test_claim_with_pr_is_fine():
    assert not _MOD.claim_without_pr(issue(["status::in_progress"], open_pr=True))


def test_unclaimed_issue_is_not_a_claim():
    assert not _MOD.claim_without_pr(issue(["type::fix"]))


def test_missing_type():
    assert _MOD.missing_type(issue([]))
    assert _MOD.missing_type(issue(["bug", "status::blocked"]))
    assert not _MOD.missing_type(issue(["type::docs"]))


def test_render_lists_both_sections_and_clean_case():
    text = _MOD.render([issue(["status::in_progress"])], [issue([])], NOW)
    assert "Claims without an open PR (1)" in text
    assert "5h since last heartbeat" in text
    assert "missing a `type::*` label (1)" in text
    clean = _MOD.render([], [], NOW)
    assert clean.count("None.") == 2
