#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  create_issues.sh [--dry-run] [--ensure-labels] [--assignee USER] ISSUES_JSON [OWNER/REPO]

Examples:
  ./create_issues.sh issues.json
  ./create_issues.sh --dry-run issues.json
  ./create_issues.sh --ensure-labels issues.json
  ./create_issues.sh --assignee myuser issues.json
  ./create_issues.sh --dry-run --ensure-labels --assignee myuser issues.json
  ./create_issues.sh issues.json ricardo/gts

Notes:
- Requires: gh, jq
- If OWNER/REPO is omitted, the current git remote repo is used.
- --dry-run validates the JSON, checks for duplicate titles when possible, and
  prints the gh commands that would be executed without creating issues.
- --ensure-labels creates any missing labels before issue creation.
- --assignee USER assigns every created issue to USER in addition to any
  assignees already present in the JSON.
USAGE
}

DRY_RUN=0
ENSURE_LABELS=0
GLOBAL_ASSIGNEE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --ensure-labels)
      ENSURE_LABELS=1
      shift
      ;;
    --assignee)
      if [[ $# -lt 2 ]]; then
        echo "Error: --assignee requires a username." >&2
        usage
        exit 1
      fi
      GLOBAL_ASSIGNEE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

ISSUES_JSON="$1"
REPO="${2:-}"

if [[ ! -f "$ISSUES_JSON" ]]; then
  echo "Error: file not found: $ISSUES_JSON" >&2
  exit 1
fi

command -v gh >/dev/null 2>&1 || { echo "Error: gh is not installed." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq is not installed." >&2; exit 1; }

if [[ -n "$REPO" ]]; then
  GH_REPO_ARGS=(--repo "$REPO")
else
  GH_REPO_ARGS=()
fi

# Basic validation
jq -e '
  type == "array" and
  all(.[ ];
    type == "object" and
    has("title") and has("body") and
    (.title|type=="string") and
    (.body|type=="string") and
    ((.labels // [])|type=="array") and
    ((.assignees // [])|type=="array") and
    ((.milestone // "")|type=="string")
  )
' "$ISSUES_JSON" >/dev/null || {
  echo "Error: JSON must be an array of objects with string fields 'title' and 'body'. Optional fields: labels[], assignees[], milestone." >&2
  exit 1
}

quote() {
  printf '%q' "$1"
}

get_repo_name() {
  gh repo view "${GH_REPO_ARGS[@]}" --json nameWithOwner -q .nameWithOwner 2>/dev/null || true
}

repo_name="$(get_repo_name)"
if [[ -z "$repo_name" ]]; then
  echo "Warning: could not resolve repository context with 'gh repo view'." >&2
  echo "Duplicate-title checks will be skipped. You can pass OWNER/REPO explicitly." >&2
else
  echo "Using repository: $repo_name"
fi

count="$(jq 'length' "$ISSUES_JSON")"
echo "Found $count issue(s) in $ISSUES_JSON"
(( DRY_RUN )) && echo "Mode: dry run (no issues will be created)"
(( ENSURE_LABELS )) && echo "Mode: ensure labels (missing labels will be created)"
[[ -n "$GLOBAL_ASSIGNEE" ]] && echo "Mode: global assignee = $GLOBAL_ASSIGNEE"

existing_titles_json='[]'
if [[ -n "$repo_name" ]]; then
  if titles_raw="$(gh issue list "${GH_REPO_ARGS[@]}" --state all --limit 1000 --json title 2>/dev/null)"; then
    if echo "$titles_raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
      existing_titles_json="$titles_raw"
    else
      echo "Warning: could not parse issue list as JSON. Duplicate-title checks will be skipped." >&2
      existing_titles_json='[]'
      repo_name=""
    fi
  else
    echo "Warning: could not retrieve existing issues. Duplicate-title checks will be skipped." >&2
    repo_name=""
  fi
fi

existing_labels_json='[]'
if (( ENSURE_LABELS )) && [[ -n "$repo_name" ]]; then
  if labels_raw="$(gh label list "${GH_REPO_ARGS[@]}" --limit 1000 --json name 2>/dev/null)"; then
    if echo "$labels_raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
      existing_labels_json="$labels_raw"
    else
      echo "Warning: could not parse label list as JSON. Missing labels may still fail." >&2
      existing_labels_json='[]'
    fi
  else
    echo "Warning: could not retrieve labels. Missing labels may still fail." >&2
  fi
fi

ensure_label() {
  local label="$1"
  local present="0"

  present="$(echo "$existing_labels_json" | jq --arg l "$label" '[.[] | select(.name == $l)] | length')"
  if [[ "$present" -gt 0 ]]; then
    return 0
  fi

  if (( DRY_RUN )); then
    printf '  Would run: %s\n' "$(quote gh) $(quote label) $(quote create) ${GH_REPO_ARGS[*]:+$(printf '%q ' "${GH_REPO_ARGS[@]}")}$(quote "$label")"
  else
    gh label create "$label" "${GH_REPO_ARGS[@]}" >/dev/null
    echo "  Created missing label: $label"
  fi

  existing_labels_json="$(echo "$existing_labels_json" | jq --arg l "$label" '. + [{"name": $l}]')"
}

for i in $(seq 0 $((count - 1))); do
  title="$(jq -r ".[$i].title" "$ISSUES_JSON")"
  body="$(jq -r ".[$i].body" "$ISSUES_JSON")"
  milestone="$(jq -r ".[$i].milestone // \"\"" "$ISSUES_JSON")"

  mapfile -t labels < <(jq -r ".[$i].labels // [] | .[]" "$ISSUES_JSON")
  mapfile -t assignees < <(jq -r ".[$i].assignees // [] | .[]" "$ISSUES_JSON")

  if [[ -n "$GLOBAL_ASSIGNEE" ]]; then
    assignees+=("$GLOBAL_ASSIGNEE")
  fi

  if (( ${#assignees[@]} > 0 )); then
    mapfile -t assignees < <(printf '%s\n' "${assignees[@]}" | awk 'NF && !seen[$0]++')
  fi

  echo
  echo "Processing issue $((i + 1))/$count: $title"

  if [[ -n "$repo_name" ]]; then
    existing_count="$(echo "$existing_titles_json" | jq --arg t "$title" '[.[] | select(.title == $t)] | length')"
    if [[ "$existing_count" -gt 0 ]]; then
      echo "  Skipped: issue with same title already exists"
      continue
    fi
  fi

  if (( ENSURE_LABELS )); then
    for label in "${labels[@]}"; do
      [[ -n "$label" ]] && ensure_label "$label"
    done
  fi

  args=(issue create "${GH_REPO_ARGS[@]}" --title "$title" --body "$body")

  for label in "${labels[@]}"; do
    [[ -n "$label" ]] && args+=(--label "$label")
  done

  for assignee in "${assignees[@]}"; do
    [[ -n "$assignee" ]] && args+=(--assignee "$assignee")
  done

  if [[ -n "$milestone" ]]; then
    args+=(--milestone "$milestone")
  fi

  if (( DRY_RUN )); then
    printf '  Would run:'
    for arg in gh "${args[@]}"; do
      printf ' %s' "$(quote "$arg")"
    done
    printf '\n'
  else
    gh "${args[@]}"
    sleep 1
  fi
done

echo
if (( DRY_RUN )); then
  echo "Dry run complete."
else
  echo "Done."
fi
