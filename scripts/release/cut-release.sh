#!/usr/bin/env bash
# Open a release train: create release/v<line> for a Release Plan and scope release-please to the train's
# units. Every unit gets the stage the policy file (release-policy.json) gives it at the train's first stage,
# so units of one train can sit at different stages. advance-release.sh moves the train on, forward only.
#
# usage: cut-release.sh --plan vX.Y.Z --units product-web,product-api,product-sdk-core [--from main|vX.Y.Z] [--hub-dir <path> | --plan-file <path>] [--yes] [--dry-run]
#   --plan     the Release Plan this train ships (releases/release-plan-vX.Y.Z.md). The plan must be the next one
#              after the latest plan (plan.sh check). The train's product line is X.Y of the plan and names the
#              branch release/vX.Y. The opening commit records the plan in a Release-Plan trailer, which
#              advance-release.sh and finalize-release.sh read the product version from.
#   --units    comma list of units in this train (any axis: apps, packages, libs). A unit with no commits since its
#              last tag simply does not release. Two kinds of unit are added on top of the list: units that
#              depend on a listed unit, and units a prerelease unit depends on that have changed (see below).
#   --from     base: main (default) or a product tag such as v1.3.0, for a post-GA hotfix train.
#              Once the line has a vX.Y.Z tag, --from must name its latest one.
#   --hub-dir  local clone of the primary repository, where a member repository reads the plan from (default:
#              the directory next to this repository named after product.primary in the policy file).
#   --plan-file  the Release Plan itself, a file named release-plan-vX.Y.Z.md. A member repository whose CI opens the
#              train (open-release-line.yml) gets the content of the plan from the hub as a workflow input, so it has no
#              hub clone to read it from. Use it instead of --hub-dir: the plan is not read from releases/ or the hub,
#              and plan.sh check runs on the file alone, because the hub has already checked it against the plans beside it.
#
# The first stage of the train is the earliest stage any of its units walks. Each unit then takes the last stage
# of its own policy stages that is not after that, or its first stage when it has none (a unit that only has ga
# ships its final version right away). A unit that a unit in a prerelease depends on, and that has changed, follows
# that unit's stage to ga instead; a dependency that has not changed is not boarded. The stage of each unit is
# written into the config as its own versioning and prerelease-type, and the train's stage into a
# Release-Train-Stage trailer on the opening commit. A unit the first stage has not reached is deferred: it
# stays out of the config, and the Release-Train-Units trailer remembers every boarded unit.
#
# No version is pinned here: release-please's prerelease strategy derives each unit's own next
# version from its own commits, which is what keeps unit versions independent of the product marker.
# The config's prerelease-type is "<stage>.1", which the strategy appends to a unit's first bump
# (1.3.1 + feat → 1.4.0-alpha.1); a unit that never shipped starts at its initial-version plus the stage: the
# initial-version its config entry already has (0.1.0-alpha.1), else the product line (<line>.0-<stage>.1).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
cd "$REPO_ROOT"

plan="" units_csv="" from="main" plan_file_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) plan="$2"; shift 2 ;;
    --units) units_csv="$2"; shift 2 ;;
    --from) from="$2"; shift 2 ;;
    --hub-dir) HUB_DIR="$2"; export HUB_DIR; shift 2 ;;
    --plan-file) plan_file_arg="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,${/^#/!q; p;}' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$plan" && -n "$units_csv" ]] || die "--plan 與 --units 必填"
