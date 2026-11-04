#!/usr/bin/env bash
# Lock repositories to squash-merge so release-please reads exactly what ci.yml checked, and set the
# repository-level retention of Actions artifacts and logs.
#
#   allow_merge_commit / allow_rebase_merge = false
#     A merge commit or a rebase lands every branch commit on main, while ci.yml checks only the PR title.
#   squash_merge_commit_title = PR_TITLE
#     The default COMMIT_OR_PR_TITLE takes the commit message when the branch has one commit, which
#     bypasses the title check.
#   squash_merge_commit_message = PR_BODY
#     Puts Closes #N and the BREAKING CHANGE: footer into the commit body.
#   delete_branch_on_merge = true
#     The merge flow runs `gh pr merge --squash` without `--delete-branch`, and agents may not delete
#     remote branches, so this setting is what removes the remote branch.
#   artifact-and-log-retention days
#     Applies only to what is created afterwards, so set it before the first real run.
#
# The values of squash, delete-branch and days come from github-repo-settings.json next to this script,
# a copy of blueprint.merge.method and blueprint.retention.repository-days (tests/repo-settings.test.mjs
# fails when they drift).
#
# Reads the current values first and sends only the requests that change something. A failing repository
# does not stop the others; the failed ones are listed at the end and the exit status is 1.
# External write (modify) → confirmation + audit.
# usage: github-repo-settings.sh [--yes] [--dry-run] [<owner/repo>...]   (no repository: the current one)
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

repos=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -*) die "unknown argument: $1" ;;
    *) repos+=("$1"); shift ;;
  esac
done
if (( ${#repos[@]} == 0 )); then repos=("$(gh repo view --json nameWithOwner --jq .nameWithOwner)"); fi

settings="$(dirname "$0")/github-repo-settings.json"
squash="$(jq -r '.squash' "$settings")"
delete_branch="$(jq -r '.deleteBranchOnMerge' "$settings")"
days="$(jq -r '.retentionDays' "$settings")"
[[ "$squash" == true && "$delete_branch" == true && "$days" =~ ^[0-9]+$ ]] || die "invalid $settings"

# field=value pairs of the merge settings; -F makes true/false booleans, -f keeps strings
merge_args=(-F "allow_squash_merge=$squash" -F allow_merge_commit=false -F allow_rebase_merge=false
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY -F "delete_branch_on_merge=$delete_branch")
merge_filter='.allow_squash_merge == true and .allow_merge_commit == false and .allow_rebase_merge == false
  and .squash_merge_commit_title == "PR_TITLE" and .squash_merge_commit_message == "PR_BODY"
  and .delete_branch_on_merge == true'

apply_repo() { # apply_repo <owner/repo>; returns 1 when a request failed
  local repo="$1" current current_days
  log "repo ${repo}：只允許 squash 合併，artifact 與 log 保留 ${days} 天"
  if (( DRY_RUN )); then
    external "github.com/$repo" gh api -X PATCH "repos/$repo" "${merge_args[@]}" || return 1
    external "github.com/$repo" gh api -X PUT "repos/$repo/actions/permissions/artifact-and-log-retention" -F "days=$days" || return 1
    return 0
  fi
  current="$(gh api "repos/$repo")" || return 1
  if jq -e "$merge_filter" <<<"$current" >/dev/null; then
    info "合併設定已是只開 squash，不送"
  else
    external "github.com/$repo" gh api -X PATCH "repos/$repo" "${merge_args[@]}" || return 1
  fi
  current_days="$(gh api "repos/$repo/actions/permissions/artifact-and-log-retention" --jq .days)" || return 1
  if [[ "$current_days" == "$days" ]]; then
    info "已是 ${days} 天，不送"
  else
    external "github.com/$repo" gh api -X PUT "repos/$repo/actions/permissions/artifact-and-log-retention" -F "days=$days" || return 1
  fi
}

failed=()
for repo in "${repos[@]}"; do
  if ! apply_repo "$repo"; then
    warn "repo ${repo}：失敗"
    failed+=("$repo")
  fi
done

if (( ${#failed[@]} )); then
  printf '\n%s\n' "✗ ${#failed[@]} 個倉失敗：" >&2
  printf '  - %s\n' "${failed[@]}" >&2
  exit 1
fi
printf '\n'
info "核對：gh api repos/<repo> --jq '{allow_squash_merge, allow_merge_commit, allow_rebase_merge, squash_merge_commit_title, squash_merge_commit_message, delete_branch_on_merge}'"
