#!/usr/bin/env bash
# Print the Release Plan "Snapshot 對照" table: the product marker plus every unit's implementation
# version, taken from the manifest (the single source of unit versions).
#
# usage: snapshot.sh [--product X.Y.Z] [--check-tags] [--since <ref>]
#   --check-tags  verify each unit's tag. A unit only *needs* a tag when it actually shipped in this
#                 release, i.e. its version differs from <ref>; everything else is marked 未入版.
#   --since       the previous product tag to compare against. Defaults to the newest vX.Y.Z tag
#                 older than the current checkout; with none, every unit counts as shipped.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
check=0 product="$(jq -r .version package.json)" since=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-tags) check=1; shift ;;
    --product) product="$2"; shift 2 ;;
    --since) since="$2"; shift 2 ;;
    *) printf '%s\n' >&2 "unknown argument: $1"; exit 2 ;;
  esac
done

if (( check )) && [[ -z "$since" ]]; then
  # 產品 tag 之間沒有祖先關係（發布分支以 squash 合回），--merged 一律查無；退回的 --no-merged 又會取到
  # 當前這一版本身，於是每個單元都被拿來跟自己比而全數判成「未入版」。改以版本序取當前版的前一版。
  since="$(git tag --list 'v[0-9]*' --sort=-v:refname | awk -v c="v$product" 'f{print;exit} $0==c{f=1}')"
fi
prev='{}'
if [[ -n "$since" ]] && git rev-parse -q --verify "$since^{commit}" >/dev/null; then
  prev="$(git show "$since:.release-please-manifest.json" 2>/dev/null || printf '%s\n' '{}')"
fi

printf '%s\n' "| 單元 | 路徑 | 實作版號 | tag |"
printf '%s\n' "| :--- | :--- | :--- | :--- |"
printf '%s\n' "| product | package.json | $product | v$product |"
jq -r 'to_entries[] | "\(.key) \(.value)"' .release-please-manifest.json | while read -r pkg_path ver; do
  # unit 名稱一律取設定的 component，設定沒有時才退回資料夾名稱（ADR-004 第 36 項）
  unit="$(jq -r --arg p "$pkg_path" '.packages[$p].component // empty' release-please-config.json)"
  [[ -z "$unit" ]] && unit="${pkg_path##*/}"
  tag="$unit/v$ver"
  tag_status="$tag"
  if (( check )); then
    prev_ver="$(printf '%s\n' "$prev" | jq -r --arg p "$pkg_path" '.[$p] // empty')"
    if [[ -n "$prev_ver" && "$prev_ver" == "$ver" ]]; then
      tag_status="未入版（同 ${since:-基準}）"
    elif git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
      tag_status="$tag ✓"
    elif [[ -z "$(git tag --list "$unit/v*" --no-contains "$tag" 2>/dev/null)" && -z "$(git tag --list "$unit/v*")" ]]; then
      tag_status="未發布"
    else
      # 該版號從未有對應 tag，但該單元有其他 tag：可能是它在本版之後才首次發布。
      # 以「是否存在比本版號更早的該單元 tag」區分：沒有更早的即代表本版時它尚未發布過。
      earlier="$(git tag --list "$unit/v*" | sed "s#^$unit/v##" | sort -V | awk -v v="$ver" '$0 < v' | head -1)"
      if [[ -z "$earlier" ]]; then tag_status="未發布"; else tag_status="$tag ✗ missing"; fi
    fi
  fi
  printf '%s\n' "| $unit | $pkg_path | $ver | $tag_status |"
done
