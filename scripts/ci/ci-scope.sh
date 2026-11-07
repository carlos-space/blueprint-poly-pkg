#!/usr/bin/env bash
# Decide what this ci run has to check. Writes run=true|false and native=true|false to $GITHUB_OUTPUT
# and the reason to $GITHUB_STEP_SUMMARY; every other ci job runs only when run=true.
#
# A push is compared with the last *successful* ci run on the same branch, never with the previous
# push: a docs-only commit on top of a red commit still carries the red commit's source change in its
# diff, so it runs. A run skipped here still concludes success, which is sound because its tree
# differs from a green one only in non-source paths; the release gates read that success as "the tip
# is checked". The base never falls back to another branch, because the ci of a branch can be wider
# than another's (a train adds e2e): a new train with no green run yet runs everything.
#
# With CI_SCOPE_PR_TREE=1 a push is also skipped when it is the merge of a pull request whose head has
# the same tree and a green ci run. Only enable it where the pull request runs the same checks as the
# push; a pull request that checks only the affected units says nothing about the full tree.
#
# Scope looks at source changes only. What a repository has (facts/, release-policy.json, tests/e2e/) is not an
# output: a job with no work of its own says so and concludes success, and which jobs a repository has follows from
# its roles when ci.yml is composed.
#
# This file is the same in every repository that adopts the flow; what differs lives in
# scripts/ci/ci-scope.conf.
#
# usage: ci-scope.sh
#   env from Actions: EVENT, BRANCH, BASE_REF (pull_request), DEFAULT_BRANCH, REPO, GH_TOKEN
#   needs a checkout with fetch-depth: 0 and a token with actions: read and pull-requests: read
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
CI_SCOPE_NON_SOURCE=() CI_SCOPE_NATIVE=() CI_SCOPE_NATIVE_EXCLUDE=() CI_SCOPE_NATIVE_UNITS=() CI_SCOPE_PR_TREE=0 CI_SCOPE_WORKFLOW=ci.yml
# shellcheck source=scripts/ci/ci-scope.conf
source scripts/ci/ci-scope.conf

decide() { # decide <run> <native> <reason>
  printf 'run=%s\nnative=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/null}"
  printf '%s\n' "$3"
  printf '### ci scope\n- run: `%s`, native: `%s`\n- %s\n' "$1" "$2" "$3" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
}

# git pathspecs: the whole tree minus the paths that never change what ci builds or tests
source_spec=(.)
for p in "${CI_SCOPE_NON_SOURCE[@]}"; do source_spec+=(":(glob,exclude)$p"); done
native_spec=()
for p in "${CI_SCOPE_NATIVE[@]}"; do native_spec+=(":(glob)$p"); done
for p in "${CI_SCOPE_NATIVE_EXCLUDE[@]}"; do native_spec+=(":(glob,exclude)$p"); done

changed() { # changed <base> <pathspec>...: does <base>..HEAD touch these paths
  local base="$1"; shift
  ! git diff --quiet "$base" HEAD -- "$@"
}

native_since() { # native_since <base>: true|false, true when there is no base to compare with
  (( ${#native_spec[@]} )) || { echo false; return; }
  [[ -n "$1" ]] || { echo true; return; }
  if changed "$1" "${native_spec[@]}"; then echo true; else echo false; fi
}

last_green() { # last_green <branch>: head of the branch's latest successful ci run, when HEAD contains it
  local sha
  sha="$(gh run list --workflow "$CI_SCOPE_WORKFLOW" --branch "$1" --status success --limit 1 \
           --json headSha --jq '.[0].headSha // empty' 2>/dev/null || true)"
  [[ -n "$sha" ]] && git merge-base --is-ancestor "$sha" HEAD 2>/dev/null && printf '%s\n' "$sha"
  return 0
}

merged_pr_head() { # head of the merged pull request HEAD came from, if any
  gh api "repos/${REPO:?}/commits/$(git rev-parse HEAD)/pulls" \
    --jq '[.[] | select(.merged_at != null)][0].head.sha // empty' 2>/dev/null || true
}

case "${EVENT:?}" in
  pull_request)
    base="$(git merge-base "origin/${BASE_REF:?}" HEAD)"
    why="和 ${BASE_REF} 的共同祖先 ${base:0:7} 比較"
    native_base="$base"
    ;;
  push)
    if (( CI_SCOPE_PR_TREE )); then
      head="$(merged_pr_head)"
      if [[ -n "$head" ]]; then
        tree="$(gh api "repos/${REPO:?}/git/commits/$head" --jq .tree.sha 2>/dev/null || true)"
        green="$(gh run list --workflow "$CI_SCOPE_WORKFLOW" --commit "$head" --status success --limit 1 \
                   --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)"
        if [[ "$tree" == "$(git rev-parse 'HEAD^{tree}')" && -n "$green" ]]; then
          decide false false "來源 PR 的 head ${head:0:7} 與 HEAD 同 tree，且 ci run ${green} 已通過"
        fi
      fi
    fi
    base="$(last_green "${BRANCH:?}")"
    [[ -n "$base" ]] || {
      # native keeps its old base so a new branch does not take a macOS slot for nothing
      native_base="$(git merge-base "origin/${DEFAULT_BRANCH:?}" HEAD 2>/dev/null || true)"
      decide true "$(native_since "$native_base")" "${BRANCH} 沒有可比較的成功 ci，全部執行"
    }
    why="和 ${BRANCH} 最近一次成功的 ci ${base:0:7} 比較"
    native_base="$base"
    ;;
  *)
    decide true "$( (( ${#native_spec[@]} )) && echo true || echo false )" "${EVENT} 事件一律全部執行"
    ;;
esac

if changed "$base" "${source_spec[@]}"; then
  decide true "$(native_since "$native_base")" "${why}：有原始碼變更"
else
  decide false false "${why}：只改了非原始碼路徑"
fi
