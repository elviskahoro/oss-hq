import importlib.util
import pathlib

import pytest

spec = importlib.util.spec_from_file_location(
    "issues_manifest", pathlib.Path(__file__).parent.parent / "ci" / "issues_manifest.py"
)
im = importlib.util.module_from_spec(spec)
spec.loader.exec_module(im)


def test_parse_repos_splits_commas_and_spaces():
    assert im.parse_repos("a/b, c/d e/f") == ["a/b", "c/d", "e/f"]


@pytest.mark.parametrize("raw", ["", "nope", "a/b;rm"])
def test_parse_repos_rejects_bad_input(raw):
    with pytest.raises(ValueError):
        im.parse_repos(raw)


def test_keep_drops_pull_requests():
    assert im.keep({"number": 1})
    assert not im.keep({"number": 2, "pull_request": {}})


def test_normalize_handles_null_body():
    item = {"number": 3, "title": "t", "html_url": "u", "labels": [{"name": "bug"}], "body": None}
    assert im.normalize("a/b", item) == {
        "repo": "a/b", "number": 3, "title": "t", "url": "u", "labels": ["bug"], "body": "",
    }


def test_dispatch_payload_attaches_template():
    import sys
    sys.path.insert(0, str(pathlib.Path(__file__).parent.parent / "ci"))
    import dispatch_issues as di

    issue = {"repo": "o/r", "number": 5, "title": "Bug", "url": "u", "labels": [], "body": "broken"}
    p = di.build_payload(issue, "TEMPLATE-TEXT")
    assert p["repositoryUrl"] == "https://github.com/o/r"
    assert p["name"] == "r-issue-5" and p["agent"] == "claude"
    assert "closes #5" in p["message"] and p["message"].endswith("TEMPLATE-TEXT")


def test_skip_reason_matches_exact_and_prefix():
    import sys
    sys.path.insert(0, str(pathlib.Path(__file__).parent.parent / "ci"))
    import dispatch_issues as di

    pats = di.DEFAULT_SKIP_LABELS.split(",")
    assert di.skip_reason({"labels": ["type::fix", "needs-human"]}, pats) == "needs-human"
    assert di.skip_reason({"labels": ["status::blocked-external"]}, pats) == "status::blocked-external"
    assert di.skip_reason({"labels": ["status::blocked"]}, pats) == "status::blocked"
    assert di.skip_reason({"labels": ["gas-city"]}, pats) == "gas-city"
    assert di.skip_reason({"labels": ["type::fix", "agent-ready"]}, pats) is None
    assert di.skip_reason({"labels": []}, pats) is None
