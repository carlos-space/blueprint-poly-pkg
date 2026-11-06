#!/usr/bin/env bash
# Write and check Release Plans, the files that assign product versions (docs/release-policy.md).
#
# usage: plan.sh maintenance [--hub-dir <path>]
#        plan.sh check <file>
#   maintenance  write the compact plan of the next patch after the latest plan in releases/: version,
#                units, Snapshot table and Rollback. The patch is the only version a plan written this way
#                can have; a milestone plan is written by hand.
#   check        succeed only when the plan is the next one after the latest other plan in its directory:
#                the next patch for a maintenance plan, the next minor or the next major for a milestone.
#                cut-release.sh --plan runs it before it opens a train.
#   --hub-dir    local clone of the primary repository, for a member repository (default: the directory
#                next to this repository named after product.primary). A member must name it to write a
#                plan there, because plans are not its own files.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
cd "$REPO_ROOT"

cmd="${1:-}"; [[ $# -eq 0 ]] || shift
file="" explicit_hub=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hub-dir) HUB_DIR="$2"; export HUB_DIR; explicit_hub=1; shift 2 ;;
    -h|--help) sed -n '2,${/^#/!q; p;}' "$0"; exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) [[ -z "$file" ]] || die "只收一個檔案"; file="$1"; shift ;;
  esac
done

case "$cmd" in
  maintenance)
    [[ -z "$file" ]] || die "maintenance 不收檔案"
    if [[ -n "$(jq -r '.product.primary // empty' "$(policy_file)" 2>/dev/null)" ]] && (( ! explicit_hub )); then
      die "成員倉庫不寫 plan。到主檔（hub）的 clone 執行，或明確帶 --hub-dir <hub 的路徑>"
    fi
    path="$(plan_write_maintenance)"
    log "寫出 ${path}"
    info "填入入版單元後 commit 進主檔，再用 cut-release.sh --plan 開線"
    ;;
  check)
    [[ -n "$file" ]] || die "check 需要 plan 檔案：plan.sh check <file>"
    plan_check "$file"
    ;;
  *) die "用法：plan.sh maintenance [--hub-dir <路徑>] | plan.sh check <file>" ;;
esac
