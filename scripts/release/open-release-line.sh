#!/usr/bin/env bash
# Open a release train from a Release Plan that arrived as a workflow input. open-release-line.yml runs this
# in a member repository when the hub dispatches it: the hub passes the product version, the content of the
# plan and this repository's units, so the member reads nothing from the hub and holds no credential for it.
#
# usage: open-release-line.sh
#   env: PLAN          the product version, vX.Y.Z
#        PLAN_CONTENT  the content of releases/release-plan-vX.Y.Z.md of the hub
#        UNITS         comma list of this repository's units in the plan
#        FROM          optional, main (default) or the latest product tag of the line, passed to cut-release.sh --from.
#                      A line that already shipped takes patches only and has to be cut from its latest product tag.
# It writes the content to release-plan-<PLAN>.md in a temporary directory and calls
# cut-release.sh --plan <PLAN> --plan-file <that file> --units <UNITS> --from <FROM> --yes.
set -euo pipefail
plan="${PLAN:?PLAN is required (vX.Y.Z)}"
units="${UNITS:?UNITS is required (comma list of units)}"
content="${PLAN_CONTENT:?PLAN_CONTENT is required (the content of the Release Plan)}"
[[ "$plan" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf '%s\n' >&2 "✗ PLAN 需為 vX.Y.Z：$plan"; exit 1; }
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
printf '%s\n' "$content" > "$dir/release-plan-$plan.md"
bash "$(dirname "$0")/cut-release.sh" --plan "$plan" --plan-file "$dir/release-plan-$plan.md" --units "$units" --from "${FROM:-main}" --yes
