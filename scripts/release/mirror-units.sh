#!/usr/bin/env bash
# Mirror the Go and Swift units into their own repositories. Neither has a registry: the Go proxy and SwiftPM read
# the tags of a repository whose root is the package, so each release is pushed from <unit path>/ to the
# default branch of <MIRROR_OWNER>/<component> and tagged there with the bare version.
#
#   Go     v<version>    (0.3.0-alpha.2 -> v0.3.0-alpha.2)    the Go proxy needs the "v"
#   Swift  <version>     (0.3.0-alpha.2 -> 0.3.0-alpha.2)     SwiftPM reads SemVer tags without the "v"
#
# Each release is one mirror commit: the tree of <unit path> at the unit's release tag (<component>/v<version>, see
# unit_tag), on top of the mirror's main. Its author, committer and dates are those of the release tag's commit, so
# the same tag on the same main always gives the same commit. The mirror does not carry the source history: a
# release line is cut from main, the previous line came back to main as a squash, so the source commits of two lines
# are not ancestors of each other, while the Go proxy and SwiftPM only read the tags. The script never forces a push.
#
# main is always the commit of the highest version tagged in the mirror. A rerun is safe:
#   - the mirror tag exists and its tree is the unit's tree at the release tag: nothing to do
#   - the mirror tag exists with another tree: refuse, because a published version must not move
#   - a higher version is already tagged (an older version dispatched again): only the tag is pushed, main stays
#   - main is not the commit of the highest tag: refuse (someone pushed to the mirror by hand)
#
# usage: mirror-units.sh [--dry-run] <path>...      units that are not Go or Swift are skipped
#   --dry-run         print what would be pushed (commit, tag, file list); nothing is written. Without a release tag
#                     the unit's tree is taken from HEAD, so the unit can be rehearsed on a branch.
#   MIRROR_OWNER      owner of the mirror repositories (default carlos-space); the repository is the component name
#   MIRROR_REMOTE     full remote URL or path, replaces owner/component (tests use a local bare repository)
#   MIRROR_PUSH_TOKEN GitHub App token with contents: write on the mirror repositories; sent as an HTTP header, never in a URL
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
cd "$REPO_ROOT"

unit_tag() { printf '%s/v%s\n' "$(unit_component "$1")" "$2"; } # the unit tag, <ComponentName>/v<version>
unit_mirror_kind() { # unit_mirror_kind <path> → go | swift, from the file the unit carries
  if [[ -f "$1/go.mod" ]]; then printf '%s\n' go
  elif [[ -f "$1/Package.swift" ]]; then printf '%s\n' swift
  else return 1; fi
}

dry=0
if [[ "${1:-}" == --dry-run ]]; then dry=1; shift; fi
[[ $# -ge 1 ]] || die "usage: mirror-units.sh [--dry-run] <path>..."

# mirror_tag <registry> <version> → the tag in the mirror repository
mirror_tag() {
  case "$1" in
    go) printf 'v%s\n' "$2" ;;
    swift) printf '%s\n' "$2" ;;
    *) return 1 ;;
  esac
}

