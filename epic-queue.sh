#!/usr/bin/env bash
set -euo pipefail

#
# epic-queue.sh
#
# Purpose:
#   Drive an "epic checklist" issue-by-issue (assign → wait → merge) to keep PRs small.
#
# This script is generic and can be used in any repo, with any epic(s), and with any assignee.
# It defaults to GitHub Copilot coding agent conventions, but those can be overridden with flags:
#   - PR author filter: app/copilot-swe-agent
#   - Branch prefix filter: copilot/
#
# What it does:
#   1) (Optional) auto-merge open agent PRs that reference issues in the epics
#   2) If the assignee is already assigned to an epic issue, do nothing
#   3) Otherwise assign the next unchecked issue from the epic checklist to the assignee
#

REPO="${QUEUE_REPO:-}"
EPICS="${QUEUE_EPICS:-}"
ASSIGNEE="${QUEUE_ASSIGNEE:-Copilot}"
DRY_RUN="false"
AUTO_MERGE="false"
MERGE_METHOD="squash" # squash|merge|rebase
WATCH="false"
INTERVAL_SECONDS="60"
AUTO_READY="false"
AUTO_APPROVE="false"
MIN_IDLE_SECONDS="120"
SLEEP_HINT_SECONDS=""
SYNC_EPICS="false"

# ── UI / progress-bar state ──────────────────────────────────────────────────
TOTAL_ISSUES=0
DONE_ISSUES=0
CURRENT_ISSUE_NUM=""
CURRENT_ISSUE_TITLE=""
_PROGRESS_ACTIVE=false
_UI_ENABLED=false
[[ -t 1 ]] && _UI_ENABLED=true

