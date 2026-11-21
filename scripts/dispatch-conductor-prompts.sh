#!/usr/bin/env bash
# Dispatch one Conductor workspace per OWNER repo to replace its embedded copies
# of the oss-hq Conductor prompts with pointers (installer --pointers): short
# stubs that fetch prompts/conductor/*.md from oss-hq main, so later oss-hq
# changes reach the repo with no re-install. Run after the installer's
# --pointers mode is on oss-hq main.
# Dry-run by default; pass --run to create workspaces.
# Usage: dispatch-conductor-prompts.sh [--run] [--owner OWNER] [REPO ...]
#   No REPO args: discover owner repos whose .conductor/settings.toml has create_pr.
set -euo pipefail
((BASH_VERSINFO[0] >= 4)) || {
  echo "error: bash 4+ required (mapfile)" >&2
  exit 1
}

run=0
failed=0
owner=elviskahoro
repos=()
while [[ $# -gt 0 ]]; do
  case $1 in
  --run) run=1 ;;
  --owner)
    [[ $# -ge 2 ]] || {
      echo "error: --owner requires a value" >&2
      exit 1
    }
    owner=$2
    shift
    ;;
  *) repos+=("$1") ;;
  esac
  shift
done

if [[ ${#repos[@]} -eq 0 ]]; then
  mapfile -t candidates < <(gh repo list "$owner" --no-archived --source --limit 200 --json name -q '.[].name')
  for r in "${candidates[@]}"; do
    [[ $r == oss-hq ]] && continue
    if gh api "repos/$owner/$r/contents/.conductor/settings.toml" -H "Accept: application/vnd.github.raw" 2>/dev/null | grep -q create_pr; then
      repos+=("$r")
    fi
  done
  [[ ${#repos[@]} -gt 0 ]] || {
    echo "no matching repos found" >&2
    exit 0
  }
fi

tmp=${DISPATCH_MSG_DIR:-tmp/dispatch-msgs}
mkdir -p "$tmp"

for repo in "${repos[@]}"; do
  [[ $repo == */* ]] || repo="$owner/$repo"
  msg="$tmp/prompts_${repo//\//_}.md"
  {
    echo "Replace this repo's embedded Conductor prompt copies with pointers to oss-hq, so prompt changes (e.g. the create-pr issue-claim gate) reach it with no re-install."
    echo
    echo "- git clone --depth 1 https://github.com/$owner/oss-hq /tmp/oss-hq, then from this repo's root: \`uv run --no-project --with \"tomlkit>=0.15.1\" /tmp/oss-hq/scripts/install-conductor-prompts.py --pointers\` (add \`--local\` if this repo keeps prompts in settings.local.toml)."
    echo "- Check \`git diff\` touches only the [prompts] table; keep unrelated settings."
    echo "- Run it again with \`--check --pointers\` to confirm. Keep \`rename_branch\` and any other non-standard keys; if the old [prompts] table was installer-managed, make sure they were not removed. If the repo carries repo-specific edits to a prompt, say so in the PR instead of dropping them."
    echo "- Then open the PR following the create-pr prompt."
  } >"$msg"
  short=${repo#*/}
  short=${short#sdk-python-}
  cmd=(conductor workspace create --repo-url "https://github.com/$repo"
    --name "$short-reinstall_conductor_prompts" --agent claude --message-file "$msg")
  if ((run)); then
    "${cmd[@]}" || {
      echo "error: workspace create failed for $repo" >&2
      failed=1
    }
  else
    echo "dry-run: ${cmd[*]}"
  fi
done
exit $failed
