#!/usr/bin/env bash
# Publish the units a release created, at every stage of a train. publish.yml calls it with the unit paths of the
# release and the stage; release-please.yml dispatches publish.yml after each release.
#
# The target of a unit follows from the file its directory carries:
#   package.json    npm              publishConfig.registry unset or https://registry.npmjs.org. Public package,
#                                    Trusted Publishing (OIDC, npm >= 11.5.1), no token is read. dist-tag is the stage
#                                    (alpha | beta | rc), latest at ga: latest must only ever point at a GA. pnpm packs
#                                    (it rewrites workspace: ranges) and the npm CLI publishes the tarball.
#   package.json    github-packages  publishConfig.registry is https://npm.pkg.github.com. Private package, published
#                                    with the token in NODE_AUTH_TOKEN, which publish.yml sets on that step alone.
#                                    The repository field names the repository this run is in (GITHUB_REPOSITORY); a unit
#                                    whose field names another one falls back to a dry run.
#                                    A version already there is skipped when the dist/**/index.json of the published
#                                    package are the same as the built ones, and stops the run when they differ.
#   pyproject.toml  pypi             the SemVer version is written by release-please as is (2.0.0-alpha.1); the build
#                                    backend normalizes it to PEP 440 (2.0.0a1), and the version published is read back
#                                    from the built wheel. PyPI has no dist-tags: pip skips pre-releases unless asked.
#   Cargo.toml      crates           SemVer as is. Trusted Publishing needs the crate to exist, so the first version is
#                                    published by hand (--crate-exists).
#   go.mod          go               nothing is uploaded: mirror-units.sh pushes the unit to its mirror repository and
#   Package.swift   swift            tags it there (vX.Y.Z for Go, X.Y.Z for Swift). This script only checks the unit.
# Every unit's version must belong to <stage> (version_stage in scripts/lib/release-stages.sh), so a dispatch with the
# wrong stage stops instead of publishing a prerelease under latest. A version that is already on the registry is
# skipped, so a re-run is safe. The unit's own file must carry the version of .release-please-manifest.json, and a
# unit that has a tag must equal it (a fix inside a released unit goes out under the next version).
#
# publish.yml splits the Trusted Publishing work over two jobs so the build does not use hosted-runner minutes:
# `pack` runs on the self-hosted build job and writes everything an upload needs under PUBLISH_OUT, `upload` runs on
# the hosted runner Trusted Publishing requires, reads PUBLISH_OUT from the downloaded artifact and builds nothing.
# Without a subcommand both run one after the other, which is what the GitHub Packages job does.
#
# usage: publish-units.sh [pack|upload] <alpha|beta|rc|ga> <path>...
#        publish-units.sh --registries <path>...    print npm=true / github-packages=true / pypi=true / crates=true /
#                                                   go=true / swift=true for the targets the paths need ($GITHUB_OUTPUT format)
#        publish-units.sh --filter <path>...        print the paths that are units to publish, one per line
#        publish-units.sh --mirrors <path>...       print the mirror repository names of the Go and Swift units, comma separated
#        publish-units.sh --crate-exists <path>...  exit 0 when every crates.io unit among the paths already has its crate
#                                                   on crates.io, 1 when one has not, 2 when crates.io cannot be asked
#   PUBLISH_DRY_RUN     1 prints one line per unit (target, name@version, registry, dist-tag) and the command that would
#                       run, and runs nothing: nothing is packed, built or uploaded. A version the registry already has
#                       is printed as skipped.
#   PUBLISH_REGISTRIES  comma list of targets (npm,github-packages,pypi,crates,go,swift): act only on the units of these
#                       targets. The checks still run for every unit. publish.yml has one job per kind of target.
#   PUBLISH_CHECK_ONLY  1 stops after the checks (file version, stage, same content as the tag)
#   PUBLISH_OUT         where packages are built (default tmp/publish): npm tarballs in npm/<component>/, Python wheels and
#                       sdists in pypi/, and packed.txt, the list of units `pack` built. Keep npm/ and pypi/ apart: the
#                       PyPI upload checks every file in its directory. crates.io has no file to carry: `upload` publishes
#                       from the source tree, which both jobs check out at the same commit.
#   MIRROR_OWNER        owner of the mirror repositories (default carlos-space), only used to name them in the output
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
cd "$REPO_ROOT"
usage="usage: publish-units.sh [pack|upload] <alpha|beta|rc|ga> <path>... | publish-units.sh --registries|--filter|--mirrors|--crate-exists <path>..."

