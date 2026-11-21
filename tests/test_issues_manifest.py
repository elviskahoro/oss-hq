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
        "author": "", "author_association": "NONE",
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
    assert "<issue>\nTitle: Bug\n\nbroken\n</issue>" in p["message"]


def test_skip_reason_matches_exact_and_prefix():
    import sys
    sys.path.insert(0, str(pathlib.Path(__file__).parent.parent / "ci"))
    import dispatch_issues as di

    pats = di.DEFAULT_SKIP_LABELS.split(",")
    assert di.skip_reason({"author_association": "OWNER", "labels": ["type::fix", "needs-human"]}, pats) == "needs-human"
    assert di.skip_reason({"author_association": "OWNER", "labels": ["status::blocked-external"]}, pats) == "status::blocked-external"
    assert di.skip_reason({"author_association": "OWNER", "labels": ["status::blocked"]}, pats) == "status::blocked"
    assert di.skip_reason({"author_association": "OWNER", "labels": ["gas-city"]}, pats) == "gas-city"
    assert di.skip_reason({"author_association": "OWNER", "labels": ["status::some-future-state"]}, pats) == "status::some-future-state"
    assert di.skip_reason({"author_association": "OWNER", "labels": ["type::fix"]}, pats) is None
    assert di.skip_reason({"author_association": "OWNER", "labels": []}, pats) is None


def test_list_issues_quotes_label(monkeypatch):
    seen = []
    monkeypatch.setattr(im, "fetch_page", lambda url, token: (seen.append(url), ([], ""))[1])
    im.list_issues("a/b", "t", "good first issue")
    assert "labels=good%20first%20issue" in seen[0]


def test_skip_reason_rejects_untrusted_authors():
    import sys
    sys.path.insert(0, str(pathlib.Path(__file__).parent.parent / "ci"))
    import dispatch_issues as di

    pats = di.DEFAULT_SKIP_LABELS.split(",")
    for assoc in ("NONE", "CONTRIBUTOR", "FIRST_TIME_CONTRIBUTOR"):
        assert di.skip_reason({"author_association": assoc, "labels": []}, pats) == f"author: {assoc}"
    for assoc in ("OWNER", "MEMBER", "COLLABORATOR"):
        assert di.skip_reason({"author_association": assoc, "labels": []}, pats) is None


def test_skip_reason_allows_trusted_bots():
    import sys
    sys.path.insert(0, str(pathlib.Path(__file__).parent.parent / "ci"))
    import dispatch_issues as di

    pats = di.DEFAULT_SKIP_LABELS.split(",")
    bot = {"author": "detail-app[bot]", "author_association": "CONTRIBUTOR", "labels": []}
    assert di.skip_reason(bot, pats) is None
    other = {"author": "someone-else[bot]", "author_association": "CONTRIBUTOR", "labels": []}
    assert di.skip_reason(other, pats) == "author: CONTRIBUTOR"
