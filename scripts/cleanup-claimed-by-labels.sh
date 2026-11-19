#!/usr/bin/env bash
# Remove retired `claimed-by::*` labels from repos that adopted the oss-hq
# issue-claim convention (see AGENT-LABELS.md). Open issues carrying one are
# stripped first (and marked stale-claim if still status::in_progress, so the
# documented takeover applies), then the label is deleted. Idempotent.
# Dry-run by default (prints what it would do); pass --run to apply.
# Usage: cleanup-claimed-by-labels.sh [--run] [--owner OWNER] [REPO ...]
#   Explicit REPO args (owner/name or name) skip discovery.
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
  -*)
    echo "error: unknown flag $1" >&2
    exit 1
    ;;
  *) repos+=("$1") ;;
  esac
  shift
done

if [[ ${#repos[@]} -eq 0 ]]; then
  raw=$(gh search code "oss-hq/blob/main/AGENT-LABELS.md" --owner "$owner" \
    --limit 200 --json repository -q '.[].repository.nameWithOwner') || {
    echo "error: gh search code failed" >&2
    exit 1
  }
  mapfile -t repos < <(printf '%s\n' "$raw" | sed '/^$/d' | sort -u)
  echo "discovered ${#repos[@]} repo(s); code search is approximate, so pass explicit REPO args for any it missed" >&2
  [[ ${#repos[@]} -gt 0 ]] || {
    echo "no adopting repos found" >&2
    exit 0
  }
fi

act() {
  if ((!run)); then
    echo "  would: $*"
  elif ! "$@"; then
    echo "  warning: failed: $*" >&2
    failed=1
  fi
}

for repo in "${repos[@]}"; do
  [[ $repo == */* ]] || repo="$owner/$repo"
  echo "== $repo"

  if ! labels=$(gh label list --repo "$repo" --limit 1000 --json name -q '.[].name'); then
    echo "  skip (gh label list failed)" >&2
    failed=1
    continue
  fi
  labels=$(printf '%s\n' "$labels" | grep '^claimed-by::' || true)

  if [[ -z $labels ]]; then
    echo "  no claimed-by labels"
  else
    while IFS= read -r label; do
      if ! nums=$(gh issue list --repo "$repo" --state open --label "$label" --limit 1000 --json number -q '.[].number'); then
        echo "  skip '$label' (gh issue list failed)" >&2
        failed=1
        continue
      fi
      while IFS= read -r num; do
        [[ -n $num ]] || continue
        echo "  strip '$label' from open issue #$num"
        act gh issue edit "$num" --repo "$repo" --remove-label "$label"
        # The old holder is no longer identifiable; mark the claim reclaimable so
        # the issue isn't stranded with status::in_progress and no holder.
        if ! current=$(gh issue view "$num" --repo "$repo" --json labels -q '.labels[].name'); then
          echo "  warning: could not read labels for #$num" >&2
          failed=1
        elif grep -qx 'status::in_progress' <<<"$current"; then
          echo "  mark #$num stale-claim (status::in_progress with no holder)"
          act gh label create stale-claim --repo "$repo" --color e99695 --description "Claim has no recent heartbeat; reclaimable." --force
          act gh issue edit "$num" --repo "$repo" --add-label stale-claim
          act gh issue comment "$num" --repo "$repo" --body "Marked stale-claim by cleanup-claimed-by-labels.sh: the retired claimed-by label was removed, so the previous holder is unknown. Any agent may take over per AGENT-LABELS.md."
        fi
      done <<<"$nums"
      echo "  delete label '$label'"
      act gh label delete "$label" --repo "$repo" --yes
    done <<<"$labels"
  fi

  if have=$(gh label list --repo "$repo" --limit 1000 --json name -q '.[].name'); then
    grep -qx 'status::in_progress' <<<"$have" || echo "  warning: status::in_progress missing; run the adoption snippet in AGENT-LABELS.md"
  else
    echo "  warning: could not list labels to confirm status::in_progress"
  fi

  if ! gh api "repos/$repo/contents/AGENTS.md" -H "Accept: application/vnd.github.raw" 2>/dev/null |
    grep -q 'oss-hq/blob/main/AGENT-LABELS.md'; then
    echo "  warning: AGENTS.md link to AGENT-LABELS.md not found"
  fi
done

exit "$failed"
