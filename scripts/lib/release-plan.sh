#!/usr/bin/env bash
# Release Plans: one releases/release-plan-vX.Y.Z.md per product version in the primary repository
# (docs/release-policy.md). The plan is the only place a product version comes from, and the scripts only
# read files for it, never GitHub. Sourced by common.sh; do not execute.
#
# The primary repository is the product repository itself, or <product>-hub for a product that spans
# several repositories. A member repository reads the plans from a local clone of the hub: the releaser
# runs the scripts on their own machine, and the member's CI never reads the hub or holds a credential for
# it (docs/multi-repo.md).
#
#   HUB_DIR  local clone of the primary repository, for a member repository. Default: the directory next
#            to this repository named after the primary repository.
#
# A plan says what kind it is on a line of its own, "- 類型：maintenance" or "- 類型：milestone". A plan
# without that line counts as a milestone.

# ver_key <X.Y.Z> → a number that orders versions
ver_key() {
  local IFS=.
  local -a v
  read -r -a v <<<"$1"
  printf '%s\n' $(( v[0] * 1000000 + v[1] * 1000 + v[2] ))
}

# plan_dir → the releases/ directory the plans live in
plan_dir() {
  local primary d
  policy_require
  primary="$(jq -r '.product.primary // empty' "$(policy_file)")"
  if [[ -z "$primary" ]]; then printf '%s\n' "$REPO_ROOT/releases"; return 0; fi
  d="${HUB_DIR:-$(dirname "$REPO_ROOT")/${primary#*/}}"
  [[ -d "$d" ]] || die "找不到 hub（${primary}）的本機 clone：${d}。先 clone 它，或用 --hub-dir 指定路徑"
  printf '%s\n' "$d/releases"
}

# plan_versions <dir> → the versions of the plans in <dir>, oldest first, one per line
plan_versions() {
  local f
  for f in "$1"/release-plan-v*.md; do
    [[ -e "$f" ]] || continue
    [[ "${f##*/}" =~ ^release-plan-v([0-9]+\.[0-9]+\.[0-9]+)\.md$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
  done | sort -t. -k1,1n -k2,2n -k3,3n
  return 0
}

# plan_kind <file> → maintenance | milestone
plan_kind() {
  local k
  k="$(sed -nE 's/^- 類型：(maintenance|milestone).*/\1/p' "$1" | head -1)"
  printf '%s\n' "${k:-milestone}"
}

# plan_check <file> → fails unless the plan is the next one after the latest other plan beside it:
#   - the next patch, only for a plan that plan.sh maintenance wrote
#   - the next minor or the next major, only for a milestone plan
plan_check() {
  local f="$1" name ver v prev="" newer="" kind
  local -a cur prv
  [[ -f "$f" ]] || die "找不到 Release Plan：$f"
  name="${f##*/}"
  [[ "$name" =~ ^release-plan-v([0-9]+\.[0-9]+\.[0-9]+)\.md$ ]] || die "Release Plan 檔名需為 release-plan-vX.Y.Z.md：$name"
  ver="${BASH_REMATCH[1]}"
  while IFS= read -r v; do
    [[ "$v" == "$ver" ]] && continue
    if (( $(ver_key "$v") > $(ver_key "$ver") )); then newer="$v"; else prev="$v"; fi
  done < <(plan_versions "$(dirname "$f")")
  [[ -z "$newer" ]] || die "v${ver} 不是最新的 plan：已有 v${newer}，新的 plan 要接在最新一份後面"
  if [[ -z "$prev" ]]; then info "✓ v${ver} 是第一份 plan"; return 0; fi
  IFS=. read -r -a cur <<<"$ver"; IFS=. read -r -a prv <<<"$prev"
  kind="$(plan_kind "$f")"
  if (( cur[0] == prv[0] && cur[1] == prv[1] && cur[2] == prv[2] + 1 )); then
    [[ "$kind" == maintenance ]] \
      || die "v${ver} 是 v${prev} 的下一個 patch，只接受 plan.sh maintenance 寫的 plan（檔內要有「- 類型：maintenance」）。里程碑要寫 v${prv[0]}.$(( prv[1] + 1 )).0 或 v$(( prv[0] + 1 )).0.0"
    info "✓ v${ver} 是 v${prev} 的下一個 patch（維護型）"
  elif (( cur[2] == 0 )) && { (( cur[0] == prv[0] && cur[1] == prv[1] + 1 )) || (( cur[0] == prv[0] + 1 && cur[1] == 0 )); }; then
    [[ "$kind" == milestone ]] || die "v${ver} 是里程碑版號，但 plan 的類型是 ${kind}。維護型只寫 patch"
    info "✓ v${ver} 是 v${prev} 的下一個 $( (( cur[0] == prv[0] )) && printf minor || printf major )（里程碑）"
  else
    die "v${ver} 不是 v${prev} 的下一號。上一份是 v${prev}，下一份只能是 v${prv[0]}.${prv[1]}.$(( prv[2] + 1 ))（維護型）、v${prv[0]}.$(( prv[1] + 1 )).0 或 v$(( prv[0] + 1 )).0.0（里程碑）"
  fi
}

# plan_write_maintenance → writes the compact plan of the next patch after the latest plan and prints its path
plan_write_maintenance() {
  local dir latest next f
  local -a v
  dir="$(plan_dir)"
  latest="$(plan_versions "$dir" | tail -1)"
  [[ -n "$latest" ]] || die "${dir} 沒有任何 plan，先寫第一份里程碑 plan"
  IFS=. read -r -a v <<<"$latest"
  next="${v[0]}.${v[1]}.$(( v[2] + 1 ))"
  f="$dir/release-plan-v${next}.md"
  [[ ! -e "$f" ]] || die "${f} 已存在"
  cat > "$f" <<PLAN
# Release Plan v${next}（維護型）

- 類型：maintenance（由 plan.sh maintenance 寫出）
- 狀態：draft
- 產品版號：\`v${next}\`（本 plan 是版號的唯一指派點）
- 上一份：\`v${latest}\`
- 入版單元：（發布前填入）

## Snapshot 對照（GA 當下由 \`pnpm snapshot --check-tags\` 產出後貼入）

| 單元 | 路徑 | 實作版號 | tag |
| :--- | :--- | :--- | :--- |
| product | package.json | ${next} | v${next} |

## Rollback

- 可回退：以 \`deploy-production.yml\` 的 \`workflow_dispatch\` 對舊產品 tag \`v${latest}\` 重跑。
- 不可回退：已推送的 tag 與已送審的行動端版本；補救走下一個維護型發布。
PLAN
  printf '%s\n' "$f"
}

# train_plan_version <line> → the product version (vX.Y.Z) the train of <line> was opened for. cut-release.sh
# writes it as a Release-Plan trailer on the commit that opens the train, and merge-back copies it to main,
# so it is still readable after the train branch is gone.
train_plan_version() {
  local line="$1" ref v
  for ref in "refs/heads/release/v$line" "refs/remotes/origin/release/v$line" refs/remotes/origin/main; do
    git rev-parse -q --verify "$ref^{commit}" >/dev/null || continue
    v="$(git log "$ref" -n 300 --format='%(trailers:key=Release-Plan,valueonly)' | grep -m1 -E "^v${line//./\\.}\\.[0-9]+\$" || true)"
    [[ -z "$v" ]] || { printf '%s\n' "$v"; return 0; }
  done
  return 1
}
