#!/usr/bin/env bash
# `describes` of every entry of every built component package must equal the version in
# .release-please-manifest.json of the same checkout: {"<component>": "<manifest version>"}, or {} when the
# manifest has no such unit. This catches a component package whose index.ts writes a literal version instead of describesOf(), which lets
# `describes` fall behind the version actually released.
#
# A component package is a package the aggregate (facts/fact-kit.config.json) lists; its component is the
# directory name under facts/. A package may have several entries, one dist/<entry>/index.json each, and the
# entry name need not equal the component; every entry is compared. A package with no dist/*/index.json at
# all fails. Builds the packages first.
#
# usage: check-facts-describes.sh
# Exit status: 0 every component matches, 1 at least one entry differs (component, entry, describes and manifest are printed).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
cd "$REPO_ROOT"
has_facts || { info "⊘ 沒有 facts/，略過 describes 比對"; exit 0; }


facts_components >/dev/null   # builds the packages the aggregate lists

failed=0 count=0
while IFS= read -r pkg; do
  dir="$(facts_package_dir "$pkg")" || die "facts/fact-kit.config.json 的 aggregate 列了 ${pkg}，但 facts/ 底下找不到這個套件"
  comp="${dir##*/}"
  version=""
  while IFS= read -r p; do
    [[ "$(unit_component "$p")" == "$comp" ]] && { version="$(manifest_version "$p")"; break; }
  done < <(jq -r 'keys[]' "$MANIFEST")
  if [[ -n "$version" ]]; then expected="$(jq -cnS --arg c "$comp" --arg v "$version" '{($c): $v}')"; else expected="{}"; fi
  entries=0
  for idx in "$dir"/dist/*/index.json; do
    [[ -f "$idx" ]] || continue
    entry="${idx%/index.json}"; entry="${entry##*/}"
    entries=$((entries + 1))
    actual="$(jq -cS '.describes // {}' "$idx")"
    count=$((count + 1))
    if [[ "$actual" != "$expected" ]]; then
      failed=$((failed + 1))
      warn "describes 與 manifest 不符：component=$comp entry=$entry describes=$actual manifest=${expected}（${MANIFEST}）"
    fi
  done
  (( entries > 0 )) || die "找不到 ${dir#"$REPO_ROOT"/}/dist/*/index.json（建置沒有產出任何 index.json）"
done < <(jq -r '.aggregate // {} | to_entries[] | .value' "$REPO_ROOT/facts/fact-kit.config.json")

(( failed == 0 )) || die "$failed / $count 個 entry 的 describes 和 manifest 不符：index.ts 要用 describesOf('<component>')，不寫字面版號"
info "全部 $count 個 entry 的 describes 等於 manifest"
