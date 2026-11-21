Closes #<issue>
<!-- First line. Use Closes/Fixes/Resolves only when this PR FULLY resolves a same-repo issue (one line per issue).
     Partial or cross-repo: write "Refs #N" or "Refs owner/repo#N" instead. No issue at all: delete this line. -->

## Why
<!-- The problem or constraint, not a restatement of the title. -->

## Test plan
<!-- Reasoning, not output. -->

## Roborev
<!-- Required. Roborev runs in the RWX CI/CD pipeline via the RWX CLI (`rwx run .rwx/roborev.yml --wait`), NOT in the sandbox. Do not run `roborev` locally.
     Fix every finding (including low severity) and re-run the pipeline until clean; do not hand findings to the reviewer.
     If the repo has no roborev RWX pipeline: open a GitHub issue to add one (use oss-hq `.rwx/roborev.yml` and skills/roborev-rwx/SKILL.md as the model), link it here, and report "no pipeline (issue #N)".
     Report one of: "clean after N fix rounds (rwx run <url>)", "no pipeline (issue #N)", "unavailable (reason)", or "findings remain (N)". Unavailable and remaining findings are not a clean review: get explicit user acceptance before publishing. Findings the user explicitly accepted: list them. -->

## Checks
<!-- Required. Always watch CI yourself (`gh pr checks <n> --watch --fail-fast`; never ask whether to). "No checks yet" is pending, not done: retry. Fix failures and loop until green. Report "all green" or what is pending/failing and why. -->

<!-- No AI attribution: do not add "Co-Authored-By: Claude", "🤖 Generated with Claude Code", or similar footers to the PR body or commits. Remove any that tools insert. -->