# version_gt <a> <b> → success when version a is above b (X.Y.Z or X.Y.Z-<alpha|beta|rc>.N)
version_gt() {
  local a="$1" b="$2" sa="${1%%-*}" sb="${2%%-*}"
  [[ "$a" != "$b" ]] || return 1
  if [[ "$sa" != "$sb" ]]; then
    [[ "$(printf '%s\n%s\n' "$sa" "$sb" | sort -V | tail -1)" == "$sa" ]]
    return
  fi
  [[ "$a" != "$sa" ]] || return 0 # a is the release, b a pre-release of it
  [[ "$b" != "$sb" ]] || return 1
  [[ "$(printf '%s\n%s\n' "${a#*-}" "${b#*-}" | sort -V | tail -1)" == "${a#*-}" ]]
}

# git against the mirror, with the token as a header when there is one
mgit() {
  if [[ -n "${MIRROR_PUSH_TOKEN:-}" ]]; then
    git -c "http.extraheader=Authorization: Basic $(printf 'x-access-token:%s' "$MIRROR_PUSH_TOKEN" | base64 | tr -d '\n')" "$@"
  else
    git "$@"
  fi
}

mirror_unit() { # mirror_unit <path>
  local p="${1%/}" reg ver comp remote mtag ref tree sha tagged main top="" topsha="" s r an ae ad
  reg="$(unit_mirror_kind "$p" 2>/dev/null || true)"
  if [[ "$reg" != go && "$reg" != swift ]]; then info "$p: not a Go or Swift unit, skipped"; return 0; fi
  jq -e --arg p "$p" '.packages | has($p)' "$CONFIG" >/dev/null || die "unexpected package path: $p (not a key of packages in $CONFIG)"
  ver="$(manifest_version "$p")"
  version_stage "$ver" >/dev/null || die "$p: version \"$ver\" is not X.Y.Z or X.Y.Z-<alpha|beta|rc>.N"
  comp="$(unit_component "$p")"
  remote="${MIRROR_REMOTE:-https://github.com/${MIRROR_OWNER:-carlos-space}/$comp.git}"
  mtag="$(mirror_tag "$reg" "$ver")"

  ref="$(unit_tag "$p" "$ver")"
  if ! git rev-parse -q --verify "refs/tags/$ref^{commit}" >/dev/null 2>&1; then
    (( dry )) || die "release tag $ref does not exist, so $p $ver has not been released"
    info "release tag $ref does not exist yet (dry run): taking the tree of HEAD"
    ref=HEAD
  fi
  tree="$(git rev-parse -q --verify "$ref:$p" 2>/dev/null)" && [[ "$(git cat-file -t "$tree")" == tree ]] || die "$p is not part of $ref"
  case "$reg" in
    go) git cat-file -e "$tree:go.mod" 2>/dev/null || die "$p: the unit has no go.mod at $ref" ;;
    swift) git cat-file -e "$tree:Package.swift" 2>/dev/null || die "$p: the unit has no Package.swift at $ref" ;;
  esac

  # what the mirror has now (a read; works without a token on a public repository)
  tagged="$(mgit ls-remote --refs "$remote" "refs/tags/$mtag" | cut -f1)"
  main="$(mgit ls-remote "$remote" refs/heads/main | cut -f1)"
  local action=push
  if [[ -n "$tagged" ]]; then
    mgit fetch -q --no-tags "$remote" "refs/tags/$mtag"
    [[ "$(git rev-parse "$tagged^{tree}")" == "$tree" ]] || die "$comp already has tag $mtag at ${tagged:0:12} with other content than $p at $ref; a published version must not move"
    sha="$tagged"
    action=none
  else
    while IFS=$'\t' read -r s r; do
      r="${r#refs/tags/}"
      [[ "$reg" != go ]] || r="${r#v}"
      version_stage "$r" >/dev/null 2>&1 || continue
      if [[ -z "$top" ]] || version_gt "$r" "$top"; then top="$r"; topsha="$s"; fi
    done < <(mgit ls-remote --refs --tags "$remote")
    if [[ -n "$main" ]]; then
      [[ "$main" == "$topsha" ]] || die "$comp main (${main:0:12}) is not the commit of its highest tag${top:+ $(mirror_tag "$reg" "$top") (${topsha:0:12})}; someone pushed to the mirror by hand"
      mgit fetch -q --no-tags "$remote" refs/heads/main
    fi
    IFS=$'\x1f' read -r an ae ad < <(git log -1 --format='%an%x1f%ae%x1f%aI' "$ref")
    sha="$(GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" GIT_AUTHOR_DATE="$ad" \
      GIT_COMMITTER_NAME="$an" GIT_COMMITTER_EMAIL="$ae" GIT_COMMITTER_DATE="$ad" \
      git commit-tree --no-gpg-sign "$tree" ${main:+-p "$main"} -m "$comp $ver" -m "Source: $ref ($(git rev-parse "$ref^{commit}"))")"
    if [[ -n "$top" ]] && version_gt "$top" "$ver"; then action=tag-only; fi
  fi

  local report
  report="$({
    echo "## $comp  ($p $ver)"
    echo "source        $ref"
    echo "mirror        $remote"
    echo "mirror commit $sha"
    echo "mirror tag    $mtag"
    echo "remote main   ${main:-(empty)}"
    echo "action        $action"
    echo "history (newest first, up to 5):"
    git log --format='  %h %s' -n 5 "$sha"
    echo "files at the mirror root ($(git ls-tree -r --name-only "$sha" | wc -l | tr -d ' ')):"
    git ls-tree -r --name-only "$sha" | sed 's/^/  /'
    [[ "$reg" != go ]] || echo "go.mod: $(git show "$sha:go.mod" | sed -n '/^module /p')"
  })"
  printf '%s\n' "$report"
  [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || printf '\n```\n%s\n```\n' "$report" >> "$GITHUB_STEP_SUMMARY"

  if (( dry )); then echo "dry run: nothing pushed"; return 0; fi
  case "$action" in
    none) echo "$comp $mtag is already mirrored, nothing to push" ;;
    tag-only) mgit push "$remote" "$sha:refs/tags/$mtag" ;;
    push) mgit push --atomic "$remote" "$sha:refs/heads/main" "$sha:refs/tags/$mtag" ;;
  esac
}

for p in "$@"; do mirror_unit "$p"; done
