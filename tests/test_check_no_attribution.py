import os
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "check-no-attribution.sh"


def _git(repo, *a):
    subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True)


def _repo(tmp_path, msg):
    _git(tmp_path, "init", "-q", "-b", "main")
    for k, v in (("user.name", "t"), ("user.email", "t@t")):
        _git(tmp_path, "config", k, v)
    _git(tmp_path, "commit", "-q", "--allow-empty", "-m", "base")
    _git(tmp_path, "commit", "-q", "--allow-empty", "-m", msg)


def _run(repo, body=""):
    env = {**os.environ, "PR_BODY": body}
    return subprocess.run(
        [str(SCRIPT), "HEAD~1", "HEAD"], cwd=repo, env=env, capture_output=True, text=True
    ).returncode


def test_clean_passes(tmp_path):
    _repo(tmp_path, "feat: ok")
    assert _run(tmp_path, "fine body") == 0


def test_commit_attribution_fails(tmp_path):
    _repo(tmp_path, "feat: x\n\n🤖 Generated with Claude Code")
    assert _run(tmp_path) == 1


def test_coauthor_fails(tmp_path):
    _repo(tmp_path, "feat: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>")
    assert _run(tmp_path) == 1


def test_body_attribution_fails(tmp_path):
    _repo(tmp_path, "feat: ok")
    assert _run(tmp_path, "hi\n\n🤖 Generated with Claude Code") == 1
