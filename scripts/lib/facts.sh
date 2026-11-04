#!/usr/bin/env bash
# fact-kit steps of the release scripts: which component package describes which release-please unit,
# pinning "next" rows, the --train check, and settling "since" conflicts. Source it through common.sh; do
# not execute. A repository without facts/fact-kit.config.json has none of this, and every function here
# is a no-op or reports "no facts" so the scripts run unchanged.

has_facts() { [[ -f "$REPO_ROOT/facts/fact-kit.config.json" ]]; }

# fact-kit comes from the facts workspace package. pnpm -C changes the working directory, so every path
# passed to it must be absolute.
fact_kit() { pnpm -C "$REPO_ROOT/facts" exec fact-kit "$@"; }

# facts_package_dir <package name> → the directory under facts/ whose package.json carries that name
facts_package_dir() {
  local f
  for f in "$REPO_ROOT"/facts/*/package.json; do
    [[ -f "$f" ]] || continue
    if [[ "$(jq -r '.name // empty' "$f")" == "$1" ]]; then dirname "$f"; return 0; fi
  done
  return 1
}

# facts_components → "<dir>\t<unit>" per component package that describes one release-please unit,
# read from the "describes" key of the package's built index. The aggregate itself, a package whose
# "describes" is {} (the template's spec) and a unit without a component package never appear.
# Builds each package first so the answer follows the sources on this branch.
facts_components() {
  has_facts || return 0
  local pkg dir f c out
  while IFS= read -r pkg; do
    dir="$(facts_package_dir "$pkg")" || { warn "facts/fact-kit.config.json 的 aggregate 列了 ${pkg}，但 facts/ 底下找不到這個套件"; continue; }
    out="$(fact_kit build --cwd "$dir" 2>&1)" || { printf '%s\n' "$out" >&2; die "建置 ${dir#"$REPO_ROOT"/} 失敗（facts 的依賴裝了嗎？先在倉庫根目錄執行 pnpm install）"; }
    for f in "$dir"/dist/*/index.json; do
      [[ -f "$f" ]] || continue
      while IFS= read -r c; do
        [[ -n "$c" ]] && printf '%s\t%s\n' "$dir" "$c"
      done < <(jq -r '.describes // {} | keys[]' "$f")
    done
  done < <(jq -r '.aggregate // {} | to_entries[] | .value' "$REPO_ROOT/facts/fact-kit.config.json")
}

# facts_pin <unit> <version>: turn the "next" rows of the unit's component packages into <version>.
# Prints nothing; the caller looks at git status.
facts_pin() {
  local dir unit comps
  comps="$(facts_components)"
  while IFS=$'\t' read -r dir unit; do
    [[ "$unit" == "$1" ]] || continue
    info "pin $unit → ${2}（${dir#"$REPO_ROOT"/}）"
    fact_kit pin --version "$2" --cwd "$dir" >/dev/null || die "fact-kit pin 失敗：$dir"
  done <<<"$comps"
}

# facts_locate_problems <package dir> <check output>: fact-kit reports a row by id and JSON pointer, so find
# the line of that row in the sources and print it as <file>:<line>. The id is searched whole first, then by
# its last segment (the name a factsOf helper adds the tool and prefix to).
facts_locate_problems() {
  local dir="$1" id hit
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    hit="$(grep -rnF --include='*.ts' --exclude-dir=node_modules --exclude-dir=dist "'$id'" "$dir/facts" | head -1 || true)"
    [[ -n "$hit" ]] || hit="$(grep -rnF --include='*.ts' --exclude-dir=node_modules --exclude-dir=dist "'${id##*.}'" "$dir/facts" | head -1 || true)"
    [[ -n "$hit" ]] || continue
    hit="${hit#"$REPO_ROOT"/}"
    printf '%s\n' "  → ${id}：$(cut -d: -f1,2 <<<"$hit")" >&2
  done < <(sed -nE 's/^[a-z-]+: ([^ :]+): .*/\1/p' <<<"$2")
}

# facts_train_check <unit>=<version>... → runs `fact-kit check --train` for the component packages that
# describe those units. Prints the problems (each with its <file>:<line>) and returns 1 on any. A
# repository without facts, or no component package for the units, passes.
facts_train_check() {
  has_facts || { info "⊘ 沒有 facts/，略過 fact-kit check"; return 0; }
  local pair unit dir u failed=0 out
  local -a train=() dirs=()
  local -A seen=()
  local comps; comps="$(facts_components)"
  for pair in "$@"; do
    unit="${pair%%=*}"
    while IFS=$'\t' read -r dir u; do
      [[ "$u" == "$unit" ]] || continue
      train+=(--train "$pair")
      [[ -n "${seen[$dir]:-}" ]] || { seen[$dir]=1; dirs+=("$dir"); }
    done <<<"$comps"
  done
  (( ${#dirs[@]} )) || { info "⊘ 這次的單元沒有對應的 component 套件，略過 fact-kit check"; return 0; }
  for dir in "${dirs[@]}"; do
    if out="$(fact_kit check --cwd "$dir" "${train[@]}" 2>&1)"; then
      info "✓ fact-kit check ${dir#"$REPO_ROOT"/}（${train[*]}）"
    else
      printf '%s\n' "$out" >&2
      facts_locate_problems "$dir" "$out"
      failed=1
    fi
  done
  return "$failed"
}

# facts_settle_since_conflicts: after a failed `git apply --3way`, let fact-kit merge-since settle the
# conflicts that differ only in "since", then stage everything so the next patch applies on top. Runs from
# the repository root and without --cwd facts, so a conflict outside facts/ is listed too and stops it.
# Dies, with the <file>:<line> merge-since printed, when anything is left.
facts_settle_since_conflicts() { # facts_settle_since_conflicts <description of the commit>
  local out left
  has_facts || die "套用 $1 時衝突，請手動處理後再執行本階段"
  if ! out="$(fact_kit merge-since --cwd "$REPO_ROOT" 2>&1)"; then
    printf '%s\n' "$out" >&2
    die "套用 $1 時有 fact-kit merge-since 解不開的衝突（上面是 <檔案>:<行>），請手動處理後再執行本階段"
  fi
  # merge-since 不 stage 解完的檔，索引裡仍是 unmerged，所以不能只看 --diff-filter=U 是否為空；
  # 改看這些檔裡還有沒有衝突標記，有就停下並印出 <檔案>:<行>
  left="$(git diff -z --name-only --diff-filter=U | while IFS= read -r -d '' f; do grep -nE -e '^(<<<<<<<|>>>>>>>)' -- "$f" | sed "s#^#$f:#"; done || true)"
  [[ -z "$left" ]] || { printf '%s\n' "$left" >&2; die "套用 $1 時 merge-since 回報完成，但以上位置仍有衝突標記，請手動處理後再執行本階段"; }
  info "✓ fact-kit merge-since 解掉 since 衝突：$1"
  git add -A
}
