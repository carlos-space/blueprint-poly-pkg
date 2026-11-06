#!/usr/bin/env bash
# Release stages of a train, which stage each unit is in, and the steps that move a train between
# stages. Sourced by common.sh; do not execute.
#
# A train walks alpha → beta → rc → ga, forward only. What a stage means comes from the policy file
# release-policy.json (docs/release-policy.md), never from this script:
#   - units.<unit>.stages              the stages a unit walks when it releases on its own, ending at ga
#   - targets, units.<unit>.targets    where each stage ships: an environment, or a store channel for
#                                      mobile and desktop units. The unit's own entry wins.
#   - units.<unit>.dependsOn           same-repository dependencies the package manifests cannot express
#
# The train as a whole stands at one stage, the line stage. It starts at the earliest stage any boarded
# unit has and moves through the union of the boarded units' stages. Every unit takes its own stage from
# the line stage (train_assign_stages). The line stage is recorded in a Release-Train-Stage trailer on the
# commit that opens the train and on every commit that moves it, because it cannot be recovered from the
# units' stages: a unit that is held back or that follows a dependant can sit at a stage earlier than the
# line. It is not a config key, because release-please's config schema accepts no keys it does not know.
#
#   RELEASE_POLICY  path of the policy file (default $REPO_ROOT/release-policy.json)

RELEASE_STAGES=(alpha beta rc ga)

policy_file() { printf '%s\n' "${RELEASE_POLICY:-$REPO_ROOT/release-policy.json}"; }

policy_require() {
  [[ -f "$(policy_file)" ]] || die "找不到政策檔 $(policy_file)（格式見 docs/release-policy.md）"
}

policy_unit_exists() { policy_require; jq -e --arg u "$1" '(.units // {}) | has($u)' "$(policy_file)" >/dev/null; }

# policy_unit_stages <unit> → the stages the unit walks on its own, one per line. Stops when the policy
# does not list the unit, because a unit without a recorded cadence must not be given a guessed one.
policy_unit_stages() {
  policy_unit_exists "$1" || die "政策檔 $(policy_file) 沒有單元 $1，先為它決定階段（docs/release-policy.md）"
  jq -r --arg u "$1" '.units[$u].stages[]' "$(policy_file)"
}

policy_unit_kind() { policy_require; jq -r --arg u "$1" '.units[$u].kind // empty' "$(policy_file)"; }

# stage_target <unit> <stage> → where the unit ships <stage>. A service, backend or web unit uses its own
# target, else the shared one. A mobile or desktop unit uses its own channel only: the shared targets name
# environments, which are not store channels. Fails when there is none.
stage_target() {
  local t
  policy_require
  t="$(jq -r --arg u "$1" --arg s "$2" '
    .units[$u] as $v
    | if ($v.kind | IN("mobile", "desktop")) then $v.targets[$s] else ($v.targets[$s] // .targets[$s]) end // empty' "$(policy_file)")"
  [[ -n "$t" ]] || return 1
  printf '%s\n' "$t"
}

# stage_shared_target <stage> → the repository-wide target of <stage>; fails when there is none
stage_shared_target() {
  local t
  policy_require
  t="$(jq -r --arg s "$1" '.targets[$s] // empty' "$(policy_file)")"
  [[ -n "$t" ]] || return 1
  printf '%s\n' "$t"
}

stage_index() { # stage_index <stage> → 0-based position in RELEASE_STAGES
  local i
  for i in "${!RELEASE_STAGES[@]}"; do
    [[ "${RELEASE_STAGES[$i]}" == "$1" ]] && { printf '%s\n' "$i"; return 0; }
  done
  return 1
}

is_stage() { stage_index "$1" >/dev/null; }

# unit_registry <dir> → npm | pypi | crates, from the file the unit directory carries; fails when none.
# publish-units.sh picks the registry with this same function.
unit_registry() {
  if [[ -f "$1/package.json" ]]; then printf '%s\n' npm
  elif [[ -f "$1/pyproject.toml" ]]; then printf '%s\n' pypi
  elif [[ -f "$1/Cargo.toml" ]]; then printf '%s\n' crates
  else return 1; fi
}

# aggregate_unit → the components of the aggregate packages, one per line: the facts aggregate, the config
# entry whose path is "facts", and the document package, the entry whose path is "docs"; nothing when the
# config has neither. They board every train (cut-release.sh), because a change to a facts component package
# or a document lands in their path and release-please decides from the commits whether they release.
aggregate_unit() { jq -r '(.packages["facts"].component // empty), (.packages["docs"].component // empty)' "$CONFIG"; }

# unit_base_version <path> <line> [<config file>] → the version a unit that has never shipped counts from:
# the initial-version its config entry already carries, else the product line <X.Y>.0
unit_base_version() {
  local b
  b="$(jq -r --arg p "$1" '.packages[$p]["initial-version"] // empty' "${3:-$CONFIG}")"
  printf '%s\n' "${b:-$2.0}"
}

# stage_initial_version <base version> <stage> → the initial-version for a unit entering <stage>:
# the base itself at ga, <base>-<stage>.1 otherwise
stage_initial_version() { if [[ "$2" == ga ]]; then printf '%s\n' "$1"; else printf '%s\n' "$1-$2.1"; fi; }

# unit_release_type <path> [<config file>] → the release-type of a config entry (node when it sets none)
unit_release_type() { jq -r --arg p "$1" '.packages[$p]["release-type"] // "node"' "${2:-$CONFIG}"; }

# first_release_needs_release_as <unit> <release-type> <stage> → succeeds when the unit's first release must be
# pinned with a Release-As commit. release-please's python and rust strategies return 0.1.0 for a unit with no
# previous release and never read initial-version (src/strategies/python.ts:200-202, rust.ts:133-134), so the
# prerelease suffix of the first version only comes from Release-As (src/strategies/base.ts:543-573). "No previous
# release" is read from the tags (unit_released), not from the manifest, which keeps its version after a tag is
# deleted. A unit whose first stage is ga ships 0.1.0 as it is and needs none.
first_release_needs_release_as() {
  case "$2" in python|rust) ;; *) return 1 ;; esac
  [[ "$3" != ga ]] && ! unit_released "$1"
}

