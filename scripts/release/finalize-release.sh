#!/usr/bin/env bash
# Close a release train in three phases:
#   ga          each train unit gets a "Release-As: <its own stable version>" commit (the prerelease
#               suffix stripped from its current version), and the config leaves prerelease mode.
#               One commit per unit: Release-As is a per-commit footer and release-please attributes
#               it to the paths that commit touches, so unit versions stay independent.
#               advance-release.sh --to ga hands over to this phase; the earlier stages are its job.
#   merge-back  verify the GA tags of the units the train shipped (a line can ship none: a repository that joins
#               a product release with no unit changed still closes it, with the product version only);
#               finish the train (drop the markers, write the product version into the root package.json)
#               so its last commit is what the product tag will name; restore the config and the non-train
#               manifest entries from main; open the release PR → main. That PR is merged with
#               *squash*: the train's own release commits must not enter main's timeline, or the next
#               train's commit walk stops at them and silently drops whatever landed on main while this
#               train was stabilising.
#   close       merge that PR with a squash message this script controls, so Release-Train-Base stays the last
#               line main can read; tag vX.Y.Z on the *train's* final commit, whose tree already carries the
#               product version; delete the branches; run the close checklist against origin/main. It never
#               switches to main, which is often checked out in another worktree. The tag must sit on the
#               train, not on main's merge result: merging produces "main's current content + the train's
#               diff", which carries whatever landed on main during stabilisation and was never released.
#               A hotfix train rebuilt from that tag would drag those unreleased changes into a patch.
#
# usage: finalize-release.sh --line X.Y --phase ga|merge-back|close [--yes] [--dry-run]
#
# The product version is the one in the Release-Plan trailer cut-release.sh wrote when it opened the train
# (the plan, releases/release-plan-vX.Y.Z.md, is where versions are assigned). Every release has one: a
# release that ships only libraries is still a release, and its finalize path must be identical (Snapshot,
# tag check, product Release, governance sync). merge-back copies the trailer onto main, so close still finds
# it after the train branch is gone.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
cd "$REPO_ROOT"

line="" phase="" product=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --line) line="$2"; shift 2 ;;
    --phase) phase="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; export ASSUME_YES; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,${/^#/!q; p;}' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$line" =~ ^[0-9]+\.[0-9]+$ ]] || die "--line 需為 X.Y"
