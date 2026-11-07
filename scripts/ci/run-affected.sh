#!/usr/bin/env bash
# Run a workspace script over the affected set (AFFECTED_SINCE set) or the whole tree (unset).
#
# Affected = packages changed since AFFECTED_SINCE plus everything depending on them (pnpm's
# "...[<ref>]"). That set is right for tests but not for builds: a changed package still needs its
# UPSTREAM packages' dist/*.d.ts to compile (observed 2026-09-09: shared-utils failed with TS2307 on
# product-shared-types, which was unchanged and therefore unbuilt). WITH_DEPS=1 widens the build to
# the dependency closure by adding "<name>..." for every affected package.
#
# Filters are passed as argv, never through eval: an eval re-parse strips the quotes and lets the
# shell expand "**/*.md" into file names, which pnpm then took for the script name and ran nothing
# while exiting 0 (observed 2026-09-09 on the first probe PRs).
#
# usage: AFFECTED_SINCE=origin/main [WITH_DEPS=1] scripts/ci/run-affected.sh build
#        scripts/ci/run-affected.sh test            # full tree
set -euo pipefail
(( $# )) || { printf '%s\n' "usage: run-affected.sh <script> [pnpm flags]" >&2; exit 2; }
ignore="${CHANGED_IGNORE:-**/*.md}"
declare -a args=(-r)
if [[ -z "${AFFECTED_SINCE:-}" ]]; then
  printf '%s\n' "[affected] 全量"
else
  # The workspace root is dropped in both modes: its build and test scripts are `pnpm -r <script>`,
  # so selecting it re-runs the script over the whole tree. A change confined to root files (scripts/,
  # docs/) selected only the root, and `test` then ran every package against dist/ that the build
  # step had rightly skipped (observed 2026-09-25 on PR #511: libs/product-shared-types "Could not find 'dist/'").
  root_name="$(jq -r '.name' package.json)"
  # A failed listing must stop the job, not read as "nothing affected" and skip it.
  listing="$(pnpm ls -r --depth -1 --json --filter "...[${AFFECTED_SINCE}]" --changed-files-ignore-pattern "$ignore")" \
    || { printf '%s\n' "[affected] 無法列出 ${AFFECTED_SINCE} 以來的受影響套件" >&2; exit 1; }
  declare -a names=()
  while IFS= read -r n; do
    [[ -n "$n" && "$n" != "$root_name" ]] && names+=("$n")
  done < <(jq -r '.[].name' <<<"$listing")
  if (( ${#names[@]} == 0 )); then printf '%s\n' "[affected] since ${AFFECTED_SINCE}：無受影響套件，略過 $1"; exit 0; fi
  joined="$(IFS=,; printf '%s' "${names[*]}")"; joined="${joined//,/, }"
  if [[ "${WITH_DEPS:-0}" == 1 ]]; then
    for n in "${names[@]}"; do args+=(--filter "${n}..."); done
    printf '%s\n' "[affected] since ${AFFECTED_SINCE}：${#names[@]} 個受影響套件及其上游閉包（${joined}）"
  else
    for n in "${names[@]}"; do args+=(--filter "$n"); done
    printf '%s\n' "[affected] since ${AFFECTED_SINCE}：${#names[@]} 個變更套件及其下游（${joined}）"
  fi
fi
exec pnpm "${args[@]}" "$@"
