#!/usr/bin/env bash
# Shared helpers for release / scenario scripts. Source it; do not execute.
#   DRY_RUN=1     print every mutating command instead of running it
#   ASSUME_YES=1  skip the interactive confirmation for external writes (CI / scenario --yes)
#   TASK_DIR      where external-ops.log lives (default tmp/<today>-git-flow-sim)
# A script that skipped any external write (declined, or no terminal to answer the prompt) lists the
# skipped writes and exits 3 even when everything else succeeded, outside DRY_RUN.
set -euo pipefail

# mapfile and associative arrays are bash 4; macOS still ships 3.2 as /bin/bash, so say so plainly
# rather than failing later with a confusing parse error.
if (( BASH_VERSINFO[0] < 4 )); then
  printf '%s\n' "✗ 需要 bash 4 以上（目前 ${BASH_VERSION}）；macOS 內建的 /bin/bash 是 3.2，請以 brew install bash 安裝後再跑" >&2
  exit 1
fi

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
TASK_DIR="${TASK_DIR:-$REPO_ROOT/tmp/$(date +%Y-%m-%d)-git-flow-sim}"
AUDIT_LOG="$TASK_DIR/external-ops.log"
CONFIG="release-please-config.json"
MANIFEST=".release-please-manifest.json"

log()  { printf '%s\n' "→ $*"; }
info() { printf '%s\n' "  $*"; }
warn() { printf '%s\n' "! $*" >&2; }
die()  { printf '%s\n' "✗ $*" >&2; exit 1; }

