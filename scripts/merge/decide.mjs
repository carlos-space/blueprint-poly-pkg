// Decides what the auto-merge workflow does with one pull request. It only reads the facts of the pull request and
// of its checks, and prints the decision; the workflow runs `gh` and does the merge, so this file stays testable
// without a network.
//
// usage: node scripts/merge/decide.mjs --input <file|-> [--config scripts/merge/merge-config.json]
//   input  JSON { pr, checkedSha, checks, changedFiles }
//     pr           from `gh pr view --json number,state,isDraft,headRefOid,headRefName,baseRefName,isCrossRepository,labels`,
//                  read last, just before this decision
//     checkedSha   the head commit of the pull request when the checks were read
//     checks       from `gh pr checks --json name,bucket`; bucket is pass, fail, pending, skipping or cancel
//     changedFiles the paths the pull request changes (only used for the checks in config.pathFiltered)
//   config JSON { label, requiredChecks, pathFiltered, reviewPaths, syncPr }, written when the repository is composed
//          from blueprint.merge.required-checks. pathFiltered maps a check name to the path globs of the workflow that
//          has a path filter: when none of the changed files matches, that workflow did not run and the check
//          counts as skipped. reviewPaths are the CODEOWNERS style paths (blueprint.git-flow.review-paths) that need
//          a review; empty or missing means no pull request needs one here. syncPr is { author, branch }: the
//          pull request that blueprint opens in a demo repository (blueprint.sync.pull-request), which needs no review.
//   pr     also needs author ({ login, is_bot }) and latestReviews ([{ state }]) from `gh pr view --json`.
// Output: one JSON line { action, reason, ... }. action is "merge", "merge-release-pr" or "skip". A skip because a
// required check failed also lists those checks in failed.
// Exit status: 0 whenever a decision was made, 2 when the input or the config is unusable.
import { readFileSync } from "node:fs";
import { matchesGlob, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const RELEASE_PR_HEAD = "release-please--";
const RELEASE_LINE = /^release\/v(\d+\.\d+)$/;

const skip = (reason, extra = {}) => ({ action: "skip", reason, ...extra });

// A sync pull request is made by the GitHub App on the sync branch, both at once. The branch name alone is not
// enough: anyone who can push can open a pull request from a branch of the same name. gh prints the App as
// "app/<slug>", the REST API as "<slug>[bot]"; the bare slug is a user account and does not count.
export function isSyncPr(pr, syncPr) {
  if (!syncPr?.author || !syncPr?.branch) return false;
  const slug = syncPr.author.replace(/\[bot\]$/, "");
  const login = pr.author?.login;
  return pr.headRefName === syncPr.branch && (login === `${slug}[bot]` || login === `app/${slug}`) && pr.author?.is_bot !== false;
}

// CODEOWNERS style: "/dir/" is everything under dir, "/file*.json" a file at the root.
const reviewGlob = (path) => (path.endsWith("/") ? `${path.replace(/^\//, "")}**` : path.replace(/^\//, ""));
export const touchesReviewPath = (files, paths = []) => files.some((f) => paths.some((p) => matchesGlob(f, reviewGlob(p))));

// "fail" for a failed or cancelled check, "pending" for a running one, "pass" for a successful or skipped one.
// A skipped check passes: the scope job of ci.yml skips the others when nothing in the diff needs checking.
function stateOf(entries) {
  const buckets = entries.map((e) => e.bucket);
  if (buckets.some((b) => b === "fail" || b === "cancel")) return "fail";
  if (buckets.some((b) => b === "pending")) return "pending";
  return "pass";
}

export function decide({ pr, checkedSha, checks = [], changedFiles = [] }, config) {
  const { label, requiredChecks, pathFiltered = {} } = config;
  const number = pr.number;
  if (pr.state !== "OPEN") return skip(`the pull request is ${pr.state}, not OPEN`, { pr: number });
  if (pr.isCrossRepository) return skip("the pull request comes from a fork and cannot get the App token", { pr: number });
  const labels = (pr.labels ?? []).map((l) => (typeof l === "string" ? l : l.name));
  if (!labels.includes(label)) return skip(`the pull request has no ${label} label`, { pr: number });
  if (pr.isDraft) return skip("the pull request is a draft", { pr: number });
  if (checkedSha !== pr.headRefOid) {
    return skip(`a commit was pushed after the checks were read (checked ${checkedSha}, head now ${pr.headRefOid})`, { pr: number });
  }

  const failed = [];
  const pending = [];
  const missing = [];
  for (const name of requiredChecks) {
    const entries = checks.filter((c) => c.name === name);
    if (entries.length === 0) {
      const globs = pathFiltered[name];
      const filteredOut = globs !== undefined && !changedFiles.some((file) => globs.some((glob) => matchesGlob(file, glob)));
      if (!filteredOut) missing.push(name);
      continue;
    }
    const state = stateOf(entries);
    if (state === "fail") failed.push(name);
    else if (state === "pending") pending.push(name);
  }
  if (failed.length > 0) return skip(`required check failed: ${failed.join(", ")}`, { pr: number, failed });
  if (pending.length > 0) return skip(`required check still running: ${pending.join(", ")}`, { pr: number });
  if (missing.length > 0) return skip(`required check has not run: ${missing.join(", ")}`, { pr: number });

  const release = pr.headRefName.startsWith(RELEASE_PR_HEAD);
  // A change to a review path needs an approving review, except a sync pull request (blueprint.merge.sync-pr-review-exempt)
  // and a Release PR, which merge-release-pr.sh merges on a machine. The required checks above still have to pass for all of them.
  if (!release && !isSyncPr(pr, config.syncPr) && touchesReviewPath(changedFiles, config.reviewPaths)) {
    const states = (pr.latestReviews ?? []).map((r) => r.state);
    if (states.includes("CHANGES_REQUESTED")) return skip("a review asks for changes on a pull request that changes a review path", { pr: number });
    if (!states.includes("APPROVED")) return skip("the pull request changes a review path and has no approving review yet", { pr: number });
  }

  // A Release PR is not merged by this workflow. It waits for release-please to settle and its facts have to be pinned first, so a person
  // merges it on their machine with merge-release-pr.sh (git-flow-template docs/versioning.md:28), and the real run of the demos does it
  // in its pin and merge steps (decision real-run-local-orchestration).
  if (release) {
    if (!RELEASE_LINE.test(pr.baseRefName)) return skip(`a Release PR must target release/vX.Y, this one targets ${pr.baseRefName}`, { pr: number });
    return skip("a Release PR is merged with merge-release-pr.sh on a machine, not by this workflow", { pr: number });
  }
  return {
    action: "merge",
    reason: "all required checks passed or were skipped",
    pr: number,
    sha: checkedSha,
    command: ["gh", "pr", "merge", String(number), "--squash", "--match-head-commit", checkedSha, "--delete-branch"],
  };
}

const read = (p) => readFileSync(p === "-" ? 0 : p, "utf8");

function main(argv) {
  const opt = (k, d) => (argv.includes(`--${k}`) ? argv[argv.indexOf(`--${k}`) + 1] : d);
  const input = opt("input");
  if (!input) throw new Error("missing --input <file|->");
  const config = JSON.parse(read(opt("config", "scripts/merge/merge-config.json")));
  if (typeof config.label !== "string" || !Array.isArray(config.requiredChecks) || config.requiredChecks.length === 0) {
    throw new Error("the config needs a label and a non-empty requiredChecks");
  }
  console.log(JSON.stringify(decide(JSON.parse(read(input)), config)));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv.slice(2));
  } catch (e) {
    console.error(`decide.mjs: ${e.message}`);
    process.exit(2);
  }
}
