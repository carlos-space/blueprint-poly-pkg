#!/usr/bin/env bash
# Native build for a mobile unit. ios / macos are SwiftPM packages: build and test with the Swift
# toolchain (the ci `native` job runs this on the macOS runner). android stays a stub: a real gradle
# build needs a JDK and the Android SDK on the runner, which the template does not provision.
#
# usage: native-build.sh <product-ios|product-macos|product-android>   an app under apps/, as in git-flow-template
#        native-build.sh <dir>                                          a SwiftPM package at <dir> (has a Package.swift)
#        native-build.sh                                                every directory of CI_SCOPE_NATIVE_UNITS in scripts/ci/ci-scope.conf
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if (( $# == 0 )); then
  CI_SCOPE_NATIVE_UNITS=()
  # shellcheck source=scripts/ci/ci-scope.conf
  source scripts/ci/ci-scope.conf
  (( ${#CI_SCOPE_NATIVE_UNITS[@]} )) || { printf '%s\n' "native-build：ci-scope.conf 的 CI_SCOPE_NATIVE_UNITS 是空的，沒有原生單元要建置"; exit 0; }
  for unit in "${CI_SCOPE_NATIVE_UNITS[@]}"; do bash "$0" "$unit"; done
  exit 0
fi
app="${1:?usage: native-build.sh <product-ios|product-macos|product-android|dir>}"
# A SwiftPM package of a unit directory (not an app of the template): the same build and test commands,
# pointed at the package. It has no version.txt, because release-please keeps the version in the manifest.
if [[ -f "$app/Package.swift" ]]; then
  command -v swift >/dev/null || { printf '%s\n' >&2 "[$app] 找不到 swift 工具鏈：原生建置在 macOS runner 的 ci native job 執行"; exit 1; }
  printf '%s\n' "[$app] swift build + swift test"
  swift build --package-path "$app" && swift test --package-path "$app"
  exit 0
fi
dir="$(cd "apps/$app" && pwd)"
version="$(cat "$dir/version.txt")"
case "$app" in
  product-ios|product-macos)
    command -v swift >/dev/null || { printf '%s\n' >&2 "[$app] 找不到 swift 工具鏈：原生建置在 macOS runner 的 ci native job 執行"; exit 1; }
    printf '%s\n' "[$app] version ${version}：swift build + swift test"
    ( cd "$dir" && swift build -c release && swift test )
    ;;
  product-android)
    printf '%s\n' "[product-android] version ${version}：gradle 未接上（runner 需 JDK 與 Android SDK），native/build.gradle 的 versionName 由 release-please 維護"
    ;;
  *) printf '%s\n' >&2 "unknown app: $app"; exit 2 ;;
esac