[[ "$plan" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "--plan 需為 vX.Y.Z（Release Plan 的產品版號）"
line="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
branch="release/v$line"
IFS=, read -r -a units <<<"$units_csv"

policy_require
bash "$(dirname "$0")/../ci/check-release-policy.sh" || die "政策檔與倉庫不一致，先修正再開線"
if [[ -n "$plan_file_arg" ]]; then
  [[ "${plan_file_arg##*/}" == "release-plan-$plan.md" ]] || die "--plan-file 的檔名需為 release-plan-$plan.md：${plan_file_arg##*/}"
  plan_file="$plan_file_arg"
else
  plan_file="$(plan_dir)/release-plan-$plan.md"
fi
[[ -f "$plan_file" ]] || die "找不到 Release Plan：${plan_file}。先寫好並提交，或用 plan.sh maintenance 寫維護型的 plan"
plan_check "$plan_file"

require_clean_tree
run git fetch --prune --tags origin
declare -a existing=()
while IFS= read -r b; do [[ -n "$b" ]] && existing+=("$b"); done < <(release_branches)
[[ -z "${existing[0]:-}" ]] || die "遠端已有 release 分支：${existing[*]}（不變式：任一時刻 ≤ 1 條）"
git rev-parse -q --verify "refs/heads/$branch" >/dev/null && die "本地已有 ${branch}，先刪除或改用它"
git rev-parse -q --verify "refs/tags/$plan" >/dev/null && die "產品 tag ${plan} 已存在，這份 plan 已經發布過"

# A line that already shipped takes patches only, and a patch must continue from the line's latest
# GA: cut from main it carries everything merged since, cut from an older tag it drops a shipped fix.
# Refuse instead of picking the tag, so the base stays explicit.
shipped="$(git tag --list "v${line}.*" | grep -E "^v${line//./\\.}\.[0-9]+$" | sort -t. -k3,3n | tail -1 || true)"
if [[ -n "$shipped" && "$from" != "$shipped" ]]; then
  die "產品線 v${line} 已發布到 ${shipped}，修補發布要接在它後面（目前起點 ${from}）：改帶 --from ${shipped}。修正已在 main 時，切出後把它 cherry-pick 進 ${branch}。要發下一個 minor 就改用新的 plan"
fi
[[ -n "$shipped" || "${plan##*.}" == 0 ]] || die "${plan} 是 patch，但產品線 v${line} 還沒有產品 tag，沒有可修補的發布"
if [[ "$from" == "main" ]]; then base="origin/main"; else
  git rev-parse -q --verify "refs/tags/$from" >/dev/null || die "起點 tag 不存在：${from}（發布後 hotfix 需自產品 tag 如 v1.3.0 重建，不從 main）"
  base="$from"
fi
for u in "${units[@]}"; do
  unit_path "$u" >/dev/null || die "unit 不存在：$u"
  policy_unit_exists "$u" || die "政策檔沒有單元 ${u}，先為它決定階段（docs/release-policy.md）"
done

# Where this train should start counting commits.
#
# release-please walks main's history newest-first and stops at the previous release's commit. A
# commit that landed on main while the previous train was stabilising is *older* than that release
# commit, so the walk never reaches it and the change is silently dropped from the next release.
# Anchoring on the previous train's branch point instead makes those commits visible again. The
# cost is that a fix already shipped by the previous train can appear once more in this train's
# changelog, which is the usual behaviour of release-branch workflows (a patch released on the
# maintenance line is also "new" relative to the line it was cut from).
# 前一次發布的切點由它自己在合回時寫進 commit 訊息的 Release-Train-Base trailer，不靠事後反推：
# 發布分支以 squash 合回，main 上沒有可取父節點的 merge commit，且切點本來就是切分支當下已知的事實。
if [[ "$from" == "main" ]]; then
  # 修補發布自產品 tag 重建，它合回時寫進 main 的 Release-Train-Base 指向發布分支上的 commit，而發布分支
  # 以 squash 合回，那個 commit 不是 main 的祖先。以它為界，回溯永遠走不到而重新計入全部歷史：
  # 實測 v1.4 因此把已發布過的破壞性變更再算一次，版號自 2.1.0 誤跳 3.0.0。逐筆往回找，取第一個
  # 確實在起點歷史上的切點。回溯不設筆數上限：切點是上一次發布的事實，離現在多遠都要找得到，
  # 只看最近 200 筆時，兩次發布之間 main 超過 200 筆就會誤判成「無前一次發布」而重算全部歷史。
  prev_cut=""
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    if git merge-base --is-ancestor "$c" "$base" 2>/dev/null; then prev_cut="$c"; break; fi
    info "略過非主線切點 ${c:0:7}（修補發布自 tag 重建，其切點不在 main 上）"
  done < <(git log origin/main --format='%(trailers:key=Release-Train-Base,valueonly)' 2>/dev/null | grep -E '^[0-9a-f]{7,40}$' || true)
else
  # 自產品 tag（如 v1.3.0）重建的修補發布：該 tag 之前的內容全部已發布，起算點就是它本身。
  # 沿用前一次發布的切點會把上一版已發過的功能重新計入，把 patch 誤算成 minor。
  prev_cut="$(git rev-parse "${from}^{commit}")"
fi

# What boards, on top of --units, until nothing more is added:
#   - workspace dependents: node-workspace only bumps packages present in the config, so a dependent
#     left out of the train would keep a dependency range pointing at the old version.
#   - linked-versions group members: the group shares one version, so it boards all or nothing.
#   - the aggregate packages (the config entries at path "facts" and path "docs", when those directories
#     exist): every train carries them, and release-please releases one only when commits touched its path.
#   - dependencies that have changed since the previous cut, of a unit that is in a prerelease: they follow
#     that unit's stage (train_assign_stages), so what is validated is the set shipping together. A dependency
#     that has not changed stays out.
# They feed each other (a pulled-in dependent may belong to a group, and a group member has its own
# dependents), hence the fixpoint loop rather than one pass of each. The stages depend on the boarded
# units, so each pass recomputes them.
declare -a added union
declare -A stage_of
while :; do
  added=()
  while IFS= read -r agg; do
    [[ -n "$agg" ]] && unit_path "$agg" >/dev/null 2>&1 && ! in_array "$agg" "${units[@]}" || continue
    units+=("$agg"); added+=("$agg")
    if [[ "$(unit_path "$agg")" == docs ]]; then info "自動納入文件套件：$agg"; else info "自動納入 facts 匯總套件：$agg"; fi
  done < <(aggregate_unit)
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    in_array "$d" "${units[@]}" && continue
    units+=("$d"); added+=("$d"); info "自動納入相依單元：$d"
  done < <(workspace_dependents "${units[@]}")
  while IFS= read -r g; do
    [[ -n "$g" ]] || continue
    in_array "$g" "${units[@]}" && continue
    units+=("$g"); added+=("$g"); info "自動納入共享版號群組成員：$g"
  done < <(linked_group_members "${units[@]}")
  mapfile -t union < <(stages_union "${units[@]}")
  line_stage="${union[0]}"
  stage_of=()
  while read -r u st; do stage_of[$u]="$st"; done < <(train_assign_stages "$line_stage" "${units[@]}")
  edges="$(dependency_edges)"
  for u in "${units[@]}"; do
    [[ -n "${stage_of[$u]}" && "${stage_of[$u]}" != ga ]] || continue
    while read -r from_unit d; do
      [[ "$from_unit" == "$u" ]] || continue
      in_array "$d" "${units[@]}" && continue
      unit_path "$d" >/dev/null 2>&1 || continue
      unit_changed "$d" "${prev_cut:-}" "$base" || continue
      units+=("$d"); added+=("$d"); info "自動納入有變更的相依單元：${d}（${u} 在 ${stage_of[$u]}）"
    done <<<"$edges"
  done
  (( ${#added[@]} )) || break
done
# A unit the line has not reached yet is deferred: it stays out of the config, so release-please does not
# release it, and advance-release.sh brings it in when the line gets to its first stage.
declare -a paths active=() deferred=()
for u in "${units[@]}"; do
  if [[ -n "${stage_of[$u]}" ]]; then active+=("$u"); paths+=("$(unit_path "$u")"); else deferred+=("$u"); fi
done
stage="$line_stage"

log "切 ${branch}（base ${base}，plan ${plan}），train 單元：${units[*]}"
run git switch -c "$branch" "$base"

# A train rebuilt from a product tag also rewinds scripts/, the workflows and the config to that tag;
# refresh the release tooling from main so the train runs the current flow, not the flow of the day it
# shipped. git restore (not checkout) also deletes what main has since deleted or renamed. A path main
# does not have is skipped.
declare -a sync_paths=()
if [[ "$from" != "main" ]]; then
  log "自 main 更新發布工具（重建的 train 否則會跑該 tag 當時的舊腳本）"
  mapfile -t sync_paths < <(main_existing_paths "${RELEASE_REBUILD_PATHS[@]}")
  run git restore --source=origin/main --staged --worktree -- "${sync_paths[@]}"
  if (( DRY_RUN )); then info "[dry-run] 以 main 的 manifest 為底補上非 train 單元版號"; else
    keep="$(printf '"%s",' "${paths[@]}")"; keep="[${keep%,}]"
    tmp="$(mktemp)"
    jq -s --argjson keep "$keep" '.[0] * (.[1] | with_entries(select(.key as $k | $keep | index($k))))' \
      <(git show origin/main:"$MANIFEST") "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
    git add "${sync_paths[@]}" "$MANIFEST" 2>/dev/null || true
  fi
fi

# A unit that has never shipped has no release for the prerelease strategy to bump from, so
# release-please would take initial-version verbatim (1.0.0 when unset). Start it at this line, in
# the same format the unit's stage gives every other unit.
declare -a fresh=()
stagemap="{}"
for u in "${deferred[@]:-}"; do
  [[ -n "$u" ]] && info "${u}：發布線還沒到它的第一個階段（$(policy_unit_stages "$u" | head -1)），先不發，推進到那個階段才入版"
done
for u in "${active[@]}"; do
  p="$(unit_path "$u")"; ust="${stage_of[$u]}"
  stagemap="$(jq -c --arg p "$p" --arg s "$ust" '. + {($p): $s}' <<<"$stagemap")"
  initial="$(stage_initial_version "$(unit_base_version "$p" "$line")" "$ust")"
  case "$(policy_unit_kind "$u")" in
    package|sdk) tgt="註冊中心" ;;
    *) tgt="$(stage_target "$u" "$ust" || printf '%s' '（政策檔沒有去處）')" ;;
  esac
  if unit_released "$u"; then
    info "${u}：目前 $(manifest_version "$p")，${ust} → ${tgt}；第一個版本由 release-please 依 commit 計算"
    continue
  fi
  fresh+=("$p"); info "${u}：首次發布，${ust} → ${tgt}，起始版號 ${initial}"
done
freshj="[]"; (( ${#fresh[@]} )) && { freshj="$(printf '"%s",' "${fresh[@]}")"; freshj="[${freshj%,}]"; }

# scope the config to the train, then put every unit at its stage
keep="$(printf '"%s",' "${paths[@]}")"; keep="[${keep%,}]"
tmp="$(mktemp)"; tmp2="$(mktemp)"
keepc="$(printf '"%s",' "${active[@]}")"; keepc="[${keepc%,}]"
jq --argjson keep "$keep" --argjson keepc "$keepc" --arg sha "${prev_cut:-}" \
  --argjson fresh "$freshj" --argjson st "$stagemap" --arg line "$line" '
  .packages |= with_entries(select(.key as $k | $keep | index($k)))
  | .packages |= with_entries(if (.key as $k | $fresh | index($k)) then .value."initial-version" = ((.value."initial-version" // "\($line).0") as $b | if $st[.key] == "ga" then $b else "\($b)-\($st[.key]).1" end) else . end)
  # 群組成員未全數納入的 linked-versions 條目會指向設定中不存在的 component，一併移除
  | .plugins = ((.plugins // []) | map(
      select(.type != "linked-versions" or (((.components // []) - $keepc) | length) == 0)))
  | if $sha == "" then . else ."last-release-sha" = $sha end
' "$CONFIG" > "$tmp"
config_with_stages "$tmp" "$stagemap" > "$tmp2"; rm -f "$tmp"; tmp="$tmp2"
if [[ -n "${prev_cut:-}" ]]; then
  [[ "$from" == "main" ]] && info "起算點：${prev_cut:0:7}（前一次發布自 main 的切點）" || info "起算點：${prev_cut:0:7}（${from}）"
else
  info "起算點：無前一次發布，自歷史起頭計算"
fi
info "起始階段：${stage}（本班單元走過的階段：${union[*]}）"
if (( DRY_RUN )); then info "[dry-run] $CONFIG 會縮為："; jq -c '{"last-release-sha", plugins: [.plugins[].type], packages: (.packages | to_entries | map({(.key): {versioning: .value.versioning, "prerelease-type": .value."prerelease-type", "initial-version": .value."initial-version"}}) | add)}' "$tmp"; rm -f "$tmp"; else mv "$tmp" "$CONFIG"; fi
run git add "$CONFIG"
# The product layer of the document package (docs/product) says "next" for what this train ships; the plan
# names the product version, so pin it in the opening commit. The component layer is pinned with each unit's
# version by merge-release-pr.sh (scripts/lib/docs.sh).
docs_note=""
if has_docs && [[ -d "$REPO_ROOT/$DOCS_PRODUCT_DIR" ]]; then
  if (( DRY_RUN )); then info "[dry-run] 會用 clarify-kit pin 把 ${DOCS_PRODUCT_DIR} 的 next（since、decision 的 appliesFrom、requirement 的 release）釘成 ${plan#v}"; else
    docs_pin_product "${plan#v}"
    if [[ -n "$(git status --porcelain -- "$DOCS_PRODUCT_DIR")" ]]; then
      git add -- "$DOCS_PRODUCT_DIR"
      docs_note=" 文件 ${DOCS_PRODUCT_DIR} 的 next 已釘成產品版號 ${plan#v}。"
    else info "⊘ ${DOCS_PRODUCT_DIR} 沒有要釘的 next"; fi
  fi
fi
base_sha="$(git rev-parse "${base}^{commit}")"
unit_stages="$(for u in "${units[@]}"; do printf '%s=%s ' "$u" "${stage_of[$u]:-待命}"; done)"
body="起始階段 ${stage}：各單元依政策檔取自己的階段（${unit_stages% }），release-please 於本分支以各單元的 versioning 與 prerelease-type 計算版號；advance-release.sh 往後推進，到 ga 時由 finalize-release.sh 收斂。${docs_note}"
run git commit -q -m "chore($branch): open train at $stage with ${units[*]}" -m "$body

Release-Train-Base: $base_sha
Release-Plan: $plan
Release-Train-Units: ${units[*]}
Release-Train-Stage: $stage"

log "推送分支（觸發 release-please → 各單元的 Release PR）"
external "$(remote_target)" git push -u origin "$branch"
printf '\n'
if [[ "$stage" == ga ]]; then
  info "下一步：scripts/release/merge-release-pr.sh --line $line 合併 Release PR → 各單元正式 tag → finalize-release.sh --line $line --phase merge-back"
else
  info "下一步：scripts/release/merge-release-pr.sh --line $line 合併 Release PR → 各單元依自己的階段打 -<階段>.N tag → 部署到政策檔 targets 的去處。"
  info "hotfix：hotfix/<issue>-<kebab> 從 $branch 切、PR 合回 ${branch}（Refs #N），每次合入再開一次 Release PR。"
  info "推進：advance-release.sh --line $line [--to <階段>]；產品版號 ${plan} 由 plan 的 trailer 帶到 GA"
fi