dry_run() { [[ "${PUBLISH_DRY_RUN:-0}" == 1 ]]; }
check_only() { [[ "${PUBLISH_CHECK_ONLY:-0}" == 1 ]]; }

# wanted <target> → whether the run acts on units of that target (PUBLISH_REGISTRIES unset means all)
wanted() {
  local -a only=()
  [[ -n "${PUBLISH_REGISTRIES:-}" ]] || return 0
  IFS=, read -r -a only <<<"$PUBLISH_REGISTRIES"
  in_array "$1" "${only[@]}"
}

toml_get() { # toml_get <file> <table> <key>
  python3 -c 'import sys, tomllib; print(tomllib.load(open(sys.argv[1], "rb"))[sys.argv[2]][sys.argv[3]])' "$@"
}

npm_dist_tag() { if [[ "$1" == ga ]]; then printf '%s\n' latest; else printf '%s\n' "$1"; fi; }

summary() { [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || printf '%s\n' "- $*" >> "$GITHUB_STEP_SUMMARY"; }

# unit_target <path> → npm | github-packages | pypi | crates | go | swift, from the file the unit carries
unit_target() {
  local reg
  if [[ -f "$1/package.json" ]]; then
    reg="$(jq -r '.publishConfig.registry // empty' "$1/package.json")"
    case "${reg%/}" in
      "" | https://registry.npmjs.org) printf '%s\n' npm ;;
      https://npm.pkg.github.com) printf '%s\n' github-packages ;;
      *) echo "$1：publishConfig.registry 是 ${reg}，只支援 https://registry.npmjs.org 與 https://npm.pkg.github.com" >&2; return 1 ;;
    esac
  elif [[ -f "$1/pyproject.toml" ]]; then printf '%s\n' pypi
  elif [[ -f "$1/Cargo.toml" ]]; then printf '%s\n' crates
  elif [[ -f "$1/go.mod" ]]; then printf '%s\n' go
  elif [[ -f "$1/Package.swift" ]]; then printf '%s\n' swift
  else return 1; fi
}

target_of() { # target_of <path> → the target, or stop
  unit_target "$1" || die "$1 沒有 package.json（publishConfig.registry 只能是 npmjs 或 GitHub Packages）、pyproject.toml、Cargo.toml、go.mod 或 Package.swift，不知道要發布到哪裡"
}

# a unit is published when it carries one of those files, and a package.json only when it has a publishConfig: a
# unit that is not published (a shared library of the repository) has none
publishable() { # publishable <path>
  if [[ -f "$1/package.json" ]]; then jq -e 'has("publishConfig")' "$1/package.json" >/dev/null
  else [[ -f "$1/pyproject.toml" || -f "$1/Cargo.toml" || -f "$1/go.mod" || -f "$1/Package.swift" ]]; fi
}

unit_name() { # unit_name <path> <target>
  case "$2" in
    npm | github-packages) jq -r .name "$1/package.json" ;;
    pypi) toml_get "$1/pyproject.toml" project name ;;
    crates) toml_get "$1/Cargo.toml" package name ;;
    go) sed -n 's/^module //p' "$1/go.mod" | head -1 ;;
    swift) sed -n 's/^ *name: *"\([^"]*\)".*/\1/p' "$1/Package.swift" | head -1 ;;
  esac
}

