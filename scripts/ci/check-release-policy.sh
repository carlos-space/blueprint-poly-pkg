#!/usr/bin/env bash
# Daily consistency check of the policy file against the repository (docs/release-policy.md). Schema
# validation is a separate check; this one covers what a schema cannot see:
#   - units: the policy's units are exactly the components of release-please-config.json. A unit missing
#     from the policy has no recorded cadence, and one missing from the config can never release.
#     A release branch is the exception on the config side: cut-release.sh shrinks the config to the train's
#     units, so the policy may list units the config no longer has. The config says so itself: every unit
#     cut-release.sh keeps gets its own "versioning", which main's config never carries. The manifest
#     cannot stand in for the full list, because it maps paths and the component of a unit that left the
#     config can no longer be told. A unit in the config but not in the policy is wrong on every branch.
#   - a unit that deploys (service, backend, web) finds a target for each stage it walks, in its own
#     targets or the repository targets
#   - a unit that deploys walks at least one pre-release stage when its own targets or the repository
#     targets have one. Only after deploying does it show how it works with the other services, and a
#     GA-only unit goes to production as soon as the train enters its first stage
#   - a unit that ships to store channels (mobile, desktop) names a channel for each stage it walks
#   - every dependsOn names a unit the policy lists
# A <product>-hub has no units and no release-please-config.json, so there is nothing to compare and it passes.
#
# usage: check-release-policy.sh [--policy <file>] [--config <file>]
#   defaults: release-policy.json and release-please-config.json at the repository root
# Exit status: 0 consistent, 1 not.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
policy="${RELEASE_POLICY:-$REPO_ROOT/release-policy.json}" config="$REPO_ROOT/release-please-config.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy) policy="$2"; shift 2 ;;
    --config) config="$2"; shift 2 ;;
    -h|--help) sed -n '2,${/^#/!q; p;}' "$0"; exit 0 ;;
    *) printf '%s\n' "✗ unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -f "$policy" ]] || { printf '%s\n' "✗ 找不到政策檔 $policy" >&2; exit 1; }
jq -e 'type == "object"' "$policy" >/dev/null 2>&1 || { printf '%s\n' "✗ $policy 不是 JSON 物件" >&2; exit 1; }

problems=()
if ! jq -e 'has("units")' "$policy" >/dev/null; then
  if jq -e '(.product.members // []) | length > 0' "$policy" >/dev/null && [[ ! -f "$config" ]]; then
    printf '%s\n' "✓ $policy 是 hub，沒有單元可核對"; exit 0
  fi
fi

# 1. unit list
if [[ -f "$config" ]]; then
  in_config="$(jq -r '.packages | to_entries[] | (.value.component // (.key | split("/")[1]))' "$config" | sort -u)"
else
  in_config=""; problems+=("找不到 ${config}，政策檔列出的單元沒有對應的 release-please 單元")
fi
in_policy="$(jq -r '(.units // {}) | keys[]' "$policy" | sort -u)"
missing="$(comm -13 <(printf '%s\n' "$in_policy") <(printf '%s\n' "$in_config") | sed '/^$/d' | paste -sd ' ' -)"
extra="$(comm -23 <(printf '%s\n' "$in_policy") <(printf '%s\n' "$in_config") | sed '/^$/d' | paste -sd ' ' -)"
[[ -z "$missing" ]] || problems+=("政策檔的 units 缺少 release-please-config.json 的單元：$missing")
scoped=0
if [[ -f "$config" ]] && jq -e '[.packages[]? | has("versioning")] | any' "$config" >/dev/null; then scoped=1; fi
if [[ -n "$extra" ]] && (( ! scoped )); then
  problems+=("政策檔的 units 列了 release-please-config.json 沒有的單元：$extra")
fi

# 2. cross-field: where each stage of each unit goes, and what dependsOn points at
while IFS= read -r line; do [[ -n "$line" ]] && problems+=("$line"); done < <(jq -r '
  . as $p
  | (.units // {}) | to_entries[] | .key as $u | .value as $v
  | (
      ($v.stages // [])[] as $s
      | if ($v.kind | IN("service", "backend", "web")) then
          select((($v.targets // {})[$s] // ($p.targets // {})[$s]) == null)
          | "\($u)（\($v.kind)）的階段 \($s) 找不到去處：units.\($u).targets 與 targets 都沒有 \($s)"
        elif ($v.kind | IN("mobile", "desktop")) then
          select((($v.targets // {})[$s]) == null)
          | "\($u)（\($v.kind)）的 targets 缺階段 \($s) 的通道"
        else empty end
    ),
    (
      select($v.kind | IN("service", "backend", "web"))
      | ([($v.targets // {}), ($p.targets // {})] | map(keys[]) | map(select(IN("alpha", "beta", "rc"))) | unique) as $pre
      | select(($pre | length) > 0 and ([($v.stages // [])[] | select(. != "ga")] | length) == 0)
      | "\($u)（\($v.kind)）只發 GA，但 targets 有預發布階段 \($pre | join("、"))：部署型單元要至少走一個預發布階段"
    ),
    (
      ($v.dependsOn // [])[] as $d
      | select(($p.units | has($d)) | not)
      | "\($u) 的 dependsOn 指到不存在的單元：\($d)"
    )
' "$policy")

if (( ${#problems[@]} )); then
  printf '%s\n' "✗ 政策檔與倉庫不一致（${policy}）：" >&2
  for p in "${problems[@]}"; do printf '%s\n' "  - $p" >&2; done
  exit 1
fi
if (( scoped )); then
  printf '%s\n' "✓ 發布分支的設定已縮成本班單元，政策檔另列的單元不算錯；設定裡的單元都在政策檔，階段去處與 dependsOn 核對通過"
else
  printf '%s\n' "✓ 政策檔與 release-please 單元一致：$(wc -l <<<"$in_policy" | tr -d ' ') 個單元，階段去處與 dependsOn 核對通過"
fi
