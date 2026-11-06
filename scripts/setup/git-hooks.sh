#!/usr/bin/env bash
# Point git at the repository's hooks (scripts/hooks), which guard the local lane into main. Runs from
# pnpm's prepare on every install, so a fresh clone is guarded without a separate step. A repository that
# only takes changes through PRs drops the prepare script from package.json and runs
# git config --unset core.hooksPath.
#
# Also sets commit.cleanup scissors. Messages use "## " section headings (docs/git-flow.md, commit 與 PR
# 訊息格式); when a message is written in the editor, git's default cleanup (strip) deletes every line
# starting with "#", headings included. scissors keeps them and drops only git's help text, which it
# places below a scissors line. Messages given with -m or -F are not edited and keep "#" lines either way.
# usage: git-hooks.sh
set -euo pipefail
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0   # a packed tarball has no git
git config core.hooksPath scripts/hooks
git config commit.cleanup scissors
printf '%s\n' "git hooks → scripts/hooks（commit-msg、pre-push）；commit.cleanup → scissors"
