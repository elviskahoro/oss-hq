from __future__ import annotations

import importlib.util
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

_SPEC = importlib.util.spec_from_file_location(
    "stale_claim_sweeper",
    Path(__file__).resolve().parents[1] / "ci" / "stale_claim_sweeper.py",
)
assert _SPEC is not None and _SPEC.loader is not None
_MOD = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_MOD)

NOW = datetime(2026, 11, 22, 12, 0, tzinfo=timezone.utc)


def ts(hours_ago: float) -> str:
    return (NOW - timedelta(hours=hours_ago)).isoformat().replace("+00:00", "Z")


def issue(
    claimed: float | None = 100,
    comment: float | None = None,
    commit: float | None = None,
    open_pr: bool = False,
) -> dict[str, Any]:
    labels = []
    if claimed is not None:
        labels.append({"createdAt": ts(claimed), "label": {"name": "status::in_progress"}})
    labels.append({"createdAt": ts(1), "label": {"name": "needs-human"}})  # must not count
    return {
        "number": 1,
        "repository": {"nameWithOwner": "o/r"},
        "timelineItems": {"nodes": labels},
        "comments": {"nodes": [{"createdAt": ts(comment)}] if comment is not None else []},
        "linkedBranches": {
            "nodes": [{"ref": {"target": {"committedDate": ts(commit)}}}] if commit is not None else []
        },
        "closedByPullRequestsReferences": {"nodes": [{"number": 2}] if open_pr else []},
    }


def test_old_claim_is_stale() -> None:
    assert _MOD.is_stale(issue(claimed=49), NOW)


def test_claim_inside_window_is_not_stale() -> None:
    assert not _MOD.is_stale(issue(claimed=47), NOW)


def test_other_label_events_are_not_heartbeats() -> None:
    assert _MOD.heartbeat(issue(claimed=100)) == NOW - timedelta(hours=100)


def test_recent_comment_keeps_claim_alive() -> None:
    assert not _MOD.is_stale(issue(claimed=100, comment=2), NOW)


def test_recent_linked_branch_commit_keeps_claim_alive() -> None:
    assert not _MOD.is_stale(issue(claimed=100, commit=2), NOW)


def test_open_pr_exempts_claim() -> None:
    assert not _MOD.is_stale(issue(claimed=500, open_pr=True), NOW)


def test_undatable_claim_is_left_alone() -> None:
    assert not _MOD.is_stale(issue(claimed=None), NOW)


def _record(monkeypatch: Any, fail_delete_with: int | None = None) -> list[tuple[str, str]]:
    calls: list[tuple[str, str]] = []

    def fake(method: str, url: str, token: str, body: dict[str, Any] | None = None) -> None:
        calls.append((method, url.rsplit("/", 1)[-1]))
        if method == "DELETE" and fail_delete_with is not None:
            raise _MOD.urllib.error.HTTPError(url, fail_delete_with, "x", {}, None)  # type: ignore[arg-type]

    monkeypatch.setattr(_MOD, "request", fake)
    return calls


def test_mark_stale_comments_before_relabeling(monkeypatch: Any) -> None:
    calls = _record(monkeypatch)
    _MOD.mark_stale(issue(), NOW, "t")
    assert [m for m, _ in calls] == ["POST", "POST", "DELETE"]
    assert calls[0][1] == "comments"


def test_mark_stale_tolerates_already_removed_claim_label(monkeypatch: Any) -> None:
    _record(monkeypatch, fail_delete_with=404)
    _MOD.mark_stale(issue(), NOW, "t")


def test_mark_stale_raises_on_other_delete_errors(monkeypatch: Any) -> None:
    _record(monkeypatch, fail_delete_with=500)
    try:
        _MOD.mark_stale(issue(), NOW, "t")
    except _MOD.urllib.error.HTTPError:
        return
    raise AssertionError("expected HTTPError")