draw_progress() {
  [[ "$_UI_ENABLED" == false ]] && return 0
  local width=28 filled=0 pct=0
  [[ "$TOTAL_ISSUES" -gt 0 ]] && filled=$(( DONE_ISSUES * width / TOTAL_ISSUES ))
  [[ "$TOTAL_ISSUES" -gt 0 ]] && pct=$(( DONE_ISSUES * 100 / TOTAL_ISSUES ))
  local bar="" i
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=filled; i<width; i++)); do bar+="░"; done
  local label="[${bar}] ${DONE_ISSUES}/${TOTAL_ISSUES} (${pct}%)"
  if [[ -n "$CURRENT_ISSUE_NUM" ]]; then
    local suffix=" — #${CURRENT_ISSUE_NUM}"
    [[ -n "$CURRENT_ISSUE_TITLE" ]] && suffix+=" ${CURRENT_ISSUE_TITLE}"
    local cols; cols="$(tput cols 2>/dev/null || echo 80)"
    local max_len=$(( cols - ${#label} - 1 ))
    if [[ "${#suffix}" -gt "$max_len" && "$max_len" -gt 4 ]]; then
      suffix="${suffix:0:$(( max_len - 1 ))}…"
    fi
    label+="$suffix"
  fi
  printf "\033[2K\033[1m%s\033[0m\n" "$label"
  _PROGRESS_ACTIVE=true
}

_clear_progress() {
  [[ "$_UI_ENABLED" == false || "$_PROGRESS_ACTIVE" == false ]] && return 0
  printf "\033[1A\033[2K"
  _PROGRESS_ACTIVE=false
}

log() {
  _clear_progress
  echo "[info] $*"
  draw_progress
}

warn() {
  _clear_progress
  echo "[warn] $*"
  draw_progress
}

# ── Defaults for Copilot coding agent PR detection. Override for other agents/tools.
PR_AUTHOR="${QUEUE_PR_AUTHOR:-app/copilot-swe-agent}"
PR_BRANCH_PREFIX="${QUEUE_PR_BRANCH_PREFIX:-copilot/}"

usage() {
  cat <<'EOF'
Usage:
  epic-queue.sh [options]

Required:
  --epics N1,N2,...           Epic issue numbers in priority order

Essential Options:
  --repo OWNER/REPO           GitHub repo (default: auto-detect from gh context)
  --assignee LOGIN|BOT_<id>   Issue assignee (default: Copilot)
  --dry-run                   Print actions without modifying anything
  --auto-merge                Merge open agent PRs (implies --auto-ready and --auto-approve)

Common Options:
  --merge-method METHOD       squash|merge|rebase (default: squash)
  --min-idle-seconds N        Only merge PRs idle for N seconds (default: 120)
  --watch                     Keep running in a poll loop
  --interval-seconds N        Poll interval when using --watch (default: 60)
  --sync-epics                Auto-check [x] epic items when issues are closed, and close the epic when all are done

Advanced Options:
  --pr-author LOGIN           Filter PRs by author (default: app/copilot-swe-agent)
  --pr-branch-prefix PREFIX   Filter PRs by branch prefix (default: copilot/)

Examples:
  # Basic usage
  epic-queue.sh --epics 123 --repo owner/repo --dry-run
  epic-queue.sh --epics 123 --repo owner/repo

  # Auto-merge PRs then assign next issue
  epic-queue.sh --epics 123,124 --repo owner/repo --auto-merge

  # Continuous mode (poll loop)
  epic-queue.sh --epics 123 --repo owner/repo --auto-merge --watch

Environment Variables (optional defaults):
  QUEUE_REPO, QUEUE_EPICS, QUEUE_ASSIGNEE, QUEUE_PR_AUTHOR, QUEUE_PR_BRANCH_PREFIX
EOF
}

die() {
  _clear_progress
  echo "[error] $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

default_repo() {
  # Use gh's repo context (works when invoked from within a checked-out repo).
  gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true
}

gh_json() {
  # shellcheck disable=SC2145
  gh "$@" --json number >/dev/null 2>&1 || true
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        REPO="${2:-}"; shift 2 ;;
      --epics)
        EPICS="${2:-}"; shift 2 ;;
      --assignee)
        ASSIGNEE="${2:-}"; shift 2 ;;
      --dry-run)
        DRY_RUN="true"; shift ;;
      --auto-merge)
        AUTO_MERGE="true"; shift ;;
      --merge-method)
        MERGE_METHOD="${2:-}"; shift 2 ;;
      --watch)
        WATCH="true"; shift ;;
      --interval-seconds)
        INTERVAL_SECONDS="${2:-}"; shift 2 ;;
      --auto-ready)
        AUTO_READY="true"; shift ;;
      --auto-approve)
        AUTO_APPROVE="true"; shift ;;
      --pr-author)
        PR_AUTHOR="${2:-}"; shift 2 ;;
      --pr-branch-prefix)
        PR_BRANCH_PREFIX="${2:-}"; shift 2 ;;
      --min-idle-seconds)
        MIN_IDLE_SECONDS="${2:-}"; shift 2 ;;
      --sync-epics)
        SYNC_EPICS="true"; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "Unknown argument: $1" ;;
    esac
  done
}

split_csv() {
  local csv="$1"
  local IFS=,
  # shellcheck disable=SC2206
  local parts=($csv)
  printf "%s\n" "${parts[@]}"
}

epic_unchecked_issue_numbers() {
  local epic="$1"
  local body
  body="$(gh issue view -R "$REPO" "$epic" --json body -q .body)"

  # Extract unchecked checklist items with flexible format support:
  #   - [ ] #212 — Title
  #   - [ ] Title (#212)
  #   - [ ] Title #212
  # Capture the issue number wherever it appears after '#' in the line.
  # BSD awk on macOS doesn't support `match(..., ..., array)`; use sed instead.
  echo "$body" | sed -nE 's/^- \[ \] .*#([0-9]+).*/\1/p'
}

epic_all_issue_numbers() {
  local epic="$1"
  local body
  body="$(gh issue view -R "$REPO" "$epic" --json body -q .body)"

  # Match both checked and unchecked checklist items with flexible format support:
  #   - [ ] #212 — Title
  #   - [x] #212 — Title
  #   - [ ] Title (#212)
  #   - [x] Title (#212)
  # Capture the issue number wherever it appears after '#' in the line.
  echo "$body" | sed -nE 's/^- \[[ xX]\] .*#([0-9]+).*/\1/p'
}

