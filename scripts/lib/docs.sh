#!/usr/bin/env bash
# Document package steps of the release scripts: pinning the `next` of the *.doc.ts under docs/ to a version.
# Source it through common.sh; do not execute. A repository without a docs/ directory has none of this and
# every function here is a no-op.
#
# Two layers, told apart by path and not by a field of the document index:
#   docs/product/       product layer: pinned to the product version when cut-release.sh opens the train
#                       (--plan vX.Y.Z → X.Y.Z)
#   docs/<unit>/        component layer, <unit> the release-please component name: pinned to that unit's
#                       version when merge-release-pr.sh merges the Release PR that releases it
# Anything else under docs/ is not pinned by the scripts.
#
# The pin is `clarify-kit pin --version`, as the facts are pinned by `fact-kit pin --version`: the tool knows
# which field of which document type holds a version (`since`, the `appliesFrom` of a decision, the `release`
# of a requirement) and leaves what carries `pending`.

DOCS_PRODUCT_DIR="docs/product"

has_docs() { [[ -d "$REPO_ROOT/docs" ]]; }

# clarify-kit comes from the docs workspace package. pnpm -C changes the working directory, so every path
# passed to it is absolute.
clarify_kit() { pnpm -C "$REPO_ROOT/docs" exec clarify-kit "$@"; }

# docs_pin_dir <dir under the repository root> <version> → pins that directory, prints what changed.
# clarify-kit pins the docsDir of a config, so a config naming only this directory is written outside the
# working tree for the call; the docs package's own config may name a wider docsDir.
docs_pin_dir() {
  [[ -d "$REPO_ROOT/$1" ]] || return 0
  local tmp status=0
  tmp="$(mktemp -d)"
  jq -n --arg d "$REPO_ROOT/$1" '{docsDir: $d}' > "$tmp/clarify-kit.config.json"
  clarify_kit pin --version "$2" --config "$tmp/clarify-kit.config.json" || status=$?
  rm -rf "$tmp"
  (( status == 0 )) || die "clarify-kit pin 失敗：$1 → $2"
}

# docs_pin_product <version>: the product layer
docs_pin_product() {
  has_docs || return 0
  info "pin ${DOCS_PRODUCT_DIR} → ${1}"
  docs_pin_dir "$DOCS_PRODUCT_DIR" "$1"
}

# docs_pin_unit <unit> <version>: the component layer of one unit
docs_pin_unit() {
  has_docs || return 0
  [[ -d "$REPO_ROOT/docs/$1" ]] || return 0
  info "pin docs/$1 → ${2}"
  docs_pin_dir "docs/$1" "$2"
}