# unit_first_version <release-type> <base> <stage> <line> <manifest version> → the version a unit with no
# <component>/v* tag releases first when it is in <stage>. Advancing, GA and the check before the merge of a
# Release PR (merge-release-pr.sh) all ask this one function, so they cannot disagree.
#   - a prerelease stage: <base>-<stage>.1 (stage_initial_version), e.g. 0.1.0-beta.1
#   - ga, the manifest holds a prerelease: its stable version (1.2.0-rc.2 → 1.2.0), what the GA Release-As says
#   - ga, python or rust, no manifest entry: 0.1.0, which release-please picks by itself
#   - ga, python or rust, the manifest holds a stable version: <X.Y>.0, written as Release-As because
#     release-please would count on from the manifest (0.1.0 + feat → 0.2.0)
#   - ga, any other release-type: the base
# <base> is the initial-version of main's config, else <line>.0 (unit_main_base_version).
unit_first_version() {
  local type="$1" base="$2" stage="$3" line="$4" cur="$5"
  if [[ "$stage" != ga ]]; then stage_initial_version "$base" "$stage"; return; fi
  if [[ "$cur" == *-* ]]; then stable_version "$cur"; return; fi
  case "$type" in
    python|rust) if [[ -z "$cur" ]]; then printf '%s\n' "0.1.0"; else printf '%s\n' "$line.0"; fi ;;
    *) printf '%s\n' "$base" ;;
  esac
}

# unit_main_base_version <path> <line> → the base of a unit's first version: the initial-version its entry has in
# main's config, else <line>.0. The branch config is not read: it already carries <base>-<stage>.1 for a unit that
# was boarded, and stage_initial_version on top of that would give 0.1.0-alpha.1-beta.1.
unit_main_base_version() {
  local b
  b="$(git show "origin/main:$CONFIG" 2>/dev/null | jq -r --arg p "$1" '.packages[$p]["initial-version"] // empty')"
  printf '%s\n' "${b:-$2.0}"
}

# version_above_base <manifest version> <base> → succeeds when the manifest version, prerelease suffix removed, is
# higher than the base (also without its suffix). A first release with Release-As would then move the version back.
version_above_base() {
  local bin="$REPO_ROOT/node_modules/.bin/semver" cur base
  cur="$(stable_version "$1")" base="$(stable_version "$2")"
  [[ -x "$bin" ]] || die "找不到 ${bin}，先在 $REPO_ROOT 執行 pnpm install"
  [[ -n "$("$bin" "$cur" -r ">$base")" ]]
}