# the version the unit's own file carries; empty for a Go unit (no file) and for a Swift unit without version.txt
file_version() { # file_version <path> <target> → "<file>\t<version>"
  case "$2" in
    npm | github-packages) printf '%s\t%s\n' "$1/package.json" "$(jq -r .version "$1/package.json")" ;;
    pypi) printf '%s\t%s\n' "$1/pyproject.toml" "$(toml_get "$1/pyproject.toml" project version)" ;;
    crates) printf '%s\t%s\n' "$1/Cargo.toml" "$(toml_get "$1/Cargo.toml" package version)" ;;
    swift) [[ ! -f "$1/version.txt" ]] || printf '%s\t%s\n' "$1/version.txt" "$(tr -d '[:space:]' < "$1/version.txt")" ;;
  esac
}

# The unit's own file must carry the manifest version: release-please writes both in one commit, and
# a broken updater would otherwise publish a version the manifest never released.
check_file_version() { # check_file_version <path> <file> <version in file> <manifest version>
  [[ "$3" == "$4" ]] || die "$1：manifest 是 $4，但 $2 是 ${3:-（空）}；release-please 沒有更新到這個檔"
}

unit_tag() { printf '%s/v%s\n' "$(unit_component "$1")" "$2"; }

# A publish that failed after its tag was made can be dispatched again from the release branch once the fix lands
# there. That is only safe while the unit's own files still equal the tag: otherwise one version number would name
# two different packages. publish.yml's checkout is shallow and carries no tags, so a shallow clone fetches the tag
# first; a unit without a tag has nothing to compare.
check_same_as_tag() { # check_same_as_tag <path> <version>
  local t; t="$(unit_tag "$1" "$2")"
  if ! git rev-parse -q --verify "refs/tags/$t" >/dev/null 2>&1; then
    [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == true ]] || return 0
    git fetch -q --depth=1 origin "refs/tags/$t:refs/tags/$t" 2>/dev/null || return 0
  fi
  git diff --quiet "$t" HEAD -- "$1" \
    || die "$1 的內容和 tag $t 不同。修正動到套件本身時，要推進到下一個序號重發，不能用同一個版號"
}

registry_url() { case "$1" in github-packages) echo https://npm.pkg.github.com ;; *) echo https://registry.npmjs.org ;; esac; }

# the registry a line names: the host, or the mirror repository for Go and Swift
registry_name() { # registry_name <target> <path>
  case "$1" in
    npm) echo registry.npmjs.org ;;
    github-packages) echo npm.pkg.github.com ;;
    pypi) echo pypi.org ;;
    crates) echo crates.io ;;
    go | swift) echo "github.com/${MIRROR_OWNER:-carlos-space}/$(unit_component "$2")" ;;
  esac
}

# SemVer of this repository's stages → PEP 440, only to ask PyPI in a dry run. A real run reads the version back
# from the built wheel instead (pack_pypi).
pep440() { # pep440 X.Y.Z[-alpha|beta|rc.N]
  local pre
  [[ "$1" == *-* ]] || { printf '%s\n' "$1"; return; }
  pre="${1#*-}"
  case "${pre%%.*}" in alpha) printf '%sa%s\n' "${1%%-*}" "${pre#*.}" ;; beta) printf '%sb%s\n' "${1%%-*}" "${pre#*.}" ;; *) printf '%s%s%s\n' "${1%%-*}" "${pre%%.*}" "${pre#*.}" ;; esac
}

npm_published() { npm view "$1@$2" version --registry "$3" 2>/dev/null | grep -qx "$2"; } # name version registry
pypi_published() { curl -fsS -o /dev/null "https://pypi.org/pypi/$1/$2/json" 2>/dev/null; }
crates_published() { curl -fsS -o /dev/null -A "publish check" "https://crates.io/api/v1/crates/$1/$2" 2>/dev/null; }

# crates_status <name> → exists | absent. Anything but a 200 or a 404 fails: a network error must not read as
# "the crate does not exist".
crates_status() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -A "publish check" "https://crates.io/api/v1/crates/$1" 2>/dev/null || true)"
  case "$code" in 200) echo exists ;; 404) echo absent ;; *) warn "crates.io answered ${code:-nothing} for the crate $1"; return 1 ;; esac
}