branch="release/v$line"
target="$(remote_target)"
# 每次發布都有產品版號，不因入版單元的種類分流：發布就是發布，收尾流程必須一致。
# 只含程式庫時產品版號同樣往前走，Snapshot 因此完整記錄「這一版由哪些單元組成」（ADR-001）。
# 版號來自開線 commit 的 Release-Plan trailer，要在各階段抓完遠端之後才讀。
resolve_product() {
  product="$(train_plan_version "$line")" || die "找不到 $branch 的 Release-Plan trailer：這條分支不是用 cut-release.sh --plan 開的，main 上也沒有這條產品線的紀錄"
  product="${product#v}"
  [[ "$product" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Release-Plan trailer 的版號需為 vX.Y.Z（目前 v${product}）"
}

case "$phase" in
  ga)
    require_clean_tree
    [[ "$(current_branch)" == "$branch" ]] || die "請在 $branch 上執行（目前 $(current_branch)）"
    # Sync before the gates: they read the remote too (the base gate needs the line's latest product
    # tag, the scripts gate compares against origin/main). Merging a stale ref and then fetching would
    # compare an old local train against a fresh main.
    train_sync "$branch"
    resolve_product
    train_gates "$branch" "$line" ga
    # 累積集的 fact-kit 閘：不先 pin，每一列都要已經釘在實際發過的版號。累積集是發布分支 manifest 對
    # main 的差異，版號取發布分支 manifest 的現行版號（rc.N）。失敗要在任何推送、也在寫 Release-As 之前結束。
    if has_facts; then
      log "GA 閘（fact-kit）：累積集的 next 都要已釘在發過的版號"
      declare -a ga_train=()
      while IFS= read -r u; do
        [[ -n "$u" ]] && ga_train+=("$u=$(manifest_version "$(unit_path "$u")")")
      done < <(train_units_by_manifest)
      facts_train_check ${ga_train[@]+"${ga_train[@]}"} \
        || die "GA 閘未通過：fact-kit check --train 在上面列出的 <檔案>:<行> 還有沒釘版的 next。先用 merge-release-pr.sh 合進 rc 的修補，或把那一列標成 pending，再重跑 --phase ga。沒有任何東西被推送"
    else
      info "⊘ 沒有 facts/，略過 fact-kit 閘"
    fi
    log "收斂 prerelease：各單元以自身版號定案（產品版號 v${product}）"
    train_release_ga "$branch"
    tmp="$(mktemp)"
    jq '.packages |= map_values(if .versioning == "prerelease" then .prerelease = false else . end)' "$CONFIG" > "$tmp"
    # 重跑 GA（前一次在合併 Release PR 之後失敗）時設定已是非 prerelease，無條件 commit 會因無變更而中止
    if (( DRY_RUN )); then rm -f "$tmp"; else
      mv "$tmp" "$CONFIG"; git add "$CONFIG"
      if git diff --cached --quiet -- "$CONFIG"; then info "⊘ 設定已離開 prerelease 模式"
      else git commit -q -m "chore($branch): leave prerelease mode" -m "Release-Train-Stage: ga"; fi
    fi
    external "$target" git push origin "$branch"
    printf '\n'
    info "下一步：scripts/release/merge-release-pr.sh --line $line 合併 Release PR → 各單元正式 tag → production（tag 白名單）。"
    info "之後執行：finalize-release.sh --line $line --phase merge-back"
    ;;

  merge-back)
    require_clean_tree
    [[ "$(current_branch)" == "$branch" ]] || die "請在 $branch 上執行"
    run git fetch --prune --tags origin
    run git merge --ff-only "origin/$branch"
    resolve_product
    declare -a units=()
    while IFS= read -r u; do [[ -n "$u" ]] && units+=("$u"); done < <(train_units_by_manifest)
    # 沒有單元升版的發布線照常收尾：產品版號寫進發布分支、合回 main，close 再打產品 tag。參與一次產品發布
    # 但這次沒有單元變動的倉（例如只放 plan 的 hub）就是這種線。
    (( ${#units[@]} )) || info "本分支與 main 的 manifest 無差異：這條線沒有單元升版，只發產品 v${product}"
    declare -a paths=() missing=()
    for u in ${units[@]+"${units[@]}"}; do
      p="$(unit_path "$u")"; paths+=("$p")
      v="$(manifest_version "$p")"
      [[ "$v" == *-* ]] && { missing+=("$u 仍是 prerelease $v"); continue; }
      git rev-parse -q --verify "refs/tags/$u/v$v" >/dev/null || missing+=("$u/v$v")
    done
    (( ${#missing[@]} == 0 )) || die "GA 尚未完成：${missing[*]}（先合併 Release PR 並等 tag 建立）"

    # 發布分支的最後一個 commit 就是產品 tag 的位置，它的樹要等於實際發布的內容，所以在這裡把發布分支
    # 整理成最終樣子，再算合回差異：
    #   - 標記檔只為了讓 GA 的 Release-As commit 觸及單元路徑而存在，任務已完成。刪掉後「建立又刪除」
    #     的淨差異為零，main 永遠看不到它們，也消掉本檔第 18 項提到的一個衝突來源。
    #   - 產品版號寫進根目錄 package.json，產品 tag 的樹因此帶著自己的版號，合回差異也一併帶到 main。
    # 這個 commit 只含 chore、不帶 Release-As，沒有版號要算。刪標記檔會碰到單元路徑而觸發 release-please.yml，
    # 它的 job 認得這則 commit 訊息（chore(<發布分支>): product v）而跳過，因為合回 PR 合併後發布分支就被刪掉，
    # 排隊較久的 run 開跑時會讀不到分支。訊息格式改動時，release-please.yml 的 if 要一起改。
    # 任何深度的標記檔都要刪：單元路徑可以是一層（facts 匯總套件）也可以是兩層（apps/product-web）
    declare -a markers=()
    while IFS= read -r m; do [[ -n "$m" ]] && markers+=("$m"); done < <(git ls-files -- ':(glob)**/.release-marker')
    if (( ${#markers[@]} )); then run git rm -q --ignore-unmatch -- "${markers[@]}"; fi
    log "產品 marker → ${product}（發布分支的 root package.json）"
    if (( DRY_RUN )); then info "[dry-run] jq .version=$product package.json"; else
      tmp="$(mktemp)"; jq --arg v "$product" '.version = $v' package.json > "$tmp" && mv "$tmp" package.json
    fi
    run git add package.json
    if ! git diff --cached --quiet; then
      run git commit -q -m "chore($branch): product v$product"
      external "$target" git push origin "$branch"
    else
      info "⊘ 發布分支已是最終樣子（標記檔已刪、產品版號已寫入）"
    fi

    # 發布分支的基底不一定在 main 上：squash 合回讓上一次發布的 tip 不是 main 的祖先，因此自產品 tag
    # 重建的修補發布與 main 沒有近共同祖先，直接合併會讓版號檔、CHANGELOG 全數衝突。改為在 main 之上
    # 套用發布分支的差異，合回因此永遠是一次乾淨的單一 commit。
    # 只套 main 還沒有的 commit，不套「基底 → 最後一個 commit」整段：修補發布的修正常先進 main 再
    # cherry-pick 進發布分支，自 tag 重建時開分支的 commit 也同步了 main 的 scripts/。整段套用會把這些
    # 變更重套一次，已刪的檔報錯、改過的檔衝突（promptex 1.0.1 實際遇到）。開分支的 commit 一律不套，
    # 它改的設定與 manifest 不進 main，manifest 由下一步另外合併。
    train_base="$(git log "$branch" --format='%(trailers:key=Release-Train-Base,valueonly)' | grep -m1 -E '^[0-9a-f]{7,40}$' || true)"
    [[ -n "$train_base" ]] || die "$branch 上找不到 Release-Train-Base trailer，無法決定差異範圍"
    pending_list="$(train_commits_not_on_main "origin/$branch")" || die "無法列出 $branch 上 main 還沒有的 commit"
    declare -a pending=()
    while IFS= read -r c; do [[ -n "$c" ]] && pending+=("${c%% *}"); done <<< "$pending_list"
    sync_branch="${branch}--to-main"
    log "在 main 之上建立合回分支 ${sync_branch}（套用發布分支上 main 還沒有的 ${#pending[@]} 個 commit）"
    run git switch -C "$sync_branch" origin/main
    for c in "${pending[@]}"; do
      if (( DRY_RUN )); then info "[dry-run] 套用 $(git log -1 --format='%h %s' "$c")"; continue; fi
      # 失敗多半是 apply 留下衝突。有 facts/ 時交給 fact-kit merge-since 解只差 since 的衝突；其他差異、
      # 非衝突的失敗與沒有 facts/ 的倉庫都在這裡停下。每次重跑都從 origin/main 重建合回分支，手動解的不會保留。
      if ! git diff "$c^" "$c" -- . ':!release-please-config.json' | git apply --3way --allow-empty; then
        facts_settle_since_conflicts "$(git log -1 --format='%h %s' "$c")"
      fi
    done

    log "以 main 的 manifest 為底，只保留 train 單元版號：${units[*]:-（無）}"
    if (( DRY_RUN )); then info "[dry-run] merge $MANIFEST with origin/main"; else
      keep="$(jq -nc '$ARGS.positional' --args ${paths[@]+"${paths[@]}"})"
      tmp="$(mktemp)"
      jq -s --argjson keep "$keep" '.[0] * (.[1] | with_entries(select(.key as $k | $keep | index($k))))' \
        <(git show origin/main:"$MANIFEST") <(git show "origin/$branch:$MANIFEST") > "$tmp" && mv "$tmp" "$MANIFEST"
      jq -c . "$MANIFEST"
    fi
    run git add -A
    title="chore(release): product v$product → main"
    if [[ -n "$(git diff --cached --name-only)" ]]; then
      run git commit -q -m "$title" -m "自 $branch 套用發布內容；發布分支自身的發版 commit 不進主線。

Release-Train-Base: $train_base
Release-Plan: v$product"
    else
      info "合回內容已存在，略過提交"
    fi
    external "$target" git push -f origin "$sync_branch"

    # Release-Train-Base 必須寫在 PR body 裡：release PR 以 squash 合併，GitHub 取 PR 標題加
    # 內文作為 commit 訊息，合回分支上那個 commit 的訊息會整個被丟棄。放錯位置的後果是
    # last-release-sha 永遠設不起來，下一次發布回溯整條歷史而把已發布的變更重新計入
    # （實測 2026-09-10：api 應連動升 patch 到 1.1.1，實際跳到 1.2.0）。git 只認最後一個
    # 段落的 trailer，附在 body 結尾即可解析。
    # 內文照 docs/git-flow.md「commit 與 PR 訊息格式」的四段。最後一段的關閉關鍵字寫成 "Closes: #N"：
    # 沒有冒號的 "Closes #N" 不是 git trailer，和 Release-Train-Base 同段時會讓 git 整段都不當 trailer
    # 解析（2026-10-01 以 git interpret-trailers 實測）。GitHub 接受關鍵字後面加冒號。
    refs="$(git log "${train_base}..origin/${branch}" --format=%B | grep -oE 'Refs:? #[0-9]+' | grep -oE '[0-9]+' | sort -nu | sed 's/^/Closes: #/' || true)"
    if [[ -n "$refs" ]]; then hotfix_note="集中關閉發布期間 hotfix 的 Issue，列在最後一段。"
    else hotfix_note="這次發布沒有 hotfix Issue。"; fi
    body="$(cat <<BODY
## 動機
${product:+v$product }的單元 tag 都已建立，把發布分支 $branch 的內容套回 main。發布分支自身的發版 commit 不進 main，所以以 squash 合併。

## 變更
- 自 $branch 套用發布內容：入版單元的版號檔、CHANGELOG、manifest 與 root package.json 的產品版號
- 入版單元與 tag：

$(bash scripts/release/snapshot.sh ${product:+--product "$product"} --check-tags)

## 影響
- main 的版號檔與 CHANGELOG 前進到這次發布，非入版單元的版號不變。
- 合併後${product:+在發布分支的最後一個 commit 打 \`v$product\`，}刪除 ${branch}。
- $hotfix_note

## 驗證
- 上表是 \`snapshot.sh --check-tags\` 的輸出，tag 欄的 ✓ 表示該 tag 已存在。
- 合併前等這個 PR 的 checks 全數通過。

${refs:+$refs
}Release-Train-Base: $train_base
Release-Plan: v$product
BODY
)"
    existing="$(gh pr list --base main --head "$sync_branch" --state open --json number --jq '.[0].number // empty')"
    if [[ -n "$existing" ]]; then
      info "release PR #$existing 已存在，更新內文"
      external "$target" gh pr edit "$existing" --title "$title" --body "$body"
    else
      external "$target" gh pr create --base main --head "$sync_branch" --title "$title" --body "$body"
    fi
    printf '\n'
    info "下一步：CI 通過後執行 finalize-release.sh --line $line --phase close，它會以 squash 合併該 PR"
    ;;

  close)
    # 收尾只讀 origin/main，不切到 main：main 常在另一個 worktree 被檢出，切換會失敗。試跑與正式執行
    # 走同一套核對，差別只在對外寫入是否執行。
    require_clean_tree
    run git fetch --prune --tags origin
    resolve_product
    sync_branch="${branch}--to-main"
    title="chore(release): product v$product → main"

    # 1. 合併 release PR。合併訊息由這裡指定：GitHub 預設的 squash 訊息會在 PR 內文後面接上各 commit 的
    #    標題，Release-Train-Base 就不在最後一段，git 讀不成 trailer（v0.5.0 實際發生，見待辦 i030）。
    pr="$(gh pr list --base main --head "$sync_branch" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)"
    if [[ -n "$pr" ]]; then
      body="$(gh pr view "$pr" --json body --jq .body)"
      log "以 squash 合併 release PR #${pr}，合併訊息為 PR 標題與內文，Release-Train-Base 在最後一行"
      external_retry "$target" gh pr merge "$pr" --squash --subject "$title (#$pr)" --body "$body"
      run git fetch --prune --tags origin
    fi
    if [[ -z "$(git log origin/main --format=%H --grep="product v$product" -n 1)" ]]; then
      (( DRY_RUN )) && [[ -n "$pr" ]] && info "[dry-run] release PR #$pr 尚未合併，以下核對僅供參考" \
        || die "main 上找不到 release PR 合併後的 commit（先執行 merge-back，CI 通過後再執行 close）"
    fi

    # 2. main 帶著這次發布的起算點，也就是發布分支的 Release-Train-Base。只找「任何一個」會被上一次發布的
    #    trailer 騙過。PR 若被手動以預設訊息合併，補一個只帶 trailer 的空 commit。
    train_ref="origin/$branch"
    git rev-parse -q --verify "refs/remotes/$train_ref" >/dev/null || train_ref="v$product"
    base="$(git log "$train_ref" --format='%(trailers:key=Release-Train-Base,valueonly)' 2>/dev/null | grep -m1 -E '^[0-9a-f]{7,40}$' || true)"
    [[ -n "$base" ]] || die "$train_ref 上讀不到 Release-Train-Base，無法核對 main 的起算點"
    # 先存成字串再比對：pipefail 之下，grep -q 提早結束會讓 git log 收到 SIGPIPE，整條管線被判為失敗。
    main_has_base() { grep -qx "$base" <<<"$(git log origin/main -n 20 --format='%(trailers:key=Release-Train-Base,valueonly)')"; }
    if ! main_has_base; then
      log "main 讀不到這次的 Release-Train-Base ${base:0:7}，補一個只帶 trailer 的 commit"
      if (( DRY_RUN == 0 )); then
        fix="$(git commit-tree "origin/main^{tree}" -p origin/main \
          -m "chore(release): 記錄 v$product 的 Release-Train-Base" \
          -m "合回 main 的訊息裡讀不到這一行，這裡補上，讓下次切 train 找得到起算點。" \
          -m "Release-Train-Base: $base
Release-Plan: v$product")"
        external "$target" git push origin "$fix:refs/heads/main"
        run git fetch origin
      else
        info "[dry-run] 補上 Release-Train-Base: $base"
      fi
    fi

    # 3. 產品 tag 打在發布分支的最後一個 commit，樹裡的產品版號要等於產品版號（merge-back 已寫入）。
    #    tag 已建立時不再需要分支（重跑 close 的情形）。
    if git rev-parse -q --verify "refs/tags/v$product" >/dev/null; then
      train_tip="$(git rev-list -n1 "v$product")"
    else
      git rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null \
        || die "找不到 origin/${branch}：產品 tag 需打在發布分支的最後一個 commit，請在刪除分支前執行 close"
      train_tip="$(git rev-parse "origin/$branch")"
    fi
    tip_version="$(git show "$train_tip:package.json" | jq -r .version)"
    [[ "$tip_version" == "$product" ]] \
      || die "發布分支最後一個 commit 的產品版號是 ${tip_version}，不是 ${product}：先執行 merge-back 寫入產品版號"
    if git rev-parse -q --verify "refs/tags/v$product" >/dev/null; then
      info "v$product 已存在且指向發布分支的最後一個 commit ${train_tip:0:7}，略過建立"
    else
      log "打產品 tag v$product 於發布分支的最後一個 commit ${train_tip:0:7}"
      run git tag -a "v$product" "$train_tip" -m "product v$product"
    fi
    if [[ -z "$(git ls-remote --tags origin "refs/tags/v$product")" ]]; then
      external "$target" git push origin "v$product"
    else
      info "v$product 已在遠端"
    fi

    # 4. 刪除發布分支與流程產生的暫時分支（不變式：兩次發布之間 0 條）。本機分支正被檢出時先切離。
    log "刪除 release 分支與暫時分支"
    for extra in "$branch" "release-please--branches--$branch" "$sync_branch"; do
      if [[ -n "$(git ls-remote --heads origin "refs/heads/$extra")" ]]; then
        external "$target" git push origin --delete "$extra"
      fi
    done
    [[ "$(current_branch)" == "$branch" || "$(current_branch)" == "$sync_branch" ]] && run git switch -q --detach origin/main
    for local_branch in "$branch" "$sync_branch"; do
      git rev-parse -q --verify "refs/heads/$local_branch" >/dev/null && run git branch -D "$local_branch"
    done
    run git fetch --prune --tags origin

    # 5. 關閉核對，全部讀遠端與 origin/main。
    printf '\n'
    log "關閉核對清單"
    ok=1
    n="$(release_branches | grep -c . || true)"
    [[ "$n" == 0 ]] && info "✓ release 分支數 = 0" || { info "✗ 仍有 release 分支：$(release_branches)"; ok=0; }
    leftover="$(git ls-remote --heads origin 'refs/heads/release-please--*' | wc -l | tr -d ' ')"
    [[ "$leftover" == 0 ]] && info "✓ 無殘留的 release-please 工作分支" || { info "✗ 仍有 $leftover 條 release-please 工作分支"; ok=0; }
    if git rev-parse -q --verify "refs/tags/v$product" >/dev/null; then
      [[ "$(git show "v$product:package.json" | jq -r .version)" == "$product" ]] \
        && info "✓ v${product}，樹裡的產品版號為 ${product}" || { info "✗ v$product 的樹裡產品版號不是 $product"; ok=0; }
    else
      info "✗ product tag 缺"; ok=0
    fi
    [[ "$(git show origin/main:package.json | jq -r .version)" == "$product" ]] && info "✓ main 的產品 marker 為 $product" || { info "✗ main 的 root package.json ≠ $product"; ok=0; }
    # 同類無聲失效已踩過多次（ADR-004 第 28、31 項）：步驟回報成功但實際沒生效。
    main_has_base && info "✓ main 已帶這次的 Release-Train-Base ${base:0:7}" || { info "✗ main 上找不到這次的 Release-Train-Base ${base:0:7}，下一次發布會用錯起算點"; ok=0; }
    # 任一階段（alpha、beta、rc）的版號都帶 "-"，判斷 "-" 而不是某個階段名
    git show "origin/main:$MANIFEST" | jq -e 'any(.[]; test("-"))' >/dev/null && { info "✗ main manifest 仍含 prerelease 版號"; ok=0; } || info "✓ main manifest 無 prerelease 版號"
    git show "origin/main:$CONFIG" | jq -e '[.versioning, (.packages[]? | .versioning)] | any(. != null)' >/dev/null 2>&1 && { info "✗ main 的 $CONFIG 仍帶發布分支的階段設定"; ok=0; } || info "✓ main 設定為正式模式且涵蓋全部單元"
    info "Snapshot、Issue 關閉核對與部署記錄由 release-line-finalize workflow 產出"
    if (( DRY_RUN )); then log "試跑完成：以上核對反映執行前的狀態"
    elif (( ok )); then log "verified：$branch 已關閉"
    else die "關閉核對未全過，補齊後重跑 --phase close"; fi
    ;;
  *) die "--phase 需為 ga|merge-back|close" ;;
esac
