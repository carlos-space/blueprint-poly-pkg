#!/usr/bin/env bash
# Check that the units production declares are the versions the Release Plan names. The check reads what is declared after the
# release, so it is not a dependency of the unit that holds the declaration (decision infra-ops-version-unit).
#
# The Release Plan lists the version of every unit in a table with the columns 單元 and 實作版號 (the table that is pasted at GA,
# or the output of snapshot.sh and snapshot-members.sh, which have the same columns). For each unit that ops/versions.json declares
# under "production", the version there has to be the version in the table. The units the table lists and production does not
# declare (packages, libraries, facts) are not deployed and are not checked. The check fails, and says which unit, when
#   - a declared unit has another version in the table, or
#   - a declared unit has no row in the table.
# It does not know which repository holds the plan or the declaration, so the monorepo (both in one repository) and a poly product
# (the plan in the hub, the declaration in the ops repository) call it the same way.
#
# usage: verify-production.sh --plan <release-plan file> --ops <directory that has ops/versions.json>
# exit:  0 every declared unit matches, 1 a unit does not match, 2 an input is missing
set -euo pipefail
plan="" ops=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) plan="${2:?--plan needs a file}"; shift 2 ;;
    --ops) ops="${2:?--ops needs a directory}"; shift 2 ;;
    *) printf '%s\n' >&2 "unknown argument: $1"; exit 2 ;;
  esac
done
[[ -n "$plan" && -n "$ops" ]] || { printf '%s\n' >&2 "usage: verify-production.sh --plan <release-plan file> --ops <directory that has ops/versions.json>"; exit 2; }
[[ -f "$plan" ]] || { printf '%s\n' >&2 "找不到 Release Plan：$plan"; exit 2; }
decl="$ops/ops/versions.json"
[[ -f "$decl" ]] || { printf '%s\n' >&2 "找不到 ops 宣告：$decl"; exit 2; }

# "<unit> <version>" for each row of the unit table of the plan
planned="$(awk -F'|' '
  function trim(s) { gsub(/^[ \t`]+|[ \t`]+$/, "", s); return s }
  /^\|/ {
    if (!u) {
      for (i = 1; i <= NF; i++) { t = trim($i); if (t == "單元") uc = i; if (t == "實作版號") vc = i }
      if (uc && vc) { u = uc; v = vc }
      next
    }
    if ($0 ~ /^\|[ :|-]+$/) next
    unit = trim($u); ver = trim($v)
    if (unit != "" && unit != "product" && ver ~ /^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$/) print unit, ver
    next
  }
  { u = 0; uc = 0; vc = 0 }
' "$plan")"
[[ -n "$planned" ]] || { printf '%s\n' >&2 "$plan 沒有單元版號表（欄位 單元 與 實作版號）：GA 時貼入 snapshot 的輸出，或先產生 snapshot"; exit 2; }

declared="$(jq -r '(.production // {}) | to_entries[] | "\(.key) \(.value.version)"' "$decl")"
if [[ -z "$declared" ]]; then printf '%s\n' "ops production 沒有宣告任何單元，沒有可核對的"; exit 0; fi

fail=0
while read -r unit version; do
  [[ -n "$unit" ]] || continue
  want="$(awk -v u="$unit" '$1 == u { print $2; exit }' <<<"$planned")"
  if [[ -z "$want" ]]; then
    printf '%s\n' "  ✗ ${unit}：ops production 宣告 ${version}，Release Plan 的單元版號表沒有這個單元"; fail=1
  elif [[ "$want" != "$version" ]]; then
    printf '%s\n' "  ✗ ${unit}：Release Plan 是 ${want}，ops production 宣告 ${version}"; fail=1
  else
    printf '%s\n' "  ✓ ${unit} ${version}：ops production 與 Release Plan 一致"
  fi
done <<<"$declared"
if (( fail )); then printf '%s\n' "核對失敗：ops production 的版本和 Release Plan 不一致"; exit 1; fi