# One line per unit in a dry run. <what> is `dry-run` or `skip`; <rest> is the command, or the reason.
plan_line() { # plan_line <what> <target> <name> <version> <registry> <extra> <rest>
  printf '[%s] %s %s@%s -> %s%s: %s\n' "$1" "$2" "$3" "$4" "$5" "${6:+ ($6)}" "$7"
}

# Whether the repository field of a GitHub Packages package names the repository this run is in. GitHub names
# ignore case, and the field may be an https, git+https, ssh or git@ URL or the owner/repo shorthand. When it does
# not, the unit falls back to a dry run, as in git-flow-template's github_packages_registry.
check_repository_field() { # check_repository_field <path>
  local repo here
  repo="$(jq -r '(.repository | if type == "object" then .url else . end) // empty' "$1/package.json" \
    | sed -E 's#^(git\+)?(https?|ssh)://([^@/]+@)?github\.com/##; s#^git@github\.com:##; s#\.git$##' | tr 'A-Z' 'a-z')"
  here="$(printf '%s' "${GITHUB_REPOSITORY:-}" | tr 'A-Z' 'a-z')"
  if [[ -z "$repo" || "$repo" != "$here" ]]; then
    printf '%s\n' "  $1：repository 不符（package.json 是「${repo:-空}」，這次在「${here:-空}」），改 dry-run" >&2
    return 1
  fi
}

# whether the dist/**/index.json of the published <name>@<ver> are the same files, in the same places, as the
# ones built in <path>
published_indexes_match() { # published_indexes_match <path> <name> <version> <registry>
  local p="$1" dir f
  dir="$(mktemp -d "$PUBLISH_OUT/compare.XXXXXX")"
  ( cd "$dir" && npm pack "$2@$3" --registry "$4" --silent >/dev/null && tar -xzf ./*.tgz ) \
    || { rm -rf "$dir"; die "$2@$3 的已發布內容取不下來，無法比對 dist/**/index.json"; }
  diff <(cd "$dir/package" && find dist -name index.json 2>/dev/null | sort) <(cd "$p" && find dist -name index.json 2>/dev/null | sort) >/dev/null \
    || { rm -rf "$dir"; return 1; }
  while IFS= read -r f; do
    cmp -s "$dir/package/$f" "$p/$f" || { rm -rf "$dir"; return 1; }
  done < <(cd "$p" && find dist -name index.json 2>/dev/null | sort)
  rm -rf "$dir"
}

# --- dry run: one line per unit, nothing is run -------------------------------------------------------------------
plan_unit() { # plan_unit <path> <version> <stage> <target>
  local p="$1" ver="$2" stage="$3" t="$4" name reg tag pyver
  name="$(unit_name "$p" "$t")"
  reg="$(registry_name "$t" "$p")"
  case "$t" in
    npm | github-packages)
      tag="$(npm_dist_tag "$stage")"
      if npm_published "$name" "$ver" "$(registry_url "$t")"; then plan_line skip "$t" "$name" "$ver" "$reg" "" "已發布，略過"; return 0; fi
      if [[ "$t" == npm ]]; then
        plan_line dry-run "$t" "$name" "$ver" "$reg" "dist-tag $tag" "npm publish <tarball> --tag $tag --access public --registry $(registry_url "$t")"
      else
        plan_line dry-run "$t" "$name" "$ver" "$reg" "dist-tag $tag" "npm publish <tarball> --tag $tag --registry $(registry_url "$t")"
      fi ;;
    pypi)
      pyver="$(pep440 "$ver")"
      if pypi_published "$name" "$pyver"; then plan_line skip "$t" "$name" "$ver" "$reg" "" "已發布（${pyver}），略過"; return 0; fi
      plan_line dry-run "$t" "$name" "$ver" "$reg" "PEP 440 $pyver" "uv publish --trusted-publishing always --check-url https://pypi.org/simple/ <wheel and sdist>" ;;
    crates)
      if crates_published "$name" "$ver"; then plan_line skip "$t" "$name" "$ver" "$reg" "" "已發布，略過"; return 0; fi
      plan_line dry-run "$t" "$name" "$ver" "$reg" "" "cargo publish --locked --no-verify --manifest-path $p/Cargo.toml" ;;
    go | swift)
      plan_line dry-run "$t" "$name" "$ver" "$reg" "mirror tag $([[ "$t" == go ]] && echo "v$ver" || echo "$ver")" "bash scripts/release/mirror-units.sh $p" ;;
  esac
}

