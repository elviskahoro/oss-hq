#!/usr/bin/env bash
# Fail if the PR body ($PR_BODY) or any commit message in <base>..<head> carries an AI attribution line.
# Usage: check-no-attribution.sh <base-ref> <head-ref>   (PR_BODY optional, from env)
set -uo pipefail
base="${1:?base ref}"; head="${2:?head ref}"
pat='Generated with.*Claude Code|🤖 Generated with|Co-Authored-By:.*(Claude|anthropic)'
fail=0
if [ -n "${PR_BODY:-}" ] && grep -qiE "$pat" <<<"$PR_BODY"; then
  echo "FAIL: PR body contains an AI attribution line:"; grep -niE "$pat" <<<"$PR_BODY"; fail=1
fi
for c in $(git rev-list "$base..$head"); do
  if git log -1 --format=%B "$c" | grep -qiE "$pat"; then
    echo "FAIL: commit $c contains an AI attribution line:"
    git log -1 --format=%B "$c" | grep -niE "$pat"; fail=1
  fi
done
[ "$fail" = 0 ] && echo "OK: no AI attribution in PR body or commits."
exit "$fail"
