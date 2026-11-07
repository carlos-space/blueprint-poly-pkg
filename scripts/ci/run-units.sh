#!/usr/bin/env bash
# Build or test the units that are not pnpm packages (Python, Rust, Go), from the rows of scripts/ci/units.json that
# composing the repository wrote. The commands are the ones of the unit's stack, the same ones blueprint's demos.yml
# runs. Swift units go through the native job, pnpm units through run-affected.sh.
#
# Like run-affected.sh, a pull request runs only the units whose directory changed since AFFECTED_SINCE (the base
# branch), and without AFFECTED_SINCE (a push to main or a train) every unit runs.
#
# usage: AFFECTED_SINCE=origin/main scripts/ci/run-units.sh build|test
#        scripts/ci/run-units.sh langs        # the languages of the units, comma-separated, for the toolchain steps
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
units="scripts/ci/units.json"
mode="${1:?usage: run-units.sh build|test|langs}"
[[ -f "$units" ]] || { [[ "$mode" == langs ]] || printf '%s\n' "[units] 沒有 ${units}，沒有其他語言的單元"; exit 0; }
case "$mode" in
  langs) jq -r '[.[].lang] | unique | join(",")' "$units"; exit 0 ;;
  build|test) ;;
  *) printf '%s\n' >&2 "usage: run-units.sh build|test|langs"; exit 2 ;;
esac
since=""
[[ -z "${AFFECTED_SINCE:-}" ]] || since="$(git merge-base "$AFFECTED_SINCE" HEAD)"
ran=0
while IFS=$'\t' read -r name dir cmd; do
  if [[ -n "$since" ]] && git diff --quiet "$since" HEAD -- "$dir"; then
    printf '%s\n' "[units] ${name}：${dir} 自 ${AFFECTED_SINCE} 沒有變更，略過 ${mode}"
    continue
  fi
  printf '%s\n' "[units] ${name}：${mode}"
  bash -c "$cmd"
  ran=$((ran + 1))
done < <(jq -r --arg mode "$mode" '.[] | [.unit, .dir, .[$mode]] | @tsv' "$units")
printf '%s\n' "[units] ${ran} 個單元執行了 ${mode}"
