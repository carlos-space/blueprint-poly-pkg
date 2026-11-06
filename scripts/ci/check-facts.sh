#!/usr/bin/env bash
# fact-kit check on every facts package, one after the other: the aggregate at facts/, the spec and one
# component package per release-please unit. A component package's fact-kit.config.json lists the unit's
# directory in implDirs, so an implementation that imports the aggregate fails with impl-imports-facts.
# Builds the packages first, because some rules read the built indexes.
#
# usage: check-facts.sh
#   env: FACT_KIT_TRAIN  e.g. "--train product-web=1.2.0-alpha.1 --train facts=0.1.0-alpha.1": passed to every
#                        `fact-kit check`, so rows pinned to the version of an open Release PR are not ahead
#                        of describes. scripts/ci/release-train.sh prints it. Unset: no --train.
# Exit status: 0 every package passes, 1 at least one fails (the problems and their <file>:<line> are printed).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
cd "$REPO_ROOT"
has_facts || { info "⊘ 沒有 facts/，略過 fact-kit check"; exit 0; }

facts_components >/dev/null   # builds the packages the aggregate lists

train=()
# shellcheck disable=SC2206
[[ -z "${FACT_KIT_TRAIN:-}" ]] || train=(${FACT_KIT_TRAIN})

failed=0 count=0
for pkg in "$REPO_ROOT/facts" "$REPO_ROOT"/facts/*/; do
  pkg="${pkg%/}"
  [[ -f "$pkg/package.json" ]] || continue
  count=$((count + 1))
  if out="$(fact_kit check --cwd "$pkg" ${train[@]+"${train[@]}"} 2>&1)"; then
    info "✓ fact-kit check ${pkg#"$REPO_ROOT"/}${train[*]:+（${train[*]}）}"
  else
    printf '%s\n' "$out" >&2
    facts_locate_problems "$pkg" "$out"
    warn "fact-kit check 失敗：${pkg#"$REPO_ROOT"/}"
    failed=$((failed + 1))
  fi
done
(( failed == 0 )) || die "$failed / $count 個 facts 套件的 fact-kit check 失敗"
info "全部 $count 個 facts 套件通過"
