#!/usr/bin/env bash
# Waiting for and merging a release-please Release PR, shared by scripts/release/merge-release-pr.sh and the
# scenario scripts (examples/lib/scenario.sh). Source it through common.sh; do not execute.
# 輪詢間隔決定「事情做完後多久才被發現」，次數乘間隔決定「多久才放棄」。兩者要分開調：間隔縮短時
# 若沿用原本的 40 次，上限會跟著縮短（原本 15 秒乘 40 次是 10 分鐘，3 秒乘 40 次只剩 2 分鐘），
# 比現在更容易把「還在排隊」誤判成失敗（實測 release-please 曾排隊逾 10 分鐘）。目前是 3 秒乘 180 次，
# 每個等待迴圈的睡眠時間上限是 9 分鐘（不含每輪 gh 呼叫本身的耗時）。release_pr_settle 依序有
# 好幾個迴圈，每個各自有這個上限。
POLL_TRIES="${POLL_TRIES:-180}" POLL_SLEEP="${POLL_SLEEP:-3}"

# wait_release_pr <base-branch> → prints PR number.
# Identify the Release PR by its head branch, not by the "autorelease: pending" label: release-please
# opens the PR first and labels it afterwards, so a run that fails in between leaves a real, usable
# Release PR with no label at all (observed 2026-09-07).
wait_release_pr() {
  local base="$1" n="" i
  for ((i=1; i<=POLL_TRIES; i++)); do
    n="$(gh pr list --base "$base" --head "release-please--branches--$base" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)"
    [[ -z "$n" ]] && n="$(gh pr list --base "$base" --label 'autorelease: pending' --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)"
    [[ -n "$n" ]] && { printf '%s\n' "$n"; return 0; }
    sleep "$POLL_SLEEP"
  done
  return 1
}

# wait until no release-please run is queued/in progress for <branch>: a Release PR that predates the
# commit we just pushed would release the wrong version (observed 2026-09-07: merged a stale PR).
wait_release_please_idle() {
  local branch="$1" i
  for ((i=1; i<=POLL_TRIES; i++)); do
    [[ -z "$(gh run list --workflow release-please.yml --branch "$branch" --limit 5 --json status --jq '.[] | select(.status != "completed") | .status' 2>/dev/null)" ]] && return 0
    sleep "$POLL_SLEEP"
  done
  warn "release-please 仍在執行，繼續等待 Release PR"
}

# manifest as it stands on the Release PR's head branch, i.e. the content a merge would land
release_pr_manifest() { # release_pr_manifest <base-branch>
  local head="release-please--branches--$1"
  git fetch -q origin "$head" 2>/dev/null || return 1
  git show "FETCH_HEAD:$MANIFEST" 2>/dev/null
}

# release_pr_units <base-branch> → "<unit> <version>" per line: the units whose manifest version on the
# Release PR's head differs from origin/<base-branch>'s, with the PR's version. This is the set a merge
# of that PR releases. Fetch <base-branch> first; the comparison reads origin/<base-branch>.
release_pr_units() {
  local base="$1" mf p v
  mf="$(release_pr_manifest "$base")" || return 1
  while read -r p v; do
    [[ -n "$p" ]] && printf '%s %s\n' "$(unit_component "$p")" "$v"
  done < <(jq -r -s '.[0] as $cur | .[1] | to_entries[] | select(.value != $cur[.key]) | "\(.key) \(.value)"' \
    <(git show "origin/$base:$MANIFEST") <(printf '%s\n' "$mf"))
}

# release_pr_settle <base-branch> [--optional] [--expect-stable]
# Sets RELEASE_PR_NUMBER and RELEASE_PR_SHA once the Release PR's head has stopped moving.
# --optional：沒有 Release PR 時回傳 1 而不中止。切自產品 tag 的修補發布在 hotfix 合入前本來就無版可發。
# --expect-stable：GA 用。只在 PR 內容已無 prerelease 版號時才算穩定。
#
# 「現在沒有執行中的 run」不足以判定 PR 是最新的：release-please 每跑一次就重寫該 PR，閒置檢查通過
# 之後才啟動的 run 會把內容換掉，於是合併到的是舊版本（實測 2026-09-08：GA 合併到仍帶預發布版號的
# PR，發布分支因此停在 prerelease）。改為等 head SHA 在一次重查後仍相同，必要時再核對內容。
release_pr_settle() {
  local base="$1" n optional=0 expect_stable=0 a i sha prev="" mf
  RELEASE_PR_NUMBER="" RELEASE_PR_SHA=""
  for a in "${@:2}"; do
    case "$a" in --optional) optional=1 ;; --expect-stable) expect_stable=1 ;; esac
  done
  log "等待 $base 上的 release-please 執行完畢（避免合併過期的 Release PR）…"
  wait_release_please_idle "$base"
  log "等待 release-please 在 $base 開 Release PR…"
  if ! n="$(wait_release_pr "$base")"; then
    (( optional )) && { info "$base 目前沒有可發版的變更，略過"; return 1; }
    die "逾時：$base 上沒有 Release PR（查 gh run list --workflow release-please.yml）"
  fi
  for ((i=1; i<=POLL_TRIES; i++)); do
    wait_release_please_idle "$base"
    sha="$(gh pr view "$n" --json headRefOid --jq .headRefOid 2>/dev/null || true)"
    if [[ -n "$sha" && "$sha" == "$prev" ]]; then
      (( expect_stable )) || break
      mf="$(release_pr_manifest "$base" || true)"
      if [[ -n "$mf" ]] && ! printf '%s\n' "$mf" | jq -e 'any(.[]; test("-"))' >/dev/null 2>&1; then break; fi
      warn "Release PR #$n 仍帶 prerelease 版號，等 release-please 重新產生"
    fi
    (( i == POLL_TRIES )) && die "逾時：Release PR #$n 內容未收斂"
    prev="$sha"; sleep "$POLL_SLEEP"
  done
  RELEASE_PR_NUMBER="$n" RELEASE_PR_SHA="$sha"
  info "Release PR #${n}：$(gh pr view "$n" --json title --jq .title)"
}

# release_pr_squash <number> <head-sha>: squash-merge only if the PR head is still <head-sha>, so a PR
# that release-please rewrote after the checks is refused instead of merged
release_pr_squash() {
  external_retry merge "$(remote_target)" gh pr merge "$1" --squash --match-head-commit "$2"
}

# merge_release_pr <base-branch> [--optional] [--expect-stable]
# Wait for a settled Release PR and squash-merge it. No pin and no fact-kit check: those belong to
# scripts/release/merge-release-pr.sh, which a person uses on a real release line.
merge_release_pr() {
  if (( DRY_RUN )); then info "[dry-run] 等待並合併 $1 上的 Release PR"; return 0; fi
  release_pr_settle "$@" || return 1
  release_pr_squash "$RELEASE_PR_NUMBER" "$RELEASE_PR_SHA"
}