# --- npm and GitHub Packages --------------------------------------------------------------------------------------
# The tarball of <path>, in $PUBLISH_OUT/npm/<component>/. Nothing is packed when the version is already on the
# registry: upload then finds no tarball and skips the unit.
pack_npm() { # pack_npm <path> <version> <target>
  local p="$1" ver="$2" t="$3" name reg dir tgz
  name="$(jq -r .name "$p/package.json")"
  reg="$(registry_url "$t")"
  if [[ "$t" == github-packages ]] && ! check_repository_field "$p"; then return 0; fi
  if npm_published "$name" "$ver" "$reg"; then
    if [[ "$t" == github-packages ]]; then
      if published_indexes_match "$p" "$name" "$ver" "$reg"; then
        info "npm：$name@$ver 已在 ${reg}，dist/**/index.json 相同，略過"; return 0
      fi
      die "$name@$ver 已在 ${reg}，但已發布的 dist/**/index.json 和這次建置的不同。同一個版號不能發兩份內容：請使用者決定，改發下一個版號，或先確認是誰動了這個版號"
    fi
    info "npm：$name@$ver 已發布，略過"; return 0
  fi
  dir="$PUBLISH_OUT/npm/$(unit_component "$p")"
  mkdir -p "$dir"
  tgz="$(pnpm --filter "./$p" pack --pack-destination "$dir" --json | jq -r .filename)"
  log "npm：${name}@${ver} 已打包 → ${tgz##*/}"
}

