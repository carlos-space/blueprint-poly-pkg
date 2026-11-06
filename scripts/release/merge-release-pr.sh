#!/usr/bin/env bash
# Merge the Release PR of a release line. This is the one way to merge it: the fact-kit check below is only
# a gate when the merge goes through it, because a private repository on the free plan cannot make a
# check required.
#
# usage: merge-release-pr.sh --line X.Y [--yes] [--dry-run]
#
# Order, on release/vX.Y:
#   1. wait until no release-please run is queued and the Release PR's head has stopped moving
#   2. the units this merge releases: the manifest on the PR's head against origin/release/vX.Y, the PR's
#      version for each unit that differs. Each version is checked before anything else happens (see below)
#   3. with facts/: for each unit that has a component package (the package's built "describes" names it),
#      `fact-kit pin --version <v> --cwd facts/<dir>`. Pinned rows are committed on the release branch as
#      `chore(facts)`; the branch is pushed whenever it is ahead of origin, so a run whose push was skipped or
#      failed pushes on the next run. Never on the PR branch, which release-please rewrites with force
#   4. wait for release-please again, and stop if the PR now releases something else than what was pinned
#   5. `fact-kit check --train <unit>=<v>` for those units. A row still saying "next" that is not pending
#      fails it, printed as <file>:<line>. This script does not pin again on its own: fix the row (or mark it
#      pending) and run the script again
#   6. `gh pr merge --squash --match-head-commit <sha>`
# A repository without facts/ skips 3 and 5 and merges.
#
# Version check (git-release asks for it, and a wrong Release PR was merged without it: sdk-py and sdk-rs went from
# 0.1.0 to 0.2.0-alpha.1). Right after step 2, and again after the branch was pushed, every unit's PR version is
# compared with what it must be:
#   - a unit with no <component>/v* tag on the remote: the first version of unit_first_version (the same function
#     advance-release.sh and finalize-release.sh write Release-As from), e.g. 0.1.0-beta.1
#   - a unit with a tag: the stage name of its version equals its stage in the branch config (ga once the line is at
#     ga) and is not later than its result stage on the line, which the policy gives and which is never earlier than the
#     stage of the line (1.2.0-alpha.1 → 1.2.0-alpha.2 passes, 0.2.0-alpha.1 for a unit at beta does not)
# release-please may not have recomputed the PR after the latest push, so a mismatch is not final: the PR is read again
# the way release_pr_settle waits (POLL_TRIES times, POLL_SLEEP apart). Only when it still does not match at the end
# the script stops without merging and prints the unit, the PR version and the expected one.
#
# The document package (docs/) is pinned in the same place as the facts, by clarify-kit pin: for each unit this
# merge releases, the "next" of docs/<unit>/**/*.doc.ts becomes the PR's version for that unit, committed as
# `chore(docs)` and pushed together with the `chore(facts)` commit (scripts/lib/docs.sh; the product layer,
# docs/product, was pinned to the product version when cut-release.sh opened the train).
#
# The release line must be checked out, with a clean tree.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
cd "$REPO_ROOT"

line=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --line) line="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; export ASSUME_YES; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,${/^#/!q; p;}' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$line" =~ ^[0-9]+\.[0-9]+$ ]] || die "--line 需為 X.Y"
branch="release/v$line"
target="$(remote_target)"

require_clean_tree
[[ "$(current_branch)" == "$branch" ]] || die "請在 $branch 上執行（目前 $(current_branch)）"
train_sync "$branch"

if (( DRY_RUN )); then
  log "[dry-run] 合併 $branch 的 Release PR 的順序："
  info "1. 等 release-please 閒置、Release PR 的 head 穩定"
  if has_facts; then
    info "2. 這次要釘的單元：Release PR 的 manifest 對 origin/$branch 有差異的單元，版號取 PR 的值"
    info "   同時核對每個單元的 PR 版號：沒有 tag 的單元要等於第一版版號，有 tag 的單元階段要對上設定且不晚於它在這條線的結果階段；不符就重讀 PR，等到對上或逾時才停"
    info "3. 逐個 component 套件 fact-kit pin --version <v>，有變動才提交並推送 chore(facts)"
    info "4. 再等閒置，確認 PR 沒變"
    info "5. fact-kit check --train <單元>=<v>"
    info "對得到 component 套件的單元："
    facts_components | sed 's/^/    /' | tr '\t' ' '
  else
    info "沒有 facts/：略過 pin 與 check"
  fi
  if has_docs; then
    info "文件套件：對 docs/<單元> 存在的單元，用 clarify-kit pin 把 *.doc.ts 的 next（since、decision 的 appliesFrom、requirement 的 release）釘成 PR 的版號，pending 不動，有變動才提交 chore(docs)"
  fi
  info "6. gh pr merge --squash --match-head-commit <sha>"
  exit 0