# bash has no array-membership operator, and open-coding the loop at each call site is where
# unquoted-expansion bugs creep in, so every membership test goes through this one helper.
in_array() { # in_array <needle> <haystack>...
  local needle="$1"; shift
  local item
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

# run a local (reversible) command; printed only under DRY_RUN
run() {
  if (( DRY_RUN )); then printf '%s\n' "  [dry-run] $*"; else printf '%s\n' "  \$ $*"; "$@"; fi
}

# external write gate (execute-external per external-operation-guard): returns 0 to proceed
confirm_external() {
  local target="$1" op="$2"
  printf '%s\n' "外部寫入（execute-external）：$op → $target"
  if (( DRY_RUN )); then printf '%s\n' "  [dry-run] 不執行"; return 1; fi
  if (( ASSUME_YES )); then printf '%s\n' "  ASSUME_YES=1，視為已確認"; return 0; fi
  local reply
  read -r -n1 -p "  確認執行？[y/N] " reply || true
  printf '\n'
  [[ "$reply" == "y" ]]
}

# audit <target> <op> <result> — one line, four pipe-delimited fields.
# The operation text is flattened and truncated: PR bodies carry newlines and "|" (markdown tables),
# which would otherwise break the one-record-per-line format and make the log unparsable.
audit() {
  local op="${2//$'\n'/ ⏎ }"
  op="${op//|/／}"
  (( ${#op} > 300 )) && op="${op:0:300}…"
  mkdir -p "$TASK_DIR"
  printf '%s\n' "$(date '+%Y-%m-%d %H:%M') | $1 | $op | $3" >> "$AUDIT_LOG"
}

# A declined write returns 0 so the script runs to the end, but a run that skipped a push and exited 0
# reads as "pushed": a caller without a terminal (an agent, CI without --yes) declines every prompt
# silently. So skipped writes are collected and the exit trap reports them and turns the status into 3.
SKIPPED_EXTERNAL=()
skip_external() { # skip_external <target> <op>
  SKIPPED_EXTERNAL+=("$1：$2")
  log "跳過：$2"
}
report_skipped_external() {
  local rc=$? op
  (( DRY_RUN == 0 && ${#SKIPPED_EXTERNAL[@]} )) || return "$rc"
  printf '\n%s\n' "✗ 有 ${#SKIPPED_EXTERNAL[@]} 個外部寫入沒有執行，遠端還沒有這些變更：" >&2
  for op in "${SKIPPED_EXTERNAL[@]}"; do printf '%s\n' "  - $op" >&2; done
  printf '%s\n' "  確認後帶 --yes 重跑，或手動執行上面的指令" >&2
  (( rc == 0 )) && exit 3
  return "$rc"
}
trap report_skipped_external EXIT

# external command wrapped with confirmation + audit: external <target> <cmd...>
external() {
  local target="$1"; shift
  if confirm_external "$target" "$*"; then
    if "$@"; then audit "$target" "$*" success; else audit "$target" "$*" failure; return 1; fi
  else
    skip_external "$target" "$*"
    return 0
  fi
}

# Same gate as external(), but retries the command a few times. GitHub rejects a merge with
# "Base branch was modified" when the base moved between the PR being opened and merged, which
# happens routinely here: a staging deploy writes the ops declaration back to main while a feature
# PR is in flight. The merge itself is safe to repeat, so retry rather than abort the run.
external_retry() { # external_retry <target> <cmd>...
  local target="$1"; shift
  local i
  if ! confirm_external "$target" "$*"; then skip_external "$target" "$*"; return 0; fi
  for i in 1 2 3 4 5; do
    if "$@"; then audit "$target" "$*" success; return 0; fi
    (( i < 5 )) && { warn "第 $i 次失敗，5 秒後重試（基底分支可能剛被回寫）"; sleep 5; }
  done
  audit "$target" "$*" failure
  return 1
}

remote_target() { git remote get-url origin 2>/dev/null | sed -E 's#(git@|https://)([^/:]+)[:/]#\2/#; s#\.git$##; s#^[^@]+@##'; }

require_clean_tree() {
  [[ -z "$(git status --porcelain)" ]] && return 0
  if (( DRY_RUN )); then warn "工作區不乾淨（dry-run 下僅警告）"; return 0; fi
  die "工作區不乾淨，先 commit 或 stash"
}

current_branch() { git branch --show-current; }

release_branches() { git branch -r --list 'origin/release/*' | sed 's#.*origin/##'; }

unit_path() { # unit_path product-web -> apps/product-web; a config entry whose component differs from its folder wins
  local u="$1" p
  p="$(jq -r --arg u "$u" '.packages | to_entries[] | select(.value.component == $u) | .key' "$CONFIG" 2>/dev/null | head -1)"
  if [[ -n "$p" && -d "$p" ]]; then printf '%s\n' "$p"
  elif [[ -d "apps/$u" ]]; then printf '%s\n' "apps/$u"
  elif [[ -d "packages/$u" ]]; then printf '%s\n' "packages/$u"
  elif [[ -d "libs/$u" ]]; then printf '%s\n' "libs/$u"
  else return 1; fi
}

unit_component() { # unit_component packages/cli -> mainflow; the folder name when the config sets no component
  local p="${1%/}" c
  c="$(jq -r --arg p "$p" '.packages[$p].component // empty' "$CONFIG" 2>/dev/null)"
  printf '%s\n' "${c:-${p##*/}}"
}

# whether the unit has shipped before: release-please only applies its versioning strategy on top of a
# previous release; without one it takes initial-version verbatim (1.0.0 when unset).
# The answer comes from the tags on origin, not the local ones: fetching tags never deletes a tag that was
# removed on the remote, so a local tag can outlive the release it stood for. When ls-remote fails (network,
# permission, credentials) the script stops and prints git's error; "no tag" must never be a guess.
# Call it in the shell itself, not in $(...), so the stop ends the script.
unit_released() {
  local out
  out="$(git ls-remote --tags origin "refs/tags/$1/v*" 2>&1)" \
    || die "查遠端 tag 失敗，無法判斷 $1 發過版沒有（git ls-remote --tags origin）：$out"
  [[ -n "$out" ]]
}

manifest_version() { jq -r --arg p "$1" '.[$p] // empty' "$MANIFEST"; }

# strip a prerelease suffix: 1.2.0-rc.3 → 1.2.0
stable_version() { printf '%s\n' "${1%%-*}"; }

# units listed in the config on <ref> (default: working tree), by component name when one is set
# shellcheck disable=SC2120 # <ref> is optional; most callers read the working tree
config_units() {
  local q='.packages | to_entries[] | (.value.component // (.key | split("/")[1]))'
  if [[ -n "${1:-}" ]]; then git show "$1:$CONFIG" | jq -r "$q"
  else jq -r "$q" "$CONFIG"; fi
}

# linked-versions binds a group of components to a single version, so a train shipping any member
# must carry the whole group: the plugin cannot bump components that are absent from the scoped
# config. Returns every component of every group containing one of the given units.
linked_group_members() { # linked_group_members <unit>... → component names (may be empty)
  local u
  for u in "$@"; do
    jq -r --arg u "$u" '
      (.plugins // [])[]
      | select(.type == "linked-versions")
      | select((.components // []) | index($u))
      | .components[]
    ' "$CONFIG" 2>/dev/null
  done | sort -u
  return 0
}

# Workspace dependents of the given units, transitively. release-please's node-workspace plugin can
# only bump packages that are in the config, so a train that ships a package must also carry whatever
# depends on it — otherwise the dependents keep pointing at a version that no longer matches. For the
# same reason only directories the config lists count: an unregistered package is not a unit, and
# release-please would neither bump nor tag it.
workspace_dependents() { # workspace_dependents <unit>... → dependent unit names (may be empty)
  local d u p pkgname dn
  local -a frontier=("$@") found=()
  while (( ${#frontier[@]} )); do
    u="${frontier[0]}"; frontier=("${frontier[@]:1}")
    p="$(unit_path "$u" 2>/dev/null)" || continue
    pkgname="$(jq -r '.name // empty' "$p/package.json" 2>/dev/null)"
    [[ -n "$pkgname" ]] || continue
    for d in apps/*/ packages/*/ libs/*/; do
      [[ -f "$d/package.json" ]] || continue
      jq -e --arg p "${d%/}" '.packages | has($p)' "$CONFIG" >/dev/null 2>&1 || continue
      dn="$(unit_component "$d")"
      [[ "$dn" == "$u" ]] && continue
      if jq -e --arg n "$pkgname" '((.dependencies // {}) + (.peerDependencies // {})) | has($n)' "$d/package.json" >/dev/null 2>&1; then
        in_array "$dn" "${found[@]:-}" || { found+=("$dn"); frontier+=("$dn"); }
      fi
    done
  done
  # one per line: callers split on newlines, and a space-separated list would arrive as a single
  # bogus unit name
  (( ${#found[@]} )) && printf '%s\n' "${found[@]}"
  return 0
}

# Units this train actually shipped: the manifest entries that differ from main's. Derived rather
# than read from the config, because merge-back restores the config from main and would otherwise
# lose the train scope, making the phase impossible to re-run.
train_units_by_manifest() {
  local p
  while IFS= read -r p; do [[ -n "$p" ]] && unit_component "$p"; done < <(
    jq -s -r '.[0] as $main | .[1] | to_entries[] | select(.value != $main[.key]) | .key' \
      <(git show origin/main:"$MANIFEST") "$MANIFEST")
  return 0
}

# The libraries below belong to the release template. A repository composed from the base role alone does not
# have them, so each is sourced only when present (the message checks need nothing from them).
for _lib in release-stages release-plan release-pr facts docs; do
  # release-stages: stages and the policy file; release-plan: Release Plans, the only source of product
  # versions; release-pr: waiting for and merging the Release PR; facts: fact-kit steps; docs: pinning the
  # "next" of docs/**/*.doc.ts
  if [[ -f "$(dirname "${BASH_SOURCE[0]}")/${_lib}.sh" ]]; then source "$(dirname "${BASH_SOURCE[0]}")/${_lib}.sh"; fi
done
unset _lib
