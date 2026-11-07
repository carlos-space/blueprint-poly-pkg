#!/usr/bin/env bash
# Move a release train forward to a later stage. Forward only: a target at or before the train's current
# stage is refused.
#
# usage: advance-release.sh --line X.Y [--to beta|rc|ga] [--yes] [--dry-run]
#   --to   target stage; default is the next stage the train's units walk. The train's stages are the
#          union of the stages its units have in the policy file (release-policy.json), so a stage no unit
#          walks is skipped forward to the next one that some unit does, and the train may land later than
#          asked.
#
# The current stage is the newest Release-Train-Stage trailer on the train branch. Entering a stage moves each unit to the
# stage the policy file gives it there (scripts/lib/release-stages.sh, train_assign_stages). Only a unit
# that enters a new stage is touched: if it already shipped a prerelease in this train it gets one
# Release-As commit (1.2.0-alpha.3 → 1.2.0-beta.1), and the config then carries the new prerelease-type of
# every unit that moved. The Release-As is what switches the stage: for a version that is already a
# prerelease, release-please only bumps its trailing number and never reads prerelease-type. Units that
# stay at their stage, and units that have not released in this train yet, get no commit, with one exception:
# a python or rust unit with no <component>/v* tag on the remote (git ls-remote --tags origin; a failing
# query stops the script). release-please ignores its initial-version and counts on from the manifest, so
# the unit gets a Release-As commit with its first version (unit_first_version: {X.Y}.0-{stage}.1, from the
# initial-version of main's config), whether it enters the branch config now or is already in it with a
# stable manifest version or no manifest entry. The branch config's initial-version is then set to that
# version. A manifest version above the base stops the script. A unit that has a tag only has its config
# changed. Reaching ga hands over to finalize-release.sh --phase ga, which writes Release-As {X.Y}.0 for a
# python or rust unit in the config that has a stable manifest version and no tag. The product version comes
# from the Release-Plan trailer that cut-release.sh wrote, so nothing here takes it.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
cd "$REPO_ROOT"

line="" requested=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --line) line="$2"; shift 2 ;;
    --to) requested="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,${/^#/!q; p;}' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$line" =~ ^[0-9]+\.[0-9]+$ ]] || die "--line 需為 X.Y"
[[ -z "$requested" ]] || is_stage "$requested" || die "--to 需為 ${RELEASE_STAGES[*]:1}"
branch="release/v$line"

require_clean_tree
[[ "$(current_branch)" == "$branch" ]] || die "請在 $branch 上執行（目前 $(current_branch)）"
train_sync "$branch"
plan="$(train_plan_version "$line")" || die "$branch 上找不到 Release-Plan trailer，這條分支不是用 cut-release.sh --plan 開的"

current="$(train_stage)"
ci="$(stage_index "$current")"
declare -a units union
while IFS= read -r u; do [[ -n "$u" ]] && units+=("$u"); done < <(train_boarded_units)
mapfile -t union < <(stages_union "${units[@]}")
(( ci + 1 < ${#RELEASE_STAGES[@]} )) \
  || die "$branch 已是 ga，沒有下一個階段。GA 中途失敗要重跑時用 finalize-release.sh --line $line --phase ga"
next="$(stage_at_or_after "${RELEASE_STAGES[$((ci + 1))]}" "${union[@]}")"
[[ -n "$requested" ]] || requested="$next"
ri="$(stage_index "$requested")"
if (( ri < ci )); then die "不能往回：$branch 目前在 ${current}，目標 ${requested} 在它之前"; fi
if (( ri == ci )); then
  hint=""
  [[ -n "$(git rev-list "origin/$branch..HEAD" 2>/dev/null)" ]] \
    && hint="；本機比 origin/$branch 多出 commit，前一次推進若只差推送，執行 git push origin $branch"
  die "$branch 已在 ${current}，只能往後推進${hint}"
fi
target="$(stage_at_or_after "$requested" "${union[@]}")"
[[ "$target" == "$requested" ]] || info "階段 ${requested} 沒有單元走（本班單元走過的階段：${union[*]}），跳到 ${target}"
log "${branch}（${plan}）：${current} → ${target}"

if [[ "$target" == ga ]]; then
  log "交給 finalize-release.sh --phase ga"
  DRY_RUN="$DRY_RUN" ASSUME_YES="$ASSUME_YES" \
    exec bash "$(dirname "$0")/finalize-release.sh" --line "$line" --phase ga
fi

train_gates "$branch" "$line" "$target"
log "進入 ${target}：階段改變的單元各自換階段，已發過 prerelease 的從 .1 開始"
train_enter_stage "$branch" "$target"
external_retry push "$(remote_target)" git push origin "$branch"
printf '\n'
info "下一步：scripts/release/merge-release-pr.sh --line $line 合併 Release PR → 階段改變的單元打 -<階段>.1 tag → 部署到政策檔 targets 的去處。"
later=""
for s in "${union[@]}"; do (( $(stage_index "$s") > $(stage_index "$target") )) && later+="${later:+|}$s"; done
info "再推進：advance-release.sh --line $line [--to ${later}]"
