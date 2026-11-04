#!/usr/bin/env bash
# Conventional Commits check for one title: a PR title (squash-merge makes it the releasable unit) or the
# subject of a commit entering main. The single source of the rule for ci.yml, the commit-msg and pre-push
# hooks, and the nightly history check.
# usage: check-pr-title.sh "<title>"   (exit 1 on violation)
set -euo pipefail
title="${1:?usage: check-pr-title.sh <title>}"
re='^(feat|fix|perf|refactor|docs|chore|ci|build|test|deps|revert)(\([a-z0-9./_-]+\))?!?: .+'
if [[ "$title" =~ $re ]]; then printf '%s\n' "✓ title ok: $title"; else
  printf '%s\n' >&2 "✗ title must follow Conventional Commits (<type>(<scope>): <subject>): $title"; exit 1; fi
