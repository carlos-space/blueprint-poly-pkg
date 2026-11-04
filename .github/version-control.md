# 版控流程範本

導入版控流程時，下表的檔案隨 base 範本組進倉庫。每個檔案都是起點，依倉庫的設定調整佔位符 `{...}`。

| 檔案 | 用途 |
| :--- | :--- |
| `.github/PULL_REQUEST_TEMPLATE.md` | PR 內文的動機、變更、影響、驗證四段，最後一段放關聯 trailer。squash 後 PR 內文就是 commit 內文，所以和 commit 訊息同一份格式 |
| `.github/ISSUE_TEMPLATE/*.yml` | bug、feature、hotfix 三種 Issue |
| `releases/release-plan.md` | 一版一份的發布規劃範本，複製成主檔的 `releases/release-plan-v{X.Y.Z}.md`。維護型發布規劃由 `scripts/release/plan.sh maintenance` 寫出，不從這份範本複製 |
| `.github/CODEOWNERS.example` | 複製成 `.github/CODEOWNERS`，列出版號與發布相關檔案的審查者。`scripts/hooks/pre-push` 也讀它，推上 main 的變更碰到這些路徑時擋下，改走 PR |
| `scripts/hooks/commit-msg`、`scripts/hooks/pre-push` | 訊息格式與 AI 平台署名的檢查，推送預設分支前再查一次推送範圍的訊息並跑建置測試。由 `scripts/setup/git-hooks.sh` 設定 `core.hooksPath`，使用者在自己的終端機執行（代理執行會被權限規則擋下） |
| `.github/workflows/main-commit-check.yml` | 每天核對預設分支前一天的 commit 訊息格式與 AI 平台署名，呼叫 `scripts/ci/check-main-commits.sh` |
| `.github/workflows/pr-message.yml` | PR 標題與內文的同一組檢查，squash 後標題與內文就是 commit 訊息 |
| `scripts/setup/github-repo-settings.sh`、`scripts/setup/github-repo-settings.json` | 把倉庫鎖定成只允許 squash 合併、合併後刪分支，並設定 Actions 產物與 log 的保留天數。值寫在旁邊的 JSON。可以一次指定多個倉。`--dry-run` 只印要送的請求，套用前先讀現值，已相同的設定不送 |

訊息檢查的腳本在 `scripts/ci/`：`check-pr-title.sh`、`check-commit-body.sh`、`check-main-commits.sh` 與 `ai-attribution-list.txt`。

`pre-push` 檢查推上 main 的 commit：訊息格式與 AI 平台署名、每個 commit 只動一個發布單元、不碰 `.github/CODEOWNERS` 列的治理路徑、沒有破壞性變更，通過後跑 `scripts/ci/run-affected.sh` 的 lint、build、test。`core.hooksPath` 寫相對路徑時，在 linked worktree 裡會指到那個 worktree 底下的 `scripts/hooks/`。

每日核對 workflow 的 runner 讀倉庫變數 `LINUX_RUNNER`，沒設時用 self-hosted 的 `self-hosted-linux`。改用其他 runner 時，只要有 git 與 bash 4 就能跑。倉庫沒有 self-hosted runner 時，把 `LINUX_RUNNER` 設成 `ubuntu-latest`。

Issue 與 PR 範本取自 git-flow-template，label 與分支前綴是它的預設值，倉庫的設定不同時照設定替換。PR 範本的 `Closes #N` 依目標分支換關鍵字，目標是發布分支（hotfix）時寫 `Refs #N`。
