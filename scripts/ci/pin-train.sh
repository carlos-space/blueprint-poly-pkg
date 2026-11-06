#!/usr/bin/env bash
# Pin the "next" rows of the components named by FACT_KIT_TRAIN, in the working tree only. On a release branch
# the facts are pinned to the Release PR's versions by merge-release-pr.sh just before the PR merges, so until
# then the branch still says "next" and `fact-kit check` reports train-next for a component in the train. This
# does the same pin in the CI checkout so that check passes. It does not commit and does not push.
# A component that is not in FACT_KIT_TRAIN is left alone.
#
# usage: pin-train.sh
#   env: FACT_KIT_TRAIN  e.g. "--train product-web=1.2.0-alpha.1 --train facts=0.1.0-alpha.1", as
#                        scripts/ci/release-train.sh prints it. Unset or empty: nothing to pin, exit 0.
# Exit status: 0 pinned (or nothing to pin), 1 fact-kit pin failed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
cd "$REPO_ROOT"
[[ -n "${FACT_KIT_TRAIN:-}" ]] || { info "⊘ FACT_KIT_TRAIN 沒有設定，沒有要釘的版號"; exit 0; }
has_facts || { info "⊘ 沒有 facts/，略過釘版"; exit 0; }

# shellcheck disable=SC2206
words=(${FACT_KIT_TRAIN})
i=0
while (( i < ${#words[@]} )); do
  if [[ "${words[i]}" == --train && -n "${words[i+1]:-}" ]]; then
    pair="${words[i+1]}"
    facts_pin "${pair%%=*}" "${pair#*=}"
    i=$((i + 2))
  else
    die "FACT_KIT_TRAIN 格式不對：${words[i]}（要 --train <unit>=<version>）"
  fi
done
