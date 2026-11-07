#!/usr/bin/env bash
# Check that every commit in a range satisfies the rules for entering main (docs/git-flow.md, 進入 main):
# one change is one commit, so there are no merge commits; every subject follows Conventional Commits; and
# no message carries AI-platform attribution (check-commit-body.sh --only attribution).
# The pre-push hook runs it on the range being pushed; nightly runs it on main's whole first-parent
# history, catching commits that skipped the hooks with --no-verify. It only reports, never rewrites.
# The attribution rule holds from the commit that added scripts/ci/ai-attribution-list.txt: a commit whose
# tree has no list predates the rule, and its message is history that is not rewritten.
# usage: check-main-commits.sh <rev-range>   e.g. origin/main, abc123..def456
set -euo pipefail
# check-commit-body.sh needs bash 4; under 3.2 it would fail on every commit and read as attribution
(( BASH_VERSINFO[0] >= 4 )) || { printf '%s\n' >&2 "✗ 需要 bash 4 以上（目前 ${BASH_VERSION}）"; exit 1; }
range="${1:?usage: check-main-commits.sh <rev-range>}"
here="$(cd "$(dirname "$0")" && pwd)"
list=scripts/ci/ai-attribution-list.txt
bad=0
while IFS= read -r c; do
  [[ -n "$c" ]] || continue
  printf '%s\n' >&2 "✗ ${c:0:7} 是合併 commit：進 main 用 git merge --squash，一個變更一個 commit"; bad=1
done < <(git rev-list --first-parent --merges "$range")
while IFS=$'\t' read -r c subject; do
  [[ -n "$c" ]] || continue
  bash "$here/check-pr-title.sh" "$subject" >/dev/null 2>&1 \
    || { printf '%s\n' >&2 "✗ ${c:0:7} 的訊息不符 Conventional Commits：$subject"; bad=1; }
  if git cat-file -e "$c:$list" 2>/dev/null; then
    bash "$here/check-commit-body.sh" --only attribution --commit "$c" >/dev/null 2>&1 \
      || { printf '%s\n' >&2 "✗ ${c:0:7} 的訊息帶 AI 平台署名：${subject}（看是哪一行：bash scripts/ci/check-commit-body.sh --only attribution --commit ${c:0:7}）"; bad=1; }
  fi
done < <(git log --first-parent --no-merges --format=$'%H\t%s' "$range")
(( bad == 0 )) && printf '%s\n' "✓ $range 的 commit 都符合進 main 的條件"
exit "$bad"