# stages_union <unit>... → the stages any of the units walks, in stage order, one per line
# The aggregate packages (aggregate_unit) follow the line and do not set it, so they are left out; a train
# of nothing but aggregates counts its own stages.
stages_union() {
  local u s
  local -A seen=()
  local -a counted=() aggs=()
  mapfile -t aggs < <(aggregate_unit)
  for u in "$@"; do in_array "$u" ${aggs[@]+"${aggs[@]}"} || counted+=("$u"); done
  (( ${#counted[@]} )) || counted=("$@")
  for u in "${counted[@]}"; do
    while IFS= read -r s; do seen[$s]=1; done < <(policy_unit_stages "$u")
  done
  for s in "${RELEASE_STAGES[@]}"; do [[ -n "${seen[$s]:-}" ]] && printf '%s\n' "$s"; done
  return 0
}

# stage_at_or_after <stage> <union stage>... → the first union stage not before <stage>; fails when there
# is none. A stage that no boarded unit walks is skipped forward this way.
stage_at_or_after() {
  local want="$1" s; shift
  for s in "$@"; do
    (( $(stage_index "$s") >= $(stage_index "$want") )) && { printf '%s\n' "$s"; return 0; }
  done
  return 1
}

# unit_stage_at <unit> <line stage> → the stage a unit is in while the line is at <line stage>: the last
# stage of its own that is not after the line. A unit that only has ga ships its final version right away.
# Any other unit the line has not reached yet gets an empty stage: it is deferred and does not release until
# the line gets to its first stage. A unit with alpha and ga stays at alpha until the line reaches ga.
unit_stage_at() {
  local line="$2" s pick="" first=""
  while IFS= read -r s; do
    [[ -n "$first" ]] || first="$s"
    (( $(stage_index "$s") <= $(stage_index "$line") )) && pick="$s"
  done < <(policy_unit_stages "$1")
  if [[ -z "$pick" && "$first" == ga ]]; then pick=ga; fi
  printf '%s\n' "$pick"
}

# stage_rank <stage> → stage_index, or one past ga for the empty stage of a deferred unit
stage_rank() { if [[ -z "$1" ]]; then printf '%s\n' "${#RELEASE_STAGES[@]}"; else stage_index "$1"; fi; }

# dependency_edges → "<unit> <dependency>" per line for every unit of the config: workspace dependencies
# from the package manifests (dependencies and peerDependencies) plus the policy's dependsOn
dependency_edges() {
  local row key comp name dep
  local -A by_name=()
  local -a rows=()
  while IFS=$'\t' read -r key comp; do
    [[ -f "$key/package.json" ]] || continue
    name="$(jq -r '.name // empty' "$key/package.json")"
    [[ -z "$name" ]] || by_name[$name]="$comp"
    rows+=("$key"$'\t'"$comp")
  done < <(jq -r '.packages | to_entries[] | "\(.key)\t\(.value.component // (.key | split("/")[1]))"' "$CONFIG")
  for row in "${rows[@]:-}"; do
    [[ -n "$row" ]] || continue
    key="${row%%$'\t'*}"; comp="${row#*$'\t'}"
    while IFS= read -r dep; do
      [[ -n "${by_name[$dep]:-}" && "${by_name[$dep]}" != "$comp" ]] && printf '%s\n' "$comp ${by_name[$dep]}"
    done < <(jq -r '((.dependencies // {}) + (.peerDependencies // {})) | keys[]' "$key/package.json")
  done
  if [[ -f "$(policy_file)" ]]; then
    jq -r '(.units // {}) | to_entries[] | .key as $u | (.value.dependsOn // [])[] | "\($u) \(.)"' "$(policy_file)"
  fi
  return 0
}

# train_assign_stages <line stage> <unit>... → "<unit> <stage>" per line, the stage each boarded unit is in
# while the line is at <line stage>. Two rules, the first one stronger:
#   - a unit another boarded unit depends on follows the earliest stage among its dependants, all the way
#     to ga. What a prerelease validates is the set shipping together, so a library must not reach a final
#     version while something built on it is still in a prerelease.
#   - every other unit takes unit_stage_at, which is empty for a unit the line has not reached.
# A linked-versions group shares one version, so its members share the earliest stage among them.
train_assign_stages() {
  local line="$1" u e from to g m agg min="" changed=1
  shift
  local -A stage_of=()
  local -a edges=() groups=() members=() aggs=()
  mapfile -t aggs < <(aggregate_unit)
  for u in "$@"; do stage_of[$u]="$(unit_stage_at "$u" "$line")"; done
  # an aggregate package is always in the line's stage, whatever stages its policy entry lists
  for agg in ${aggs[@]+"${aggs[@]}"}; do [[ ! -v "stage_of[$agg]" ]] || stage_of[$agg]="$line"; done
  while IFS= read -r e; do [[ -n "$e" ]] && edges+=("$e"); done < <(dependency_edges)
  while IFS= read -r g; do [[ -n "$g" ]] && groups+=("$g"); done < <(
    jq -c '(.plugins // [])[] | select(.type == "linked-versions") | .components' "$CONFIG")
  while (( changed )); do
    changed=0
    for e in "${edges[@]:-}"; do
      [[ -n "$e" ]] || continue
      read -r from to <<<"$e"
      [[ -v "stage_of[$from]" && -v "stage_of[$to]" ]] || continue
      [[ -n "${stage_of[$from]}" && "${stage_of[$from]}" != ga ]] || continue
      if (( $(stage_rank "${stage_of[$from]}") < $(stage_rank "${stage_of[$to]}") )); then
        stage_of[$to]="${stage_of[$from]}"; changed=1
      fi
    done
    for g in "${groups[@]:-}"; do
      [[ -n "$g" ]] || continue
      members=(); min=""
      while IFS= read -r m; do
        [[ -v "stage_of[$m]" ]] || continue
        members+=("$m")
        if (( $(stage_rank "${stage_of[$m]}") < $(stage_rank "${min:-}") )); then min="${stage_of[$m]}"; fi
      done < <(jq -r '.[]' <<<"$g")
      for m in "${members[@]:-}"; do
        [[ -n "$m" && "${stage_of[$m]}" != "$min" ]] && { stage_of[$m]="$min"; changed=1; }
      done
    done
  done
  for u in "$@"; do printf '%s %s\n' "$u" "${stage_of[$u]}"; done
}

# unit_changed <unit> <anchor> <ref> → whether <ref> has, since <anchor> (empty: the whole history), a
# commit release-please would release for the unit: a feat, fix, perf, deps or revert commit or a
# breaking change that touches the unit's path
unit_changed() {
  local p range="$3"
  p="$(unit_path "$1")" || return 1
  [[ -z "$2" ]] || range="$2..$3"
  [[ -n "$(git log -1 --format=%H -E \
    --grep='^(feat|fix|perf|deps|revert)(\([^)]*\))?!?:' --grep='^BREAKING[ -]CHANGE:' "$range" -- "$p")" ]]
}

# stage_version <version> <stage> → the version a unit enters <stage> with, computed by the semver
# package (a devDependency): inc(<version>, 'prerelease', <stage>, '1'), so 1.2.0-alpha.3 → 1.2.0-beta.1.
# The strict pattern runs first because semver also accepts a leading "v".
stage_version() {
  local v="$1" id="$2" bin="$REPO_ROOT/node_modules/.bin/semver"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || return 1
  [[ -x "$bin" ]] || { echo "找不到 ${bin}，先在 $REPO_ROOT 執行 pnpm install" >&2; return 1; }
  "$bin" -i prerelease --preid "$id" -n 1 "$v"
}

# version_stage <version> → the stage a released unit version belongs to: ga for X.Y.Z, <stage> for
# X.Y.Z-<stage>.N with <stage> one of alpha, beta, rc. Any other shape fails, because publishing and
# store uploads derive their dist-tag and build number from the stage and must not guess one.
version_stage() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[2]:-ga}"
}

# train_stage [<ref>] → the line stage the newest Release-Train-Stage trailer on <ref> (default HEAD)
# records, ga when there is none. A shallow clone that shows no trailer fails instead, because the
# trailer may sit in history the clone does not have and ga would then be a guess.
train_stage() {
  local ref="${1:-HEAD}" stage
  stage="$(git log -1 -E --grep='^Release-Train-Stage: [^ ]+$' --format=%B "$ref" 2>/dev/null \
    | sed -nE 's/^Release-Train-Stage: ([^ ]+)$/\1/p' | tail -1)"
  if [[ -z "$stage" ]]; then
    [[ "$(git rev-parse --is-shallow-repository)" != true ]] \
      || die "淺 clone 在 ${ref} 的可見歷史裡找不到 Release-Train-Stage，無法判斷發布分支所在階段，需要完整歷史（例如 checkout 設 fetch-depth: 0）"
    stage=ga
  fi
  is_stage "$stage" || die "${ref} 上的 Release-Train-Stage 是「${stage}」，不是 ${RELEASE_STAGES[*]} 之一，無法判斷發布分支所在階段"
  printf '%s\n' "$stage"
}

# train_boarded_units → every unit the train was opened with, deferred ones included, from the newest
# Release-Train-Units trailer; the units of the config when there is none
train_boarded_units() {
  local list
  list="$(git log -1 -E --grep='^Release-Train-Units: ' --format=%B HEAD 2>/dev/null | sed -nE 's/^Release-Train-Units: (.*)$/\1/p' | tail -1)"
  if [[ -n "$list" ]]; then tr ' ' '\n' <<<"$list" | sed '/^$/d'; else config_units; fi
}

# config_unit_stage <path> [<config file>] → the stage the config puts the unit at: the stage of its
# prerelease-type while it versions as a prerelease, ga otherwise, empty when the config does not list it
config_unit_stage() {
  local type
  jq -e --arg p "$1" '.packages | has($p)' "${2:-$CONFIG}" >/dev/null || { printf '%s\n' ""; return 0; }
  type="$(jq -r --arg p "$1" '.packages[$p] | if .versioning == "prerelease" then (."prerelease-type" // "") else "ga" end' "${2:-$CONFIG}")"
  type="${type%%.*}"
  is_stage "$type" || die "${2:-$CONFIG} 的 $1 的 prerelease-type 不是 ${RELEASE_STAGES[*]:0:3} 之一，無法判斷它所在階段"
  printf '%s\n' "$type"
}

# config_with_stages <config file> <stage map> → the config with each mapped unit set to its stage, on
# stdout. The map is JSON from package path to stage. A unit at ga versions normally. Any other
# stage puts it in prerelease mode, and release-please then appends prerelease-type to its first bump
# (1.3.1 + feat → 1.4.0-alpha.1), so "<stage>.1" makes the stage start at .1 without pinning a version.
config_with_stages() {
  jq --argjson st "$2" '
    .packages |= with_entries(
      (.key as $k | $st[$k]) as $s
      | if $s == null then .
        elif $s == "ga" then .value.versioning = "default" | del(.value."prerelease-type", .value.prerelease)
        else .value.versioning = "prerelease" | .value."prerelease-type" = ($s + ".1") | .value.prerelease = true end)' "$1"
}

# Paths the release flow takes from main. Two lists, because the config and the policy file differ by design.
# Rebuild (cut-release.sh --from <tag>): everything the train runs or is scoped by; the config is then
# trimmed to the train's units and the manifest merged. Drift (train_gates): only what must equal main
# at all times; the config and policy file are left out because they legitimately differ on a train.
# .github/actions is included because every workflow uses setup-workspace; CODEOWNERS, PR templates and
# dependabot.yml only take effect on the default branch, so the rest of .github is not synced.
# shellcheck disable=SC2034 # read by cut-release.sh, which sources this file
RELEASE_REBUILD_PATHS=(scripts "$CONFIG" release-policy.json .github/workflows .github/actions)
RELEASE_DRIFT_PATHS=(scripts .github/workflows .github/actions)

# main_existing_paths <path>... → the paths that exist on origin/main, one per line
main_existing_paths() {
  local p
  for p in "$@"; do git cat-file -e "origin/main:$p" 2>/dev/null && printf '%s\n' "$p"; done
  return 0
}

# main_file_versions <path> → the blob hashes <path> has had on origin/main, one per line; "-" stands for
# "deleted". Only the commits of main that changed the file are read (one git log), never the whole history.
main_file_versions() {
  local _m _m2 _old new _st
  git log --format= --raw --no-abbrev --no-renames origin/main -- "$1" 2>/dev/null | while IFS=' ' read -r _m _m2 _old new _st; do
    [[ "$new" =~ ^0+$ ]] && printf -- '-\n' || printf '%s\n' "$new"
  done
  return 0
}

# commit_matches_main <sha> [-- <pathspec>...] → success when every file the commit changed (inside the
# pathspec, if one is given) holds, after the commit, the content some version of that file has had on
# origin/main. A deleted file matches when main has deleted it at some point. A commit that changes no file
# does not match. Per-file histories of main are kept in the caller's MAIN_VERSIONS array.
commit_matches_main() {
  local sha="$1" f have versions
  shift
  [[ "${1:-}" == -- ]] && shift
  local -a files=()
  mapfile -t files < <(git diff-tree --no-commit-id --name-only -r --no-renames "$sha" -- "$@")
  (( ${#files[@]} )) || return 1
  for f in "${files[@]}"; do
    have="$(git rev-parse -q --verify "$sha:$f" 2>/dev/null || printf -- '-')"
    if [[ -z "${MAIN_VERSIONS[$f]+x}" ]]; then MAIN_VERSIONS[$f]="$(main_file_versions "$f")"; fi
    versions="${MAIN_VERSIONS[$f]}"
    grep -qxF -- "$have" <<< "$versions" || return 1
  done
  return 0
}

# train_commits_not_on_main <rev> [-- <pathspec>...] → "<short sha> <subject>" for each commit the train
# made after it was opened (the newest commit carrying a Release-Train-Base trailer) that origin/main
# does not have yet. A commit counts as on main in three cases: main has a patch-equivalent commit; it was
# cherry-picked ("cherry picked from commit X") from a commit already on main; or every file it changed
# (inside the pathspec, if given) ends up with content main has had at some point, which is what a sync of
# the release tooling from main looks like (see commit_matches_main). The last case is judged by content,
# not by subject, so a renamed sync commit still counts. Merge-back is a squash, so ancestry alone cannot
# answer this: every train commit is off main's history.
train_commits_not_on_main() {
  local rev="$1"; shift
  [[ "${1:-}" == -- ]] && shift
  local open mark sha src
  local -A MAIN_VERSIONS=()
  # No pipe into an early-exiting reader here: under pipefail the writer's SIGPIPE fails the function.
  open="$(git log -1 --format=%H -E --grep='^Release-Train-Base: [0-9a-f]{7,40}$' "$rev")"
  [[ -n "$open" ]] || return 0
  while read -r mark sha; do
    [[ "$mark" == + ]] || continue
    (( $# == 0 )) || [[ -n "$(git diff-tree --no-commit-id --name-only -r "$sha" -- "$@")" ]] || continue
    src="$(git log -1 --format=%B "$sha" | sed -nE 's/^\(cherry picked from commit ([0-9a-f]{7,40})\)$/\1/p' | tail -1)"
    if [[ -n "$src" ]] && git merge-base --is-ancestor "$src" origin/main 2>/dev/null; then continue; fi
    if commit_matches_main "$sha" -- "$@"; then continue; fi
    git log -1 --format='%h %s' "$sha"
  done < <(git cherry origin/main "$rev" "$open")
}

# Bring the local train up to its remote. Fetch even under --dry-run; fetching only updates local refs.
train_sync() { # train_sync <branch>
  local branch="$1"
  git fetch --quiet --tags origin || die "無法從 origin 抓取 tag 與 main，起點閘需要遠端最新的產品 tag"
  # 明確用遠端追蹤 ref：release-please 的工作分支名尾端同樣是 "$branch"，
  # 以短 refname pull 會同時命中兩條而報 "Cannot fast-forward to multiple branches"
  run git merge --ff-only "origin/$branch"
}

# Gates a train passes before it moves to <stage>, run after train_sync. The ci gate is called the
# GA gate when the train goes to ga, which is how the docs know it.
train_gates() { # train_gates <branch> <line> <stage>
  local branch="$1" line="$2" stage="$3" shipped next st rest tip i gate act
  if [[ "$stage" == ga ]]; then gate="GA 閘" act="跑 GA"; else gate="ci 閘" act="推進到 $stage"; fi
  # Tooling gate: the train must run main's release tooling, scripts/ and the workflows and actions that
  # call it. cut-release.sh syncs them from main when it rebuilds a train from a product tag, so only a
  # hand-made or long-lived train trips this. Main changing a workflow while the train is open (an action
  # SHA bump, say) trips it too, and that is the normal case: sync first, then move on.
  # The difference can also run the other way: a hotfix to one of these paths committed on the train only.
  # Syncing from main would wipe that hotfix, so name those commits and send them to main first.
  local -a drift_paths=() ahead_paths=() behind_paths=()
  local p ahead_msg="" c
  mapfile -t drift_paths < <(main_existing_paths "${RELEASE_DRIFT_PATHS[@]}")
  for p in ${drift_paths[@]+"${drift_paths[@]}"}; do
    git diff --quiet origin/main -- "$p" && continue
    c="$(train_commits_not_on_main HEAD -- "$p")"
    if [[ -n "$c" ]]; then ahead_paths+=("$p"); ahead_msg+="${p}:"$'\n'"${c}"$'\n'; else behind_paths+=("$p"); fi
  done
  if (( ${#ahead_paths[@]} || ${#behind_paths[@]} )); then
    local msg=""
    if (( ${#ahead_paths[@]} )); then
      msg+="發布分支有 main 還沒有的修正（${ahead_paths[*]}），先把它們帶回 main 再${act}：把下列 commit cherry-pick 到 main 並合進去，再用 git restore --source=origin/main --staged --worktree -- ${ahead_paths[*]} 同步 ${branch}。直接同步會蓋掉這些修正："$'\n'"${ahead_msg}"
    fi
    if (( ${#behind_paths[@]} )); then
      msg+="發布工具落後 main（${behind_paths[*]}）：${branch} 與 origin/main 不同。發布期間 main 改了 workflow 或腳本是常態，先同步再${act}：git restore --source=origin/main --staged --worktree -- ${behind_paths[*]}，commit 後推上 ${branch}"
    fi
    die "$msg"
  fi
  # Base gate: a line that already shipped takes patches only, and a patch must continue from the
  # line's latest product tag. cut-release.sh refuses any other base. Here it catches a train opened
  # by hand from main (merge-back is a squash, so the tag is never main's ancestor) or from an older
  # tag. It cannot reach a train that runs a finalize-release.sh from before this gate existed.
  shipped="$(git tag --list "v${line}.*" | grep -E "^v${line//./\\.}\.[0-9]+$" | sort -t. -k3,3n | tail -1 || true)"
  if [[ -n "$shipped" ]]; then
    next="v${line}.$(( ${shipped##*.} + 1 ))"
    git merge-base --is-ancestor "${shipped}^{commit}" HEAD \
      || die "起點閘未通過：${branch} 不含產品線 v${line} 最後一個產品 tag ${shipped}。修補發布要從它重建：刪掉這條分支，用 cut-release.sh --plan ${next} --units <這次的單元> --from ${shipped} 重切，修正再 cherry-pick 進去。releases/ 還沒有 ${next} 的 plan 時，先用 plan.sh maintenance 寫出"
    info "✓ 起點含 ${shipped}"
  fi
  # ci gate: the ci run of the train's tip (build, unit tests and the assembled-system e2e) must be
  # green. Every push gets a ci run (ci.yml has no path filters; its scope job skips the jobs when the
  # source is unchanged since the last green run, and that run still concludes success), so the gate
  # waits for the run of this exact commit. The last push is usually a Release PR merge, so that run
  # is often still queued or in progress when the stage moves.
  if (( DRY_RUN == 0 )) && [[ "${CI_GATE:-1}" == 1 ]]; then
    tip="$(git rev-parse "origin/$branch")"
    log "${gate}：等待 $branch 最新 commit ${tip:0:7} 的 ci 執行完成"
    # Queue time and run time are counted apart, one counter each over the whole run. A round counts as
    # running only when some job is in_progress; every other round (no run yet, no jobs yet, the gap between
    # two jobs, all jobs done but the run not, waiting for approval) counts as queued, so a status GitHub adds
    # later is queued too. Each round adds to exactly one counter and fails the moment it passes its limit.
    local queue_n=0 run_n=0 queue_max="${CI_GATE_QUEUE_TRIES:-240}" run_max="${CI_GATE_TRIES:-40}" gate_sleep="${CI_GATE_SLEEP:-15}"
    local run_id="" run_status="" nrun
    while :; do
      # One gh query per round. Until a run id is known, `run list` finds the run of this commit; a run found
      # that way is judged from its list status alone (list has no jobs, so a round that is really running
      # counts as queued, at most one round). After that `run view` returns the run status and the number of
      # in_progress jobs. A failed query will not fix itself by waiting, so it stops the gate with gh's own
      # error. Only a successful query that finds no run keeps waiting.
      gh_err="$(mktemp)"
      if [[ -z "$run_id" ]]; then
        if ! st="$(gh run list --workflow ci.yml --branch "$branch" --commit "$tip" --limit 1 --json status,conclusion,databaseId \
              --jq '.[0] | "\(.status)/\(.conclusion // "")/\(.databaseId)"' 2>"$gh_err")"; then
          err_text="$(cat "$gh_err")"; rm -f "$gh_err"
          die "${gate}無法查詢 ci 執行紀錄：${err_text:-gh run list 失敗}（查 gh 權限與 token；本機演練可用 CI_GATE=0 略過）"
        fi
        nrun=0
      else
        if ! st="$(gh run view "$run_id" --json status,conclusion,jobs \
              --jq '"\(.status)/\(.conclusion // "")/\([.jobs[] | select(.status == "in_progress")] | length)"' 2>"$gh_err")"; then
          err_text="$(cat "$gh_err")"; rm -f "$gh_err"
          die "${gate}無法查詢 ci run ${run_id}：${err_text:-gh run view 失敗}（查 gh 權限與 token；本機演練可用 CI_GATE=0 略過）"
        fi
        nrun="${st##*/}"
      fi
      rm -f "$gh_err"
      if [[ -z "$st" || "$st" == "null//null" ]]; then
        run_status="尚無 ci 執行紀錄"
      else
        run_status="${st%%/*}"
        if [[ "$st" == completed/success/* ]]; then info "✓ ci run ${run_id:-${st##*/}} 通過"; break; fi
        if [[ "$run_status" == completed ]]; then
          rest="${st#completed/}"
          [[ -n "$run_id" ]] || run_id="${st##*/}"
          die "${gate}未通過：ci run ${run_id} 結論為 ${rest%%/*}（查 gh run view ${run_id}）；修正後重跑，或以 CI_GATE=0 略過"
        fi
        [[ -n "$run_id" ]] || run_id="${st##*/}"
        run_status="run ${run_id} 狀態 ${run_status}"
      fi
      if (( nrun > 0 )); then
        run_n=$((run_n + 1))
        (( run_n > run_max )) && die "${gate}執行逾時：$branch 最新 commit ${tip:0:7} 的 ci 執行超過 ${run_max} 輪（每輪 ${gate_sleep} 秒）仍未完成（run ${run_id}）"
      else
        queue_n=$((queue_n + 1))
        warn "${tip:0:7} 的 ci 排隊中（第 ${queue_n} 輪，${run_status}）"
        (( queue_n > queue_max )) && die "${gate}排隊逾時：$branch 最新 commit ${tip:0:7} 的 ci 排隊超過 ${queue_max} 輪（每輪 ${gate_sleep} 秒）仍沒有 job 在執行，${run_status}"
      fi
      sleep "$gate_sleep"
    done
  fi

  # deploy gate: the deploy of the stage the train leaves must have succeeded before the train moves on (decision
  # deploy-gate-before-advance). The units are those ensure-stage-deploys.sh looks at: every app, service and infra unit of
  # the manifest with a prerelease version, whose tag is the stage before this one. A tag with nothing to deploy
  # (scripts/deploy/route-tag.sh) is left out. Per tag one query for the newest deploy-prerelease run, which passes only
  # when it is completed and successful: a run that is still going, no run, a tag that is not created and a failed query
  # all stop the gate. A repository with no such unit passes without a query. It queries once and never waits; whoever calls it waits for the deploy and runs it again.
  # A repository whose variable DEPLOY_ENABLED is not true (blueprint.demos.enable-conditions: the repository's own value first, the
  # organization's only when the repository has none) deploys nothing, so there is no run to look for and its units pass with the reason
  # printed. A variable list that cannot be read stops the gate, because it must not be taken for "not enabled".
  if (( DRY_RUN == 0 )) && [[ "${DEPLOY_GATE:-1}" == 1 ]]; then
    local dg_unit dg_ver dg_tag dg_route dg_st dg_err dg_text dg_id dg_rest dg_concl dg_units dg_slug dg_enabled="" dg_val dg_why
    dg_units="$(jq -r --slurpfile cfg "$REPO_ROOT/release-please-config.json" '
      ($cfg[0].packages) as $pkgs
      | to_entries[]
      | select(.key | startswith("apps/") or startswith("services/") or startswith("infra/"))
      | select(.value | test("-"))
      | "\($pkgs[.key].component // (.key | split("/")[1])) \(.value)"
    ' "$REPO_ROOT/.release-please-manifest.json")"
    [[ -n "$dg_units" ]] && log "部署閘：核對上一階段的 deploy-prerelease"
    while read -r dg_unit dg_ver; do
      [[ -n "$dg_unit" ]] || continue
      dg_tag="$dg_unit/v$dg_ver"
      dg_route="$(cd "$REPO_ROOT" && bash scripts/deploy/route-tag.sh "$dg_tag")"
      if [[ "$(sed -n 's/^skip=//p' <<<"$dg_route")" == true ]]; then info "⊘ ${dg_tag} 無需部署，略過"; continue; fi
      if [[ -z "$dg_enabled" ]]; then
        dg_slug="${GITHUB_REPOSITORY:-}"
        [[ -n "$dg_slug" ]] || dg_slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
          || die "部署閘無法得知倉名，讀不到 DEPLOY_ENABLED（設 GITHUB_REPOSITORY，或在有 origin 的倉內執行；本機演練可用 DEPLOY_GATE=0 略過）"
        dg_err="$(mktemp)"
        if ! dg_val="$(gh api --paginate "repos/${dg_slug}/actions/variables" \
              --jq '.variables[] | select(.name == "DEPLOY_ENABLED") | "set:" + .value' 2>"$dg_err")"; then
          dg_text="$(cat "$dg_err")"; rm -f "$dg_err"
          die "部署閘無法讀 ${dg_slug} 的倉層變數 DEPLOY_ENABLED：${dg_text:-gh api 失敗}（查 GitHub App 的 Variables 讀取權限；本機演練可用 DEPLOY_GATE=0 略過）"
        fi
        dg_why="倉層設為「${dg_val#set:}」"
        if [[ -z "$dg_val" ]]; then
          if ! dg_val="$(gh api --paginate "repos/${dg_slug}/actions/organization-variables" \
                --jq '.variables[] | select(.name == "DEPLOY_ENABLED") | "set:" + .value' 2>"$dg_err")"; then
            dg_text="$(cat "$dg_err")"; rm -f "$dg_err"
            die "部署閘無法讀 ${dg_slug} 可用的組織層變數 DEPLOY_ENABLED：${dg_text:-gh api 失敗}（查 GitHub App 的 Variables 讀取權限；本機演練可用 DEPLOY_GATE=0 略過）"
          fi
          dg_why="組織層設為「${dg_val#set:}」"
          [[ -n "$dg_val" ]] || dg_why="倉層與組織層都沒設"
        fi
        rm -f "$dg_err"
        dg_val="${dg_val#set:}"
        if [[ "$(printf '%s' "$dg_val" | tr 'A-Z' 'a-z')" == true ]]; then dg_enabled=1; else dg_enabled=0; fi
      fi
      if [[ "$dg_enabled" == 0 ]]; then
        info "⊘ ${dg_tag} 部署沒啟用：${dg_slug} 的變數 DEPLOY_ENABLED ${dg_why}，值不是 true，沒有部署可核對，放行"
        continue
      fi
      git ls-remote --exit-code --tags origin "refs/tags/$dg_tag" >/dev/null 2>&1 \
        || die "部署閘未通過：${dg_tag} 的 tag 尚未建立，無法核對部署（本機演練可用 DEPLOY_GATE=0 略過）"
      dg_err="$(mktemp)"
      if ! dg_st="$(gh run list --workflow deploy-prerelease.yml --branch "$dg_tag" --limit 1 --json status,conclusion,databaseId \
            --jq '.[0] | "\(.status)/\(.conclusion // "")/\(.databaseId)"' 2>"$dg_err")"; then
        dg_text="$(cat "$dg_err")"; rm -f "$dg_err"
        die "部署閘無法查詢 ${dg_tag} 的 deploy-prerelease 執行紀錄：${dg_text:-gh run list 失敗}（查 gh 權限與 token；本機演練可用 DEPLOY_GATE=0 略過）"
      fi
      rm -f "$dg_err"
      if [[ -z "$dg_st" || "$dg_st" == "null//null" ]]; then
        die "部署閘未通過：${dg_tag} 尚未派送部署，沒有 deploy-prerelease run。補派送後重跑（scripts/release/ensure-stage-deploys.sh），或以 DEPLOY_GATE=0 略過"
      fi
      dg_id="${dg_st##*/}"; dg_rest="${dg_st#*/}"; dg_concl="${dg_rest%%/*}"
      if [[ "${dg_st%%/*}" != completed ]]; then
        die "部署閘未通過：${dg_tag} 部署還在跑（run ${dg_id} 狀態 ${dg_st%%/*}）。等部署跑完再重跑，或以 DEPLOY_GATE=0 略過"
      fi
      [[ "$dg_concl" == success ]] \
        || die "部署閘未通過：${dg_tag} 最新一筆 deploy-prerelease run ${dg_id} 結論為 ${dg_concl}（查 gh run view ${dg_id}）。修好部署後重跑，或以 DEPLOY_GATE=0 略過"
      info "✓ ${dg_tag} 部署 run ${dg_id} 通過"
    done <<<"$dg_units"
  fi
}

# GA: one commit per unit of the train carrying "Release-As: <its stable version>", for every unit that
# shipped a prerelease (1.2.0-rc.2 → 1.2.0). A unit still on a stable version has not released in this
# train and is left alone, with one exception: a python or rust unit that has a stable manifest version but no
# <component>/v* tag on the remote (unit_released) never shipped. release-please would count on from that
# manifest version (0.1.0 + feat → 0.2.0), so it gets "Release-As: <X.Y>.0" (unit_first_version), which is the
# manifest value when the line is the one the manifest came from. A manifest version above the base stops the
# script. Under DRY_RUN it only lists the moves.
train_release_ga() { # train_release_ga <branch>
  local branch="$1" u p cur next type base line="${1#release/v}"
  local -a units=()
  while IFS= read -r u; do [[ -n "$u" ]] && units+=("$u"); done < <(config_units)
  for u in "${units[@]}"; do
    p="$(unit_path "$u")"
    cur="$(manifest_version "$p")"
    if [[ "$cur" != *-* ]]; then
      type="$(unit_release_type "$p")"
      case "$type" in
        python|rust)
          if [[ -n "$cur" ]] && ! unit_released "$u"; then
            base="$(unit_main_base_version "$p" "$line")"
            [[ -n "$cur" ]] && version_above_base "$cur" "$base" \
              && die "${u} 的 manifest 版號 ${cur} 高於基底 ${base}，沒有 tag 的單元不能用 Release-As 退回基底。先確認它有沒有發過版"
            next="$(unit_first_version "$type" "$base" ga "$line" "$cur")"
            info "${u}：${cur} 沒有 tag，第一次發版寫 Release-As ${next}（release-please 會從 manifest 的 ${cur} 往上算）"
            (( DRY_RUN )) || release_as_commit "$branch" "$u" "$p" "$next"
            continue
          fi ;;
      esac
      info "⊘ ${u}（${cur}）本次發布未發過 prerelease，略過"; continue
    fi
    next="$(stable_version "$cur")"
    info "${u}：$cur → $next"
    (( DRY_RUN )) && continue
    release_as_commit "$branch" "$u" "$p" "$next"
  done
}

# Move the train to the line stage <target>: every unit whose stage changes under it enters the new
# stage. A unit that already shipped a prerelease in this train gets one commit carrying
# "Release-As: <version>" (1.2.0-alpha.3 → 1.2.0-beta.1), because release-please only bumps the trailing
# number of a version that is already a prerelease and never reads prerelease-type. A unit that has not
# shipped yet only has its config changed, and its first version lands in the new stage, with one exception:
# a python or rust unit with no <component>/v* tag on the remote (unit_released). release-please ignores
# initial-version for them and counts on from the manifest, so it gets "Release-As: <first version>"
# (unit_first_version) whether it is new to the branch config or already in it with a stable manifest version
# or no manifest entry (0.1.0 + feat → 0.2.0-alpha.1 otherwise). A manifest version above the base stops the
# script. The branch config then carries the new first version as its initial-version. A unit that has a tag
# only has its config changed. Units whose stage stays put are left alone. The config change is one more
# commit. Under DRY_RUN it only lists the moves.
train_enter_stage() { # train_enter_stage <branch> <target>
  local branch="$1" target="$2" u p cur old new next id map='{}' entry line base first type
  local -a retitled=()
  local -a units=() entering=()
  while IFS= read -r u; do [[ -n "$u" ]] && units+=("$u"); done < <(train_boarded_units)
  line="${branch#release/v}"
  while read -r u new; do
    # a deferred unit is not in this branch's config, so its path and settings come from main's
    p="$(jq -r --arg u "$u" '.packages | to_entries[] | select((.value.component // (.key | split("/")[1])) == $u) | .key' "$CONFIG" | head -1)"
    [[ -n "$p" ]] || p="$(git show "origin/main:$CONFIG" | jq -r --arg u "$u" '.packages | to_entries[] | select((.value.component // (.key | split("/")[1])) == $u) | .key' | head -1)"
    [[ -n "$p" ]] || die "找不到 ${u} 在 ${CONFIG} 的路徑"
    old="$(config_unit_stage "$p")"
    if [[ -z "$new" ]]; then info "= ${u} 還沒到它的第一個階段，繼續待命"; continue; fi
    map="$(jq -c --arg p "$p" --arg s "$new" '. + {($p): $s}' <<<"$map")"
    if [[ -z "$old" ]]; then
      entry="$(git show "origin/main:$CONFIG" | jq -c --arg p "$p" '.packages[$p]')"
      first=""
      if ! unit_released "$u"; then
        base="$(jq -r '."initial-version" // empty' <<<"$entry")"
        first="$(stage_initial_version "${base:-${line}.0}" "$new")"
        entry="$(jq -c --arg i "$first" '."initial-version" = $i' <<<"$entry")"
      fi
      entering+=("$p"$'\t'"$entry")
      if first_release_needs_release_as "$u" "$(jq -r '."release-type" // "node"' <<<"$entry")" "$new"; then
        info "${u}：發布線到了它的第一個階段，入版為 ${first}（release-please 的 $(jq -r '."release-type"' <<<"$entry") 策略不讀 initial-version，另提交 Release-As）"
        (( DRY_RUN )) || release_as_commit "$branch" "$u" "$p" "$first"
      else
        info "${u}：發布線到了它的第一個階段，入版為 ${new}（prerelease-type ${new}.1，不寫 Release-As）"
      fi
      continue
    fi
    [[ "$new" != "$old" ]] || { info "= ${u} 留在 ${old}"; continue; }
    cur="$(manifest_version "$p")"
    if [[ "$cur" != *-* ]]; then
      type="$(unit_release_type "$p")"
      if first_release_needs_release_as "$u" "$type" "$new"; then
        base="$(unit_main_base_version "$p" "$line")"
        [[ -n "$cur" ]] && version_above_base "$cur" "$base" \
          && die "${u} 的 manifest 版號 ${cur:-（無）} 高於基底 ${base}，沒有 tag 的單元不能用 Release-As 退回基底。先確認它有沒有發過版"
        first="$(unit_first_version "$type" "$base" "$new" "$line" "$cur")"
        info "${u}：$old → ${new}，沒有 tag，第一次發版寫 Release-As ${first}（${type} 策略不讀 initial-version，會從 manifest 的 ${cur:-（無條目）} 往上算）"
        if (( ! DRY_RUN )); then
          release_as_commit "$branch" "$u" "$p" "$first"
          retitled+=("$p"$'\t'"$first")
        fi
      else
        info "${u}：$old → ${new}（本次發布還沒發過 prerelease，只改設定）"
      fi
      continue
    fi
    id="${cur#*-}"; id="${id%%.*}"
    if is_stage "$id" && (( $(stage_index "$id") >= $(stage_index "$new") )); then
      die "${u} 的版號 ${cur} 已在 ${id}，不能再進入 ${new}"
    fi
    next="$(stage_version "$cur" "$new")"
    info "${u}：$cur → $next"
    (( DRY_RUN )) && continue
    release_as_commit "$branch" "$u" "$p" "$next"
  done < <(train_assign_stages "$target" "${units[@]}")
  if (( DRY_RUN )); then info "[dry-run] ${CONFIG}：階段改變的單元改到新的 prerelease-type，發布線階段 → ${target}"; return 0; fi
  local tmp; tmp="$(mktemp)"
  local row
  cp "$CONFIG" "$tmp"
  for row in "${entering[@]:-}"; do
    [[ -n "$row" ]] || continue
    jq --arg p "${row%%$'\t'*}" --argjson e "${row#*$'\t'}" '.packages[$p] = $e' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
  done
  config_with_stages "$tmp" "$map" > "$tmp.2" && mv "$tmp.2" "$CONFIG"; rm -f "$tmp"
  for row in "${retitled[@]:-}"; do
    [[ -n "$row" ]] || continue
    jq --arg p "${row%%$'\t'*}" --arg i "${row#*$'\t'}" '.packages[$p]["initial-version"] = $i' "$CONFIG" > "$CONFIG.2" && mv "$CONFIG.2" "$CONFIG"
  done
  git add "$CONFIG"
  git commit -q -m "chore($branch): enter $target" -m "各單元的 prerelease-type 依政策檔改到新階段，之後才第一次發版的單元也直接落在新階段。

Release-Train-Stage: $target"
}

# release-please 依「commit 觸及哪些路徑」歸屬 Release-As，所以這個 commit 必須觸及本單元路徑；又不能
# 是空的，因為空 commit 會被歸屬到所有路徑（src/manifest.ts 的 CommitSplit includeEmpty: true），一個
# 單元的 Release-As 就會污染其他單元。標記檔為此存在，時間戳讓重跑時仍產生真實 diff。它只活在發布
# 分支上，merge-back 會先刪掉再算差異，不進 main。
# 發布套件時標記檔還在單元目錄裡，所以每個套件單元的打包設定都要讓它不進套件：
#   - npm：package.json 的 files 白名單不列它。
#   - crates.io：Cargo.toml 寫 exclude。有 include 時 cargo 忽略 exclude，改成不把它列進 include。
#   - PyPI：uv_build 只打包模組目錄，不會收進它。換成會收整個目錄的後端（例如 hatchling）時，
#     sdist 要排除它。
# 核對方式：cargo package --list、npm pack --dry-run、解開 uv build 的產物，都不該出現 .release-marker。
release_as_commit() { # release_as_commit <branch> <unit> <path> <version>
  local branch="$1" u="$2" p="$3" v="$4"
  {
    printf '%s\n' "$v"
    printf '%s\n' "#"
    printf '%s\n' "# 由發布腳本在推進階段或 GA 時寫入，用途只有一個：讓帶 Release-As footer 的"
    printf '%s\n' "# commit 觸及本單元路徑且非空。發布結束前會被刪除，不會進入預設分支。"
    printf '%s\n' "# 理由見 docs/decisions/adr/004-release-engine.md 第 6、33 項。"
    printf '%s\n' "# released from $branch at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$p/.release-marker"
  git add "$p/.release-marker"
  git commit -q -m "chore($branch): $u $v" -m "Release-As: $v"
}
