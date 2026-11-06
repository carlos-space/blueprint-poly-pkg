#!/usr/bin/env bash
# Validates release-policy.json against schemas/release-policy.schema.json (draft-07, validated by ajv 8 from the
# root devDependencies through validate-json-schema.mjs), so a policy file that the schema rejects fails here and not later in a release script.
# The cross-field checks against release-please-config.json are check-release-policy.sh.
#
# usage: check-release-policy-schema.sh [--policy <file>] | --samples
#   --policy <file>  validate that file (default: release-policy.json at the repository root)
#   --samples        self-test of the schema: every file in tests/fixtures/release-policy/invalid must be
#                    rejected, every one in valid/ accepted, and a policy file written by the e2e fixture()
#                    accepted. Prints the ajv output of each.
# Exit status: 0 all as expected, 1 not.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT"
schema=schemas/release-policy.schema.json
mode=policy policy="${RELEASE_POLICY:-release-policy.json}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy) policy="$2"; shift 2 ;;
    --samples) mode=samples; shift ;;
    -h|--help) sed -n '2,${/^#/!q; p;}' "$0"; exit 0 ;;
    *) printf '%s\n' "✗ unknown argument: $1" >&2; exit 2 ;;
  esac
done

validator="$(dirname "${BASH_SOURCE[0]}")/validate-json-schema.mjs"
validate() { node "$validator" "$schema" "$1" 2>&1; }

if [[ "$mode" == policy ]]; then
  [[ -f "$policy" ]] || { printf '%s\n' "✗ 找不到政策檔 $policy" >&2; exit 1; }
  validate "$policy" && exit 0
  printf '%s\n' "✗ $policy 不符合 $schema" >&2; exit 1
fi

fail=0
for f in tests/fixtures/release-policy/invalid/*.json; do
  printf '%s\n' "--- $f (expect: rejected)"
  if out="$(validate "$f")"; then printf '%s\n' "$out" "✗ 應被擋下卻通過"; fail=1; else printf '%s\n' "$out"; fi
done
for f in tests/fixtures/release-policy/valid/*.json; do
  printf '%s\n' "--- $f (expect: accepted)"
  if out="$(validate "$f")"; then printf '%s\n' "$out"; else printf '%s\n' "$out" "✗ 應通過卻被擋下"; fail=1; fi
done
mkdir -p "$REPO_ROOT/tmp"; tmp="$(mktemp -d "$REPO_ROOT/tmp/policy-schema.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
node --input-type=module -e '
import { fixture, cleanup } from "./tests/e2e/helpers/repo.mjs";
import { copyFileSync } from "node:fs";
import { join } from "node:path";
const r = fixture({ units: { web: { path: "apps/product-web" } }, policy: { product: { name: "t", members: [] }, units: { web: { kind: "web", stages: ["ga"] } } } });
copyFileSync(join(r.dir, "release-policy.json"), process.argv[1]);
cleanup();
' "$tmp/fixture-policy.json" 2>/dev/null || true
if [[ -f "$tmp/fixture-policy.json" ]]; then
  printf '%s\n' "--- fixture() output (expect: accepted)"
  if out="$(validate "$tmp/fixture-policy.json")"; then printf '%s\n' "$out"; else printf '%s\n' "$out" "✗ fixture() 寫出的政策檔被擋下"; fail=1; fi
else
  printf '%s\n' "✗ 無法由 fixture() 產生政策檔"; fail=1
fi
exit "$fail"
