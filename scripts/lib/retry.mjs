// The one place that asks again after a transient error of GitHub (decision transient-error-shared-retry).
// A transient error is HTTP 500, 502, 503 or 504 (gh and git word it differently) and a connect timeout. Nothing else counts: another
// 5xx, a 4xx, a refused write and a dropped credential do not get better by asking again.
//
//   transientOf(text)   "HTTP 502" | "Connect Timeout" | null
//   retryMove(...)      the pure rule: after a failure, retry, stop or check first. Every caller decides through it.
//   retryTransient      the async loop around retryMove; retryTransientSync is the same loop for a caller that cannot await
//   CLI                 node retry.mjs <read|push|merge> -- <cmd> [args...]
//
// What each kind retries (a failure of any other text stops at once, with the error as it was):
//   read      a transient error, and what the caller adds through `also` (local.mjs adds the HTTP 404 of a run that was just dispatched)
//   push      a transient error, and never a force or a delete (--force, -f, --force-with-lease, --force-if-includes, --delete, -d, +refspec,
//             :ref, --mirror, --prune): the retry of a write that rewrites or removes history is a decision, not a reflex
//   merge     a transient error and "Base branch was modified" (the base moved between the pull request being opened and merged)
//   dispatch  a transient error, but first `exists()` asks whether the dispatch made its run; a run that is there is returned and the
//             dispatch is not made again. Without a nonce `exists` cannot be written, so such a dispatch is not retried at all.
// The pause between rounds is the caller's (`pause`): this file sleeps only in the CLI, whose interval is RETRY_SLEEP seconds.
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const ROUNDS = 5;
export const SLEEP_SECONDS = 5;
export const KINDS = ["read", "push", "merge", "dispatch"];
export const CLI_KINDS = ["read", "push", "merge"];

const CODES = ["500", "502", "503", "504"];
export function transientOf(text) {
  const s = String(text ?? "");
  const codes = [...s.matchAll(/\bHTTP\/?\s*(\d{3})\b/gi), ...s.matchAll(/requested URL returned error:\s*(\d{3})\b/gi)].map((m) => m[1]);
  const code = codes.find((c) => CODES.includes(c));
  if (code) return `HTTP ${code}`;
  if (/Connect Timeout|connect: connection timed out|Connection timed out/i.test(s)) return "Connect Timeout";
  return null;
}

export const BASE_MODIFIED = "Base branch was modified";

const LONG_REWRITE = /^--(?:force(?:-with-lease|-if-includes)?|delete|mirror|prune)(?:=.*)?$/;
const SHORT_REWRITE = /^-[A-Za-z]*[fd][A-Za-z]*$/;
// true when the command line of a git push rewrites or removes something on the remote
export function rewritesRemote(argv = []) {
  const at = argv.indexOf("push");
  const args = at >= 0 ? argv.slice(at + 1) : argv;
  return args.some((a) => LONG_REWRITE.test(a) || SHORT_REWRITE.test(a) || a.startsWith("+") || /^:[^:]/.test(a));
}

/**
 * The rule after a failure. Pure: it reads the text of the failure and the round, nothing else.
 * @param {object} p
 * @param {"read"|"push"|"merge"|"dispatch"} p.kind
 * @param {string} p.text the text of the failure (message, stderr, stdout)
 * @param {number} p.round the round that just failed, from 1
 * @param {number} [p.rounds]
 * @param {string[]} [p.argv] the command line, for push
 * @param {(text:string) => string|null} [p.also] an extra reason to retry a read, as text, or null
 * @returns {{move:"retry"|"stop"|"check", reason:string|null, why?:"not-transient"|"force"|"exhausted", final?:boolean}}
 *   check (dispatch only): ask exists() before anything else; `final` says this was the last round, so a missing run ends it
 */
export function retryMove({ kind, text, round, rounds = ROUNDS, argv = [], also = null }) {
  if (!KINDS.includes(kind)) throw new Error(`retry kind ${kind}: expected ${KINDS.join(", ")}`);
  let reason = transientOf(text);
  if (reason === null && kind === "merge" && new RegExp(BASE_MODIFIED, "i").test(String(text ?? ""))) reason = BASE_MODIFIED;
  if (reason === null && kind === "read" && also) reason = also(String(text ?? "")) ?? null;
  if (reason === null) return { move: "stop", reason: null, why: "not-transient" };
  if (kind === "push" && rewritesRemote(argv)) return { move: "stop", reason, why: "force" };
  if (kind === "dispatch") return { move: "check", reason, final: round >= rounds };
  if (round >= rounds) return { move: "stop", reason, why: "exhausted" };
  return { move: "retry", reason };
}

// the failure that ended a retry loop because the rounds were used up
export class RetryExhausted extends Error {
  constructor(cause, tries, reason) {
    super(`${cause?.message ?? cause}（試了 ${tries} 次，最後的理由 ${reason}）`);
    Object.assign(this, { cause, tries, reason });
  }
}

export const errorText = (e) => [e?.message ?? e, e?.stderr, e?.stdout].filter((x) => x !== undefined && x !== null && x !== "").join("\n");