issue_state_json() {
  local issue="$1"
  gh issue view -R "$REPO" "$issue" --json number,title,state,assignees,url -q .
}

is_issue_assigned_to() {
  local issue="$1"
  local login="$2"
  gh issue view -R "$REPO" "$issue" --json assignees -q ".assignees[].login" 2>/dev/null | grep -Fxq "$login"
}

find_inflight_issue() {
  local epic
  while read -r epic; do
    local issue
    while read -r issue; do
      [[ -z "$issue" ]] && continue
      local state
      state="$(gh issue view -R "$REPO" "$issue" --json state -q .state 2>/dev/null || true)"
      if [[ "$state" != "OPEN" ]]; then
        continue
      fi
      if is_issue_assigned_to "$issue" "$ASSIGNEE"; then
        echo "$issue"
        return 0
      fi
    done < <(epic_all_issue_numbers "$epic")
  done < <(split_csv "$EPICS")

  return 1
}

collect_all_epic_issue_numbers() {
  local epic
  while read -r epic; do
    epic_all_issue_numbers "$epic"
  done < <(split_csv "$EPICS")
}

init_progress_counts() {
  local epic total=0 done=0
  while read -r epic; do
    [[ -z "$epic" ]] && continue
    local body
    body="$(gh issue view -R "$REPO" "$epic" --json body -q .body 2>/dev/null || true)"
    local t d
    t=$(printf '%s\n' "$body" | sed -nE 's/^- \[[ xX]\] .*#([0-9]+).*/\1/p' | grep -c . || true)
    d=$(printf '%s\n' "$body" | sed -nE 's/^- \[[xX]\] .*#([0-9]+).*/\1/p' | grep -c . || true)
    total=$(( total + t ))
    done=$(( done + d ))
  done < <(split_csv "$EPICS")
  TOTAL_ISSUES="$total"
  DONE_ISSUES="$done"
}

list_open_prs_json() {
  gh pr list -R "$REPO" --state open --limit 200 --json number,title,body,author,headRefName,headRefOid,isDraft,mergeable,updatedAt
}

pr_idle_seconds() {
  local updated_at="$1"
  # Prefer python3; fall back to BSD date (macOS).
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$updated_at" <<'PY'
import datetime, sys
s = sys.argv[1]
try:
  dt = datetime.datetime.fromisoformat(s.replace("Z","+00:00"))
except Exception:
  dt = datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
now = datetime.datetime.now(datetime.timezone.utc)
print(int((now - dt).total_seconds()))
PY
    return 0
  fi

  # Example: 2026-02-25T03:49:46Z
  local now_s then_s
  now_s="$(date -u '+%s')"
  then_s="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$updated_at" '+%s' 2>/dev/null || true)"
  [[ -n "$then_s" ]] || die "Unable to parse updatedAt timestamp without python3: $updated_at"
  echo $((now_s - then_s))
}

has_copilot_finished() {
  local pr="$1"

  # Check if there's a copilot_work_started event
  local events
  events="$(gh api "repos/$REPO/issues/$pr/events" --paginate 2>/dev/null | jq -r '.[] | select(.event | startswith("copilot_work")) | .event' || true)"

  if [[ -z "$events" ]]; then
    # No Copilot session events - PR is not from Copilot agent
    return 0
  fi

  # Check if copilot_work_finished exists
  if echo "$events" | grep -Fxq "copilot_work_finished"; then
    return 0  # Copilot has finished
  else
    return 1  # Copilot started but hasn't finished
  fi
}

merge_pr_via_api() {
  local pr="$1"
  local head_ref="$2"
  local head_sha="$3"

  local method
  case "$MERGE_METHOD" in
    squash) method="squash" ;;
    merge) method="merge" ;;
    rebase) method="rebase" ;;
    *) die "Invalid --merge-method: $MERGE_METHOD (expected squash|merge|rebase)" ;;
  esac

  local merge_cmd=(
    gh api -X PUT "repos/$REPO/pulls/$pr/merge"
    -f "merge_method=$method"
    -f "sha=$head_sha"
  )

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] ${merge_cmd[*]}"
    log "[dry-run] gh api -X DELETE repos/$REPO/git/refs/heads/$head_ref"
    return 0
  fi

  # Merge the PR (non-interactive).
  # If branch protections block merge, this endpoint returns an error.
  if ! "${merge_cmd[@]}" >/dev/null; then
    warn "Merge API call failed for PR #$pr."
    return 1
  fi

  # Best-effort delete of the head branch.
  gh api -X DELETE "repos/$REPO/git/refs/heads/$head_ref" >/dev/null 2>&1 || true
  return 0
}

