#!/usr/bin/env bash
# Dispatch publish.yml for the packages a release created, one dispatch per stage of the versions.
# release-please.yml calls it after each release. The units of one release line may stand at different
# stages (docs/versioning.md): a unit that only walks ga is at its final version while the line is in
# alpha. publish-units.sh stops when a version does not belong to the stage it is given, so the units are
# grouped by the stage of their own version in .release-please-manifest.json and each group is dispatched
# with that stage.
#
# usage: dispatch-publish.sh
#   env: PATHS         JSON array of the paths release-please released (paths_released)
#        GH_TOKEN      a token that can dispatch workflows
#        GITHUB_REF_NAME  the branch publish.yml runs on
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
cd "$REPO_ROOT"
paths="${PATHS:?PATHS is required (JSON array of released paths)}"
ref="${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"
pkgs="$(jq -c '[.[] | select(startswith("packages/") or startswith("libs/") or . == "facts" or . == "docs")]' <<<"$paths")"
if [[ "$pkgs" == "[]" ]]; then echo "no packages in this release"; exit 0; fi
pairs=""
while IFS= read -r p; do
  ver="$(jq -r --arg p "$p" '.[$p] // empty' .release-please-manifest.json)"
  [[ -n "$ver" ]] || die "$p 不在 .release-please-manifest.json，無法決定發布階段"
  stage="$(version_stage "$ver")" || die "$p 的版號 $ver 不是 X.Y.Z 或 X.Y.Z-<alpha|beta|rc>.N，無法決定發布階段"
  pairs+="$stage $p"$'\n'
done < <(jq -r '.[]' <<<"$pkgs")
for stage in "${RELEASE_STAGES[@]}"; do
  list="$(awk -v s="$stage" '$1 == s { print $2 }' <<<"$pairs" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  [[ "$list" != "[]" ]] || continue
  echo "dispatch publish.yml for $list at stage $stage"
  gh workflow run publish.yml --ref "$ref" -f paths="$list" -f stage="$stage"
done