// What a failure leads to, shared by the async and the sync loop: { done } (return it), { fail } (throw it) or { wait } (pause, go on)
function settle(error, round, { kind, also, rounds, argv }, found) {
  const move = retryMove({ kind, text: errorText(error), round, rounds, argv, also });
  if (move.move === "stop") return { fail: move.why === "exhausted" ? new RetryExhausted(error, round, move.reason) : error };
  if (move.move === "check") {
    if (found) return { done: found.value };
    return move.final ? { fail: new RetryExhausted(error, round, move.reason) } : { wait: move.reason };
  }
  return { wait: move.reason };
}
const need = (kind, exists) => { if (kind === "dispatch" && typeof exists !== "function") throw new Error("retry kind dispatch needs exists(): a dispatch that cannot be looked up is not retried"); };
const isCheck = (error, round, o) => retryMove({ kind: o.kind, text: errorText(error), round, rounds: o.rounds, argv: o.argv, also: o.also }).move === "check";

/**
 * Runs attempt(round) until it returns, asking retryMove after each failure.
 * @param {object} p
 * @param {string} p.kind read | push | merge | dispatch
 * @param {(round:number) => Promise<any>} p.attempt
 * @param {() => Promise<any>} [p.exists] dispatch: the run the dispatch made, or null (a falsy answer means none)
 * @param {(text:string) => string|null} [p.also]
 * @param {number} [p.rounds]
 * @param {(round:number, reason:string) => Promise<void>} [p.pause] called between two rounds; the default does not wait
 * @param {string[]} [p.argv]
 */
export async function retryTransient({ kind, attempt, exists, also = null, rounds = ROUNDS, pause = async () => {}, argv = [] }) {
  need(kind, exists);
  const o = { kind, exists, also, rounds, argv };
  for (let round = 1; ; round++) {
    let error;
    try { return await attempt(round); } catch (e) { error = e; }
    const found = isCheck(error, round, o) ? { value: await exists() } : null;
    const s = settle(error, round, o, found?.value ? found : null);
    if ("done" in s) return s.done;
    if (s.fail) throw s.fail;
    await pause(round, s.wait);
  }
}

// The same for a caller that cannot await (the scenario world runs its commands with spawnSync): attempt, exists and pause are sync.
export function retryTransientSync({ kind, attempt, exists, also = null, rounds = ROUNDS, pause = () => {}, argv = [] }) {
  need(kind, exists);
  const o = { kind, exists, also, rounds, argv };
  for (let round = 1; ; round++) {
    let error;
    try { return attempt(round); } catch (e) { error = e; }
    const found = isCheck(error, round, o) ? { value: exists() } : null;
    const s = settle(error, round, o, found?.value ? found : null);
    if ("done" in s) return s.done;
    if (s.fail) throw s.fail;
    pause(round, s.wait);
  }
}

// --- CLI ---------------------------------------------------------------------------------------------------------------------
class CommandFailed extends Error {
  constructor(r) {
    super(`exit status ${r.status ?? 1}`);
    Object.assign(this, { status: r.status ?? 1, stdout: r.stdout ?? "", stderr: r.stderr ?? "" });
  }
}

// Runs the command, prints what it printed as it was, and asks again after a failure the kind retries. The exit status is the status
// of the last run. `sleep` is how the CLI waits (seconds); the default really waits.
export async function main(args, { env = process.env, out = process.stdout, err = process.stderr, sleep = (s) => new Promise((r) => setTimeout(r, s * 1000)) } = {}) {
  const [kind, sep, ...cmd] = args;
  if (!CLI_KINDS.includes(kind) || sep !== "--" || cmd.length === 0) {
    err.write(`usage: node retry.mjs <${CLI_KINDS.join("|")}> -- <cmd> [args...]\n`);
    return 2;
  }
  const seconds = Number(env.RETRY_SLEEP ?? SLEEP_SECONDS);
  const attempt = async () => {
    const r = spawnSync(cmd[0], cmd.slice(1), { encoding: "utf8", stdio: ["inherit", "pipe", "pipe"], maxBuffer: 256 * 1024 * 1024, env });
    if (r.error) throw new CommandFailed({ status: 127, stderr: `${cmd[0]}: ${r.error.message}\n` });
    out.write(r.stdout ?? "");
    err.write(r.stderr ?? "");
    if (r.status !== 0) throw new CommandFailed(r);
    return r;
  };
  try {
    await retryTransient({
      kind, attempt, argv: cmd,
      pause: async (round, reason) => {
        err.write(`! 第 ${round} 次失敗（${reason}），${seconds} 秒後重試\n`);
        await sleep(seconds);
      },
    });
    return 0;
  } catch (e) {
    const failed = e instanceof RetryExhausted ? e.cause : e;
    if (e instanceof RetryExhausted) err.write(`✗ 重試 ${e.tries} 次仍失敗，最後的理由：${e.reason}\n`);
    return failed?.status ?? 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = await main(process.argv.slice(2));
}
