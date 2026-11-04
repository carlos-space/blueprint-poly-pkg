#!/usr/bin/env bash
# Dispatch deploy-prerelease for every prerelease the train has released but never deployed.
#
# The dispatch normally happens in release-please.yml right after the release step. If that run
# fails after the release (and its tag) was created (observed 2026-09-09 as a transient GitHub
# GraphQL error) the dispatch step is skipped, and nothing retries: tags created with GITHUB_TOKEN
# raise no push event. This script is idempotent, so release-please.yml runs it after every run,
# including failed ones: it reads the manifest on the current branch, and for each app, service or infra unit with a
# prerelease version whose tag exists but has no deploy-prerelease run, dispatches one. A tag with nothing to
# deploy at its stage (no environment declared for the unit, scripts/deploy/route-tag.sh) is skipped, not
# dispatched. A repository without apps/, services/ or infra/ units has nothing to look at, so it never reaches route-tag.sh.
#
# usage: ensure-stage-deploys.sh   (env: GH_TOKEN)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# unit 名稱一律取設定的 component，設定沒有時才退回資料夾名稱（ADR-004 第 36 項）
jq -r --slurpfile cfg release-please-config.json '
  ($cfg[0].packages) as $pkgs
  | to_entries[]
  | select(.key | startswith("apps/") or startswith("services/") or startswith("infra/"))
  | select(.value | test("-"))
  | "\($pkgs[.key].component // (.key | split("/")[1])) \(.value)"
' .release-please-manifest.json | while read -r unit ver; do
  tag="$unit/v$ver"
  if ! git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then printf '%s\n' "  ⊘ $tag 尚未建立，略過"; continue; fi
  route="$(bash scripts/deploy/route-tag.sh "$tag")"
  if [[ "$(sed -n 's/^skip=//p' <<<"$route")" == true ]]; then
    printf '%s\n' "  ⊘ $tag 無需部署：$(sed -n 's/^reason=//p' <<<"$route")"; continue
  fi
  # a run dispatched with --ref <tag> carries the tag as its head branch
  n="$(gh run list --workflow deploy-prerelease.yml --branch "$tag" --limit 1 --json databaseId --jq 'length' 2>/dev/null || printf '%s\n' 0)"
  if [[ "$n" == 0 ]]; then
    printf '%s\n' "  → 補派送 deploy-prerelease（$(sed -n 's/^env=//p' <<<"$route")）：$tag"
    gh workflow run deploy-prerelease.yml --ref "$tag" -f tag="$tag"
  else
    printf '%s\n' "  ✓ $tag 已有 deploy-prerelease run"
  fi
done
