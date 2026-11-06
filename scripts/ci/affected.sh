#!/usr/bin/env bash
# Print the git ref that a pull request should be compared against, or nothing for a full run.
#
# On a pull request the base branch is the comparison point; run-affected.sh turns it into pnpm's
# "...[<ref>]" filter (packages changed since <ref> plus every package depending on one of them), so
# a change in libs/product-shared-utils still exercises web and api. Any other event (push to main or to a
# train) prints nothing and runs the full set: those are the points where release-please reads
# history, and the whole tree must be known good there.
#
# usage: since="$(scripts/ci/affected.sh)"   (env: GITHUB_EVENT_NAME, GITHUB_BASE_REF from Actions)
set -euo pipefail
if [[ "${GITHUB_EVENT_NAME:-}" != "pull_request" || -z "${GITHUB_BASE_REF:-}" ]]; then exit 0; fi
base="origin/${GITHUB_BASE_REF}"
git rev-parse -q --verify "$base" >/dev/null || { printf '%s\n' >&2 "affected: $base 不存在，改跑全量（checkout 需 fetch-depth: 0）"; exit 0; }
printf '%s\n' "$base"
