#!/usr/bin/env bash
# Dispatch one Conductor workspace per OWNER repo to re-install the oss-hq
# Conductor prompts (prompts/conductor/*.md) into its .conductor/settings.toml.
# Prompts are copied, not referenced, so a change to oss-hq reaches a repo only
# when its copy is re-installed. Run after the oss-hq change is merged to main.
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
    echo "Re-install the standard Conductor prompts from oss-hq into this repo; oss-hq's create-pr prompt gained an issue-claim gate and claim release."
    echo
    echo "- git clone --depth 1 https://github.com/$owner/oss-hq /tmp/oss-hq, then from this repo's root: \`uv run --no-project --with \"tomlkit>=0.15.1\" /tmp/oss-hq/scripts/install-conductor-prompts.py\` (add \`--local\` if this repo keeps prompts in settings.local.toml)."
    echo "- Check \`git diff\` touches only the [prompts] table; keep unrelated settings."
    echo "- Run \`install-conductor-prompts.py --check\` to confirm no drift. Keep any repo-specific edits the repo already carries (the repo wins on conflict)."
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