publish_npm() { # publish_npm <path> <version> <stage> <target>
  local p="$1" ver="$2" t="$4" name tag tgz reg
  name="$(jq -r .name "$p/package.json")"
  tag="$(npm_dist_tag "$3")"
  reg="$(registry_url "$t")"
  tgz="$(compgen -G "$PUBLISH_OUT/npm/$(unit_component "$p")/*.tgz" | head -n 1 || true)"
  if [[ -z "$tgz" ]]; then
    info "npm：$name@$ver 沒有待上傳的套件檔（建置階段已略過），略過"; return 0
  fi
  if npm_published "$name" "$ver" "$reg"; then info "npm：$name@$ver 已發布，略過"; return 0; fi
  log "npm：${name}@${ver} → dist-tag ${tag}，上傳到 ${reg}"
  # npm reads a bare relative path such as artifacts/x.tgz as a GitHub owner/repo shorthand and fails
  # with exit 128. PUBLISH_OUT is absolute in CI; keep a relative one explicit anyway.
  [[ "$tgz" == /* || "$tgz" == ./* ]] || tgz="./$tgz"
  if [[ "$t" == npm ]]; then npm publish "$tgz" --tag "$tag" --access public --registry "$reg"
  else npm publish "$tgz" --tag "$tag" --registry "$reg"; fi
  summary "npm \`$name@$ver\` → dist-tag \`$tag\`（上傳到 ${reg}）"
}

# --- PyPI ---------------------------------------------------------------------------------------------------------
# Builds the wheel and sdist into $PUBLISH_OUT/pypi. The version is read back from the built wheel.
pack_pypi() { # pack_pypi <path> <version>
  local p="$1" ver="$2" name build out pyver
  name="$(toml_get "$p/pyproject.toml" project name)"
  build="$PUBLISH_OUT/build/$(unit_component "$p")" out="$PUBLISH_OUT/pypi"
  rm -rf "$build"; mkdir -p "$build" "$out"
  uv build --quiet --sdist --wheel --out-dir "$build" "$p"
  pyver="$(python3 - "$build" <<'PY'
import pathlib, sys, zipfile
wheel = next(pathlib.Path(sys.argv[1]).glob("*.whl"))
with zipfile.ZipFile(wheel) as z:
    meta = next(n for n in z.namelist() if n.endswith(".dist-info/METADATA"))
    print(next(l for l in z.read(meta).decode().splitlines() if l.startswith("Version: "))[9:])
PY
)"
  if pypi_published "$name" "$pyver"; then
    info "PyPI：$name $pyver 已發布，略過"; rm -rf "$build"; return 0
  fi
  mv "$build"/* "$out"/
  rm -rf "$build"
  log "PyPI：${name} ${ver} → ${pyver}（PEP 440，取自建置出的 wheel）已打包"
}

publish_pypi() { # publish_pypi <path> <version>: only the summary line, the files go up together in upload_pypi
  summary "PyPI \`$(toml_get "$1/pyproject.toml" project name)\` $2"
}

# One upload for every Python unit of the run, from a directory that holds nothing but their wheels and sdists.
# --check-url skips files PyPI already has. --trusted-publishing always takes the job's OIDC token.
upload_pypi() {
  local out="$PUBLISH_OUT/pypi"
  compgen -G "$out/*" >/dev/null || return 0
  log "PyPI：上傳 $(find "$out" -type f | wc -l | tr -d ' ') 個檔"
  uv publish --trusted-publishing always --check-url https://pypi.org/simple/ "$out/"*
}

# --- crates.io ----------------------------------------------------------------------------------------------------
# crates.io has no command that uploads a built .crate, so the build only verifies the crate (a dry run compiles it)
# and the upload job publishes from the source tree.
pack_crates() { # pack_crates <path> <version>
  local p="$1" ver="$2" name
  name="$(toml_get "$p/Cargo.toml" package name)"
  if crates_published "$name" "$ver"; then
    info "crates.io：$name $ver 已發布，略過"; return 0
  fi
  log "crates.io：${name} ${ver} 驗證建置"
  cargo publish --dry-run --locked --manifest-path "$p/Cargo.toml"
}

# The token comes from crates-io-auth-action (CARGO_REGISTRY_TOKEN), which exchanges the job's OIDC token for it.
publish_crates() { # publish_crates <path> <version>
  local p="$1" ver="$2" name
  name="$(toml_get "$p/Cargo.toml" package name)"
  if crates_published "$name" "$ver"; then
    info "crates.io：$name $ver 已發布，略過"; return 0
  fi
  [[ "$(crates_status "$name")" == exists ]] || die "crates.io 還沒有 crate ${name}：Trusted Publishing 只能登記在已存在的 crate 上，第一版要由使用者手動發布"
  log "crates.io：${name} ${ver}（建置階段已驗證，--no-verify）"
  cargo publish --locked --no-verify --manifest-path "$p/Cargo.toml"
  summary "crates.io \`$name $ver\`"
}

# --- Go and Swift: nothing to upload ------------------------------------------------------------------------------
# release-please creates the unit tag when the Release PR merges, and mirror-units.sh pushes the unit to its mirror
# repository. A real run requires the unit tag to exist.
publish_tag() { # publish_tag <path> <version> <target>
  local p="$1" ver="$2" t
  t="$(unit_tag "$p" "$ver")"
  if ! git rev-parse -q --verify "refs/tags/$t" >/dev/null 2>&1; then
    git fetch -q --depth=1 origin "refs/tags/$t:refs/tags/$t" 2>/dev/null || true
    git rev-parse -q --verify "refs/tags/$t" >/dev/null 2>&1 || die "tag $t 不存在，所以 $p $ver 還沒有發版"
  fi
  log "${3}：$(unit_name "$p" "$3") ${ver}，tag $t 即發布紀錄，由 mirror-units.sh 推到鏡像倉，這裡不上傳"
  summary "$3 \`$(unit_name "$p" "$3") $ver\`，tag \`$t\`（不上傳）"
}

[[ $# -ge 2 ]] || die "$usage"
case "$1" in
  --registries)
    shift
    regs=()
    for p in "$@"; do r="$(target_of "${p%/}")"; regs+=("$r=true"); done
    printf '%s\n' "${regs[@]}" | sort -u
    exit 0 ;;
  --filter)
    shift
    for p in "$@"; do p="${p%/}"; if publishable "$p"; then printf '%s\n' "$p"; fi; done
    exit 0 ;;
  --mirrors)
    shift
    names=()
    for p in "$@"; do p="${p%/}"; [[ "$(unit_target "$p" 2>/dev/null || true)" =~ ^(go|swift)$ ]] && names+=("$(unit_component "$p")"); done
    (IFS=,; printf '%s\n' "${names[*]:-}")
    exit 0 ;;
  --crate-exists)
    shift
    for p in "$@"; do
      p="${p%/}"
      [[ "$(target_of "$p")" == crates ]] || continue
      status="$(crates_status "$(toml_get "$p/Cargo.toml" package name)")" || exit 2
      [[ "$status" == exists ]] || exit 1
    done
    exit 0 ;;
esac

phases=(pack upload)
case "$1" in
  pack) phases=(pack); shift ;;
  upload) phases=(upload); shift ;;
esac
[[ $# -ge 2 ]] || die "$usage"
stage="$1"; shift
is_stage "$stage" || die "階段「${stage}」不是 ${RELEASE_STAGES[*]} 之一"
PUBLISH_OUT="${PUBLISH_OUT:-$REPO_ROOT/tmp/publish}"

if [[ " ${phases[*]} " == *" pack "* ]] && ! dry_run && ! check_only; then
  rm -rf "$PUBLISH_OUT/npm" "$PUBLISH_OUT/pypi" "$PUBLISH_OUT/build" "$PUBLISH_OUT/packed.txt"
  mkdir -p "$PUBLISH_OUT"
fi

for phase in "${phases[@]}"; do
  for p in "$@"; do
    p="${p%/}"
    ver="$(manifest_version "$p")"
    [[ -n "$ver" ]] || die "$p 不在 $MANIFEST"
    vs="$(version_stage "$ver")" || die "$p 的版號 $ver 不是 X.Y.Z 或 X.Y.Z-<alpha|beta|rc>.N，無法決定發布階段"
    [[ "$vs" == "$stage" ]] || die "$p 的版號 $ver 屬於 ${vs}，但這次發布的階段是 ${stage}"
    target="$(target_of "$p")"
    vfile="" vin=""
    IFS=$'\t' read -r vfile vin < <(file_version "$p" "$target" || true) || true
    [[ -z "${vfile:-}" ]] || check_file_version "$p" "$vfile" "${vin:-}" "$ver"
    check_same_as_tag "$p" "$ver"
    if check_only; then
      echo "check only: $p $(unit_name "$p" "$target")@$ver passed (stage $stage, target $target)"; continue
    fi
    wanted "$target" || continue
    if dry_run; then
      [[ "$phase" == upload ]] && plan_unit "$p" "$ver" "$stage" "$target"
      continue
    fi
    if [[ "$phase" == pack ]]; then
      case "$target" in
        npm | github-packages) pack_npm "$p" "$ver" "$target" ;;
        pypi) pack_pypi "$p" "$ver" ;;
        crates) pack_crates "$p" "$ver" ;;
      esac
      printf '%s %s\n' "$p" "$ver" >> "$PUBLISH_OUT/packed.txt"
    else
      # an upload job that got a different artifact than the build job made stops instead of publishing it
      case "$target" in go | swift) ;; *)
        grep -qxF "$p $ver" "$PUBLISH_OUT/packed.txt" 2>/dev/null \
          || die "$p $ver 不在 $PUBLISH_OUT/packed.txt：建置階段沒有打包這個單元，或下載的 artifact 不是這次建置的" ;;
      esac
      case "$target" in
        npm | github-packages) publish_npm "$p" "$ver" "$stage" "$target" ;;
        pypi) publish_pypi "$p" "$ver" ;;
        crates) publish_crates "$p" "$ver" ;;
        go | swift) publish_tag "$p" "$ver" "$target" ;;
      esac
    fi
  done
  if [[ "$phase" == upload ]] && ! dry_run && ! check_only && wanted pypi; then upload_pypi; fi
done
