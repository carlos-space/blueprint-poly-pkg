#!/usr/bin/env bash
# The versions the open Release PR of a release branch is about to release, as a line for $GITHUB_ENV:
#   FACT_KIT_TRAIN=--train <component>=<version> --train <component>=<version> ...
# On a release branch the facts are pinned to those versions before the Release PR merges, while `describes`
# still reads the old version from .release-please-manifest.json. `fact-kit check --train` lets since be as new as
# the train. Prints nothing when the branch has no Release PR.
#
# The set is release_pr_units (scripts/lib/release-pr.sh): the units whose manifest version on the Release PR's
# head differs from the release branch's, with the PR's version. Only units that have a component package in
# facts/ are kept (facts_components), because the others have no package for --train to check.
#
# usage: release-train.sh
#   env: BRANCH  the release branch, e.g. release/v1.2 (for a pull request, its base branch)
#   git must be able to fetch origin. The checkout keeps no token, so the CI step passes the read-only token to
#   git through GIT_CONFIG_* in its own environment (.github/workflows/ci.yml, job facts).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
cd "$REPO_ROOT"
branch="${BRANCH:?BRANCH is not set}"

git fetch -q origin "+refs/heads/${branch}:refs/remotes/origin/${branch}"
if ! units="$(release_pr_units "$branch")" || [[ -z "$units" ]]; then
  warn "release-train: $branch 沒有開著的 Release PR（或它沒有單元的版號變動），不帶 --train"
  exit 0
fi

comps="$(facts_components | cut -f2)"
line=""
while read -r unit version; do
  [[ -n "$unit" ]] || continue
  if grep -qxF "$unit" <<<"$comps"; then
    line+="${line:+ }--train ${unit}=${version}"
  else
    warn "release-train: $unit 沒有 component 套件，不帶 --train"
  fi
done <<<"$units"
[[ -n "$line" ]] || exit 0
warn "release-train: $line"
printf 'FACT_KIT_TRAIN=%s\n' "$line"