fi

# GA 的 Release PR 一律是正式版號，所以階段是 ga 時等 PR 內容收斂到沒有 prerelease
declare -a settle_opts=()
[[ "$(train_stage)" == ga ]] && settle_opts+=(--expect-stable)
release_pr_settle "$branch" ${settle_opts[@]+"${settle_opts[@]}"}
n="$RELEASE_PR_NUMBER" sha="$RELEASE_PR_SHA"

declare -a units=()
read_units() {
  units=()
  local out row
  git fetch -q origin "$branch" || die "取 manifest 失敗：git fetch origin $branch 沒成功"
  out="$(release_pr_units "$branch")" || die "取 manifest 失敗：讀不到 Release PR 或 origin/${branch} 的 manifest，不是「沒有差異」"
  while IFS= read -r row; do [[ -n "$row" ]] && units+=("$row"); done < <(sort <<<"$out")
}
read_units
(( ${#units[@]} )) || die "Release PR #${n} 對 origin/${branch} 的 manifest 沒有差異，沒有可合併的版號"

# check_unit_version <unit> <pr version> → adds a line to version_problems when the version is not what it must be.
# Runs in the shell itself, not in $(...), because unit_released stops the script when it cannot read the tags.
declare -a version_problems=()
check_unit_version() {
  local u="$1" v="$2" p type base stage vs line_stage latest cur want
  p="$(jq -r --arg u "$u" '.packages | to_entries[] | select((.value.component // (.key | split("/") | last)) == $u) | .key' "$CONFIG" | head -1)"
  [[ -n "$p" ]] || return 0
  stage="$(config_unit_stage "$p")"
  # once the line is at ga the Release PR carries final versions, while the config of a unit still says its last prerelease
  # stage until the merge-back restores it
  [[ "$(train_stage)" != ga ]] || stage=ga
  if unit_released "$u"; then
    if ! vs="$(version_stage "$v")"; then
      version_problems+=("${u} PR 版號 ${v}，預期階段 ${stage} 的版號（X.Y.Z 或 X.Y.Z-<階段>.N）")
      return 0
    fi
    # a unit that only walks ga ships its final version at once, so on an early line its own stage (ga) is the latest
    # one it may be in; any other unit may not be later than the line
    line_stage="$(train_stage)"
    latest="$line_stage"
    if policy_unit_exists "$u"; then
      latest="$(unit_stage_at "$u" "$line_stage")"
      [[ -n "$latest" ]] || latest="$line_stage"
      (( $(stage_index "$latest") >= $(stage_index "$line_stage") )) || latest="$line_stage"
    fi
    if [[ "$vs" != "$stage" ]] || (( $(stage_index "$vs") > $(stage_index "$latest") )); then
      version_problems+=("${u} PR 版號 ${v}，預期階段 ${stage}（設定裡的階段，且不晚於 ${latest}）")
    fi
    return 0
  fi
  type="$(unit_release_type "$p")"
  base="$(unit_main_base_version "$p" "$line")"
  cur="$(git show "origin/$branch:$MANIFEST" | jq -r --arg p "$p" '.[$p] // empty')"
  want="$(unit_first_version "$type" "$base" "$stage" "$line" "$cur")"
  [[ "$v" == "$want" ]] || version_problems+=("${u} PR 版號 ${v}，預期 ${want}（沒有 tag，第一版）")
  return 0
}

# verify_versions: check every unit; on a mismatch read the PR again and check again, up to POLL_TRIES times
verify_versions() {
  local i pair
  for ((i=1; i<=POLL_TRIES; i++)); do
    version_problems=()
    for pair in "${units[@]}"; do check_unit_version "${pair% *}" "${pair#* }"; done
    (( ${#version_problems[@]} )) || return 0
    if (( i == POLL_TRIES )); then
      printf '✗ Release PR #%s 的版號不符，不合併：\n' "$n" >&2
      printf '    %s\n' "${version_problems[@]}" >&2
      exit 1
    fi
    warn "Release PR #${n} 的版號和預期不符，等 release-please 重算（${i}/${POLL_TRIES}）：${version_problems[*]}"
    sleep "$POLL_SLEEP"
    release_pr_settle "$branch" ${settle_opts[@]+"${settle_opts[@]}"}
    n="$RELEASE_PR_NUMBER" sha="$RELEASE_PR_SHA"
    read_units
    (( ${#units[@]} )) || die "Release PR #${n} 對 origin/${branch} 的 manifest 沒有差異，沒有可合併的版號"
  done
}
verify_versions
info "這次合併會發：${units[*]}"

if has_facts; then
  declare -A comp_units=()
  comps="$(facts_components)"
  while IFS=$'\t' read -r _ u; do [[ -n "$u" ]] && comp_units[$u]=1; done <<<"$comps"
  declare -a pinned=()
  for pair in "${units[@]}"; do
    u="${pair% *}" v="${pair#* }"
    [[ -n "${comp_units[$u]:-}" ]] || continue
    facts_pin "$u" "$v"
    pinned+=("$u@$v")
  done
  if [[ -n "$(git status --porcelain -- facts)" ]]; then
    git add -- facts
    run git commit -q -m "chore(facts): 釘 next 為 ${pinned[*]}" \
      -m "合併 Release PR #${n} 之前，把這次要發的單元的 next 釘成 PR 的版號。釘在發布分支，不放 Release PR 分支，因為 release-please 重算時會強制改寫它。"
  else
    info "⊘ 沒有要釘的 next，不加新的 commit"
  fi
fi

# 文件套件：和 facts 同一個位置釘，用 clarify-kit pin。docs/<單元> 存在的單元，才釘成 PR 給它的版號
if has_docs; then
  declare -a docs_pinned=()
  for pair in "${units[@]}"; do
    u="${pair% *}" v="${pair#* }"
    [[ -d "docs/$u" ]] || continue
    docs_pin_unit "$u" "$v"
    docs_pinned+=("$u@$v")
  done
  if [[ -n "$(git status --porcelain -- docs)" ]]; then
    git add -- docs
    run git commit -q -m "chore(docs): 釘 next 為 ${docs_pinned[*]}" \
      -m "合併 Release PR #${n} 之前，把這次要發的單元的文件 next 釘成 PR 的版號。釘在發布分支，不放 Release PR 分支，因為 release-please 重算時會強制改寫它。"
  else
    info "⊘ 文件套件沒有要釘的 next，不加新的 commit"
  fi
fi

if has_facts || has_docs; then
  # 看本機是否領先遠端，不看這次有沒有新變動：上一次可能建好 commit 卻沒推出去（答 n、沒帶 --yes、推送失敗），
  # 重跑時 facts 已乾淨，只看變動會跳過推送，check 讀本機工作樹通過，釘版卻沒到遠端
  if (( $(git rev-list --count "origin/$branch..HEAD") > 0 )); then
    external "$target" git push origin "$branch"
    if (( ${#SKIPPED_EXTERNAL[@]} )); then
      warn "推送沒有執行，停在這裡：確認後帶 --yes 重跑"
      exit 0
    fi
    # 推送會讓 release-please 再跑一次，PR 可能被重算
    release_pr_settle "$branch" ${settle_opts[@]+"${settle_opts[@]}"}
    n="$RELEASE_PR_NUMBER" sha="$RELEASE_PR_SHA"
    before="${units[*]}"
    read_units
    [[ "${units[*]}" == "$before" ]] \
      || die "釘版期間 Release PR #${n} 變了（原本 ${before}，現在 ${units[*]}），版號可能對不上。重跑本腳本"
    verify_versions
  fi
fi

if has_facts; then
  # 等待期間可能又有修補合進發布分支。check 要讀合併時發布分支的內容，所以先同步到遠端最新
  train_sync "$branch"
  declare -a train=()
  for pair in "${units[@]}"; do train+=("${pair% *}=${pair#* }"); done
  facts_train_check "${train[@]}" \
    || die "fact-kit check --train 未通過（上面列出 <檔案>:<行>）。修正後重跑 merge-release-pr.sh --line ${line}，不會自動重釘"
else
  info "⊘ 沒有 facts/，略過 pin 與 fact-kit check"
fi

release_pr_squash "$n" "$sha"
printf '\n'
info "已合併 Release PR #${n}。下一步見該階段的說明：advance-release.sh 或 finalize-release.sh --phase ga|merge-back"