automerge_agent_prs() {
  local issues_regex="$1"
  local prs_json
  prs_json="$(list_open_prs_json)"
  SLEEP_HINT_SECONDS=""

  # Consider only PRs that reference any epic issue number.
  # Optionally filter by PR author and head branch prefix to target a specific agent/tool.
  local pr_lines
  pr_lines="$(
    echo "$prs_json" | jq -r --arg re "$issues_regex" --arg author "$PR_AUTHOR" --arg prefix "$PR_BRANCH_PREFIX" '
      .[]
      | select(($author=="" or .author.login == $author))
      | select(($prefix=="" or (.headRefName | startswith($prefix))))
      | select((.title + "\n" + (.body // "")) | test($re))
      | [.number, (.isDraft|tostring), (.mergeable // "UNKNOWN"), .updatedAt, .headRefName, .headRefOid]
      | @tsv
    '
  )"

  if [[ -z "$pr_lines" ]]; then
    log "No eligible PRs to merge."
    return 0
  fi

  local waiting_msgs=()
  local to_merge=()
  local min_remaining=""

  local line
  while IFS=$'\t' read -r pr is_draft mergeable updated_at head_ref head_sha; do
    [[ -z "${pr:-}" ]] && continue

    local idle remaining
    idle="$(pr_idle_seconds "$updated_at")"
    remaining=$((MIN_IDLE_SECONDS - idle))

    if [[ "$is_draft" == "true" ]]; then
      if [[ "$AUTO_READY" == "true" && "$idle" -ge "$MIN_IDLE_SECONDS" ]]; then
        # Check if Copilot has finished working before marking ready
        if ! has_copilot_finished "$pr"; then
          waiting_msgs+=("PR #$pr is draft; waiting for Copilot to finish session")
          continue
        fi

        local ready_cmd=(gh pr ready -R "$REPO" "$pr")
        if [[ "$DRY_RUN" == "true" ]]; then
          log "[dry-run] ${ready_cmd[*]}"
        else
          log "Marking PR #$pr ready for review ..."
          _clear_progress
          "${ready_cmd[@]}" || {
            draw_progress
            warn "Failed to mark PR #$pr ready."
            continue
          }
          draw_progress
        fi

        # We've already waited the full idle window before flipping draft→ready.
        # Don't enforce the idle wait a *second time* for the merge step.
        to_merge+=("$pr"$'\t'"$head_ref"$'\t'"$head_sha")
      else
        if [[ "$remaining" -lt 0 ]]; then remaining=0; fi
        waiting_msgs+=("PR #$pr is draft; idle ${idle}s (need ${MIN_IDLE_SECONDS}s) — wait ${remaining}s")
        if [[ "$remaining" -gt 0 ]]; then
          if [[ -z "$min_remaining" || "$remaining" -lt "$min_remaining" ]]; then
            min_remaining="$remaining"
          fi
        fi
      fi
      continue
    fi

    if [[ "$mergeable" == "CONFLICTING" ]]; then
      waiting_msgs+=("PR #$pr is conflicting — manual resolution required")
      continue
    fi

    if [[ "$idle" -lt "$MIN_IDLE_SECONDS" ]]; then
      if [[ "$remaining" -lt 0 ]]; then remaining=0; fi
      waiting_msgs+=("PR #$pr idle ${idle}s (need ${MIN_IDLE_SECONDS}s) — wait ${remaining}s")
      if [[ "$remaining" -gt 0 ]]; then
        if [[ -z "$min_remaining" || "$remaining" -lt "$min_remaining" ]]; then
          min_remaining="$remaining"
        fi
      fi
      continue
    fi

    # Check if Copilot has finished working (if this is a Copilot PR)
    if ! has_copilot_finished "$pr"; then
      waiting_msgs+=("PR #$pr waiting for Copilot to finish session")
      continue
    fi

    to_merge+=("$pr"$'\t'"$head_ref"$'\t'"$head_sha")
  done <<<"$pr_lines"

  if [[ "${#waiting_msgs[@]}" -gt 0 ]]; then
    for msg in "${waiting_msgs[@]}"; do
      log "$msg"
    done
  fi

  # Hint to the watch loop: wake up when the next PR crosses the idle threshold,
  # but don't go too aggressive (avoid hammering the API).
  if [[ -n "$min_remaining" ]]; then
    if [[ "$min_remaining" -lt 30 ]]; then
      SLEEP_HINT_SECONDS="30"
    else
      SLEEP_HINT_SECONDS="$min_remaining"
    fi
  fi

  if [[ "${#to_merge[@]}" -eq 0 ]]; then
    return 0
  fi

  log "Eligible PRs to merge:"
  printf "%s\n" "${to_merge[@]}" | cut -f1 | while read -r _n; do log " - #$_n"; done

  local item
  for item in "${to_merge[@]}"; do
    local pr head_ref head_sha
    pr="$(echo "$item" | cut -f1)"
    head_ref="$(echo "$item" | cut -f2)"
    head_sha="$(echo "$item" | cut -f3)"

    if [[ "$AUTO_APPROVE" == "true" ]]; then
      local approve_cmd=(gh pr review -R "$REPO" "$pr" --approve)
      if [[ "$DRY_RUN" == "true" ]]; then
        log "[dry-run] ${approve_cmd[*]}"
      else
        log "Approving PR #$pr ..."
        _clear_progress
        local _approve_ok=true
        "${approve_cmd[@]}" || _approve_ok=false
        draw_progress
        [[ "$_approve_ok" == false ]] && warn "Failed to approve PR #$pr (may already be approved or not permitted)."
      fi
    fi

    log "Merging PR #$pr ..."
    if merge_pr_via_api "$pr" "$head_ref" "$head_sha"; then
      DONE_ISSUES=$(( DONE_ISSUES + 1 ))
    else
      warn "Failed to merge PR #$pr. Leaving it open."
    fi
  done
}

resolve_assignee_id() {
  # Allow passing a node id directly (e.g. BOT_...).
  if [[ "$ASSIGNEE" == BOT_* ]]; then
    echo "$ASSIGNEE"
    return 0
  fi

  # Regular GitHub users (and most bot accounts).
  local id
  id="$(
    gh api graphql -f login="$ASSIGNEE" -f query='query($login:String!){ user(login:$login){ id } }' 2>/dev/null \
      | jq -r '.data.user.id // empty' 2>/dev/null
  )"
  if [[ -n "${id:-}" ]]; then
    echo "$id"
    return 0
  fi

  # Fallback: discover node id by scanning recent issues and PRs via REST API.
  # This is necessary for some special bot accounts (e.g. Copilot) which can't be resolved via user(login: ...).

  # Try finding in issue assignees first
  id="$(
    gh api "repos/$REPO/issues?state=all&per_page=100" 2>/dev/null \
      | jq -r --arg a "$ASSIGNEE" '.[] | .assignees[]? | select(.login==$a) | .node_id' 2>/dev/null \
      | head -n 1
  )"
  if [[ -n "${id:-}" ]]; then
    echo "$id"
    return 0
  fi

  # Fallback to PR authors (useful if Copilot hasn't been assigned to issues yet)
  id="$(
    gh api "repos/$REPO/pulls?state=all&per_page=100" 2>/dev/null \
      | jq -r --arg a "$ASSIGNEE" '.[] | .user | select(.login==$a) | .node_id' 2>/dev/null \
      | head -n 1
  )"

  [[ -n "${id:-}" ]] || die "Unable to resolve assignee '$ASSIGNEE'. If it's a bot, try using --assignee BOT_<node_id> directly."
  echo "$id"
}

assign_issue_to_assignee() {
  local issue="$1"
  local issue_id assignee_id
  issue_id="$(gh issue view -R "$REPO" "$issue" --json id -q .id)"
  assignee_id="$(resolve_assignee_id)"

  local cmd=(
    gh api graphql --silent
    -f query='mutation($issue:ID!,$assignees:[ID!]!){ addAssigneesToAssignable(input:{assignableId:$issue,assigneeIds:$assignees}){ clientMutationId } }'
    -F issue="$issue_id"
    -F "assignees[]=$assignee_id"
  )
  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] ${cmd[*]}"
  else
    log "Assigning #$issue to $ASSIGNEE ..."
    "${cmd[@]}"
  fi
}

