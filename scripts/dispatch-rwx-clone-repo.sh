#!/usr/bin/env bash
# Find OWNER repos whose .rwx/ configs use a task keyed `code` and dispatch a
# Conductor session per repo to rename it to `clone-repo`.
# Dry-run by default (prints the commands); pass --run to execute them.
# Usage: dispatch-rwx-clone-repo.sh [--run] [--owner OWNER] [REPO[=BRANCH] ...]
#   Explicit REPO args (owner/name or name) skip discovery; =BRANCH scans that
#   branch, for repos whose `code` task is only on an unmerged branch.
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
  raw=$(gh search code --owner "$owner" --match path ".rwx" --limit 200 \
    --json repository -q '.[].repository.nameWithOwner')
  # gh search code can't paginate past --limit; count before dedup (one line per matching file).
  (($(printf '%s\n' "$raw" | wc -l) < 200)) || echo "warning: search hit the 200-result limit; some repos may be missed" >&2
  mapfile -t repos < <(printf '%s\n' "$raw" | sed '/^$/d' | sort -u)
  [[ ${#repos[@]} -gt 0 ]] || {
    echo "no matching repos found" >&2
    exit 0
  }
fi

# Kept after exit (repo .gitignore covers tmp/) so dry-run commands can be inspected and re-run.
tmp=${DISPATCH_MSG_DIR:-tmp/dispatch-msgs}
mkdir -p "$tmp"

for entry in "${repos[@]}"; do
  repo=${entry%%=*}
  branch=""
  [[ $entry == *=* ]] && branch=${entry#*=}
  [[ $repo == */* ]] || repo="$owner/$repo"

  if ! meta=$(gh repo view "$repo" --json isArchived,isFork -q '"\(.isArchived) \(.isFork)"'); then
    echo "skip $repo (gh repo view failed)"
    continue
  fi
  if [[ $meta != "false false" ]]; then
    echo "skip $repo (archived or fork)"
    continue
  fi

  ref=${branch:+?ref=$branch}
  # Recursive tree listing so nested .rwx/sub/*.yml files are included.
  if ! files=$(gh api "repos/$repo/git/trees/${branch:-HEAD}?recursive=1" -q '.tree[]|select(.type=="blob")|.path|select(test("^\\.rwx/.*\\.ya?ml$"))' 2>/dev/null); then
    echo "skip $repo (could not list .rwx files)"
    continue
  fi
  hits=()
  fetch_failed=0
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    if ! body=$(gh api "repos/$repo/contents/$f$ref" -H "Accept: application/vnd.github.raw" 2>/dev/null); then
      echo "warning: could not fetch $repo/$f; skipping repo" >&2
      fetch_failed=1
      break
    fi
    if grep -qE '(key:[[:space:]]*[[:punct:]]?code[[:punct:]]?[[:space:]]*(#.*)?$|use:[[:space:]]*(\[[^]]*\bcode[[:space:]]*[],]|code[[:space:]]*(#.*)?$))|(^|[[:space:]])-[[:space:]]code[[:space:]]*(#.*)?$' <<<"$body"; then
      hits+=("$f")
    fi
  done <<<"$files"
  if ((fetch_failed)); then
    echo "skip $repo (file fetch failed; list would be incomplete)"
    failed=1
    continue
  fi
  if [[ ${#hits[@]} -eq 0 ]]; then
    echo "skip $repo (no \`code\` task found${branch:+ on $branch}; may live on an unmerged branch or the pattern missed it)"
    continue
  fi

  msg="$tmp/${repo//\//_}.md"
  {
    echo "Rename the RWX git-clone task key \`code\` to \`clone-repo\`; \`code\` is unclear."
    echo
    echo "Files with a \`code\` task or \`use: code\` reference (default-branch scan${branch:+, branch $branch}):"
    printf -- '- %s\n' "${hits[@]}"
    echo
    echo "- Rename \`- key: code\` to \`- key: clone-repo\`, update every \`use: [code, ...]\`/\`use: code\`, and comments such as \"no use: code\"."
    echo "- Grep ci/ and docs for other references."
    echo "- Verify: \`grep -rn \"\\bcode\\b\" .rwx\` shows no leftover task refs; \`rwx lint\` each edited file; \`rwx run\` the changed configs green."
    echo "- If these files aren't on the default branch, work on the branch that has them."
    echo "- Then open the PR following the repo's create-pr prompt (flox-conductor-sandbox prompts/conductor/create-pr.md)."
  } >"$msg"

  # Short repo label for the workspace name: sdk-python-attio -> attio, cmu-database-group-lectures -> cmu.
  short=${repo#*/}
  short=${short#sdk-python-}
  [[ $short == cmu-database-group-lectures ]] && short=cmu

  cmd=(conductor workspace create --repo-url "https://github.com/$repo" ${branch:+--branch "$branch"}
    --name "$short-rename_rwx_code_task" --agent claude --message-file "$msg")
  if ((run)); then
    # A failed create (e.g. duplicate workspace name after a partial run) must not abort the rest.
    "${cmd[@]}" || {
      echo "error: workspace create failed for $repo" >&2
      failed=1
    }
  else
    echo "dry-run: ${cmd[*]}"
  fi
done
exit $failed