sync_epic_checklist() {
  local epic="$1"
  local body
  body="$(gh issue view -R "$REPO" "$epic" --json body -q .body)"

  # Collect unique issue numbers referenced in checklist (flexible format support).
  local issue_nums
  issue_nums="$(sed -nE 's/^- \[[ xX]\] .*#([0-9]+).*/\1/p' <<<"$body" | sort -n | uniq)"
  if [[ -z "${issue_nums:-}" ]]; then
    return 0
  fi

  # NOTE: macOS ships with Bash 3.2 which does not support associative arrays.
  # Keep this script Bash 3.x-compatible by storing issue states in a TSV string.
  local states_tsv
  states_tsv=""
  local n
  while read -r n; do
    [[ -z "$n" ]] && continue
    local st
    st="$(gh issue view -R "$REPO" "$n" --json state -q .state 2>/dev/null || echo UNKNOWN)"
    states_tsv+="${n}"$'\t'"${st}"$'\n'
  done <<<"$issue_nums"

  local new_body
  new_body=""
  local line num
  while IFS= read -r line; do
    # Check if line is an unchecked checklist item with an issue number
    if [[ "$line" =~ ^-\ \[\ \]\ .*\#([0-9]+) ]]; then
      num="${BASH_REMATCH[1]}"
      # If this issue is closed, mark it as checked
      if grep -Eq "^${num}[[:space:]]+CLOSED$" <<<"$states_tsv"; then
        # Replace - [ ] with - [x] at the start of the line
        new_body+="${line/- \[ \]/- [x]}"$'\n'
      else
        new_body+="$line"$'\n'
      fi
    else
      new_body+="$line"$'\n'
    fi
  done <<<"$body"

  if [[ "$new_body" == "$body" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] sync epic #$epic checklist (mark closed issues as [x])"
    return 0
  fi

  log "Syncing epic #$epic checklist (mark closed issues as [x]) ..."
  gh issue edit -R "$REPO" "$epic" --body-file - <<<"$new_body" >/dev/null
}

sync_all_epics() {
  local epic
  while read -r epic; do
    [[ -z "$epic" ]] && continue
    sync_epic_checklist "$epic"
  done < <(split_csv "$EPICS")
}

close_all_epics() {
  local epic
  while read -r epic; do
    [[ -z "$epic" ]] && continue
    local state
    state="$(gh issue view -R "$REPO" "$epic" --json state -q .state 2>/dev/null || true)"
    [[ "$state" != "OPEN" ]] && continue
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[dry-run] gh issue close -R $REPO $epic"
    else
      log "Closing epic #$epic ..."
      gh issue close -R "$REPO" "$epic" >/dev/null
    fi
  done < <(split_csv "$EPICS")
}

main() {
  parse_args "$@"

  # Make --auto-merge imply --auto-ready and --auto-approve for convenience.
  if [[ "$AUTO_MERGE" == "true" ]]; then
    AUTO_READY="true"
    AUTO_APPROVE="true"
  fi

  need gh
  need jq
  gh auth status >/dev/null 2>&1 || die "Not authenticated with gh. Run: gh auth login"

  if [[ -z "${REPO:-}" ]]; then
    REPO="$(default_repo)"
  fi
  [[ -n "${REPO:-}" ]] || die "Unable to determine repo. Pass --repo OWNER/REPO."
  [[ -n "${EPICS:-}" ]] || die "Missing --epics. Example: epic-queue.sh --epics 123,124"

  # Build a regex that matches any referenced epic issue number like "#212" in PR title/body.
  local issue_numbers
  issue_numbers="$(collect_all_epic_issue_numbers | tr '\n' ' ' | xargs -n1 | sort -n | uniq | tr '\n' ' ')"
  if [[ -z "$issue_numbers" ]]; then
    die "No checklist issue numbers found in epics: $EPICS"
  fi

  local issues_regex
  issues_regex="$(echo "$issue_numbers" | awk '{for(i=1;i<=NF;i++) printf("%s%s", (i==1?"":"|"), $i)}')"
  issues_regex="#(${issues_regex})\\b"

  init_progress_counts
  draw_progress

  local last_inflight=""

  while :; do
    if [[ "$AUTO_MERGE" == "true" ]]; then
      automerge_agent_prs "$issues_regex"
    fi

    local inflight
    if inflight="$(find_inflight_issue)"; then
      local info
      info="$(gh issue view -R "$REPO" "$inflight" --json title,url -q '{title:.title,url:.url}')"
      local title url
      title="$(echo "$info" | jq -r .title)"
      url="$(echo "$info" | jq -r .url)"

      CURRENT_ISSUE_NUM="$inflight"
      CURRENT_ISSUE_TITLE="$title"
      if [[ "$WATCH" == "true" && "$inflight" == "$last_inflight" ]]; then
        log "Waiting on $ASSIGNEE issue #$inflight (next check in ${INTERVAL_SECONDS}s)"
      else
        log "$ASSIGNEE assigned to #$inflight: $title"
        log "$url"
      fi
      last_inflight="$inflight"

      if [[ "$WATCH" == "true" ]]; then
        local sleep_for="$INTERVAL_SECONDS"
        if [[ -n "${SLEEP_HINT_SECONDS:-}" && "$SLEEP_HINT_SECONDS" -lt "$sleep_for" ]]; then
          sleep_for="$SLEEP_HINT_SECONDS"
        fi
        sleep "$sleep_for"
        continue
      fi
      log "Tip: pass --watch to keep polling until the issue is closed/merged."
      exit 0
    fi

    # Assign the next unchecked issue (epic order preserved).
    local assigned="false"
    local epic
    while read -r epic; do
      local issue
      while read -r issue; do
        [[ -z "$issue" ]] && continue
        local state
        state="$(gh issue view -R "$REPO" "$issue" --json state -q .state 2>/dev/null || true)"
        if [[ "$state" != "OPEN" ]]; then
          continue
        fi

        assign_issue_to_assignee "$issue"
        local info
        info="$(gh issue view -R "$REPO" "$issue" --json title,url -q '{title:.title,url:.url}')"
        local title url
        title="$(echo "$info" | jq -r .title)"
        url="$(echo "$info" | jq -r .url)"
        CURRENT_ISSUE_NUM="$issue"
        CURRENT_ISSUE_TITLE="$title"
        log "Assigned next issue: #$issue $title"
        log "$url"
        last_inflight="$issue"
        assigned="true"
        break 2
      done < <(epic_unchecked_issue_numbers "$epic")
    done < <(split_csv "$EPICS")

    if [[ "$assigned" == "true" ]]; then
      if [[ "$WATCH" == "true" ]]; then
        local sleep_for="$INTERVAL_SECONDS"
        if [[ -n "${SLEEP_HINT_SECONDS:-}" && "$SLEEP_HINT_SECONDS" -lt "$sleep_for" ]]; then
          sleep_for="$SLEEP_HINT_SECONDS"
        fi
        sleep "$sleep_for"
        continue
      fi
      exit 0
    fi

    log "No open unchecked issues remain in epics: $EPICS"
    if [[ "$SYNC_EPICS" == "true" ]]; then
      sync_all_epics
      close_all_epics
    else
      log "Tip: pass --sync-epics to automatically check off completed items and close the epic."
      log "If you still see open issues on GitHub, they may not be referenced in these epics."
    fi
    exit 0
  done
}

main "$@"
