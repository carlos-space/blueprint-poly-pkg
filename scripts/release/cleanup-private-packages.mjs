// Deletes the old versions of private packages on GitHub Packages. Each package keeps its latest GA version and every
// prerelease newer than that GA. Every older GA and every prerelease older than the latest GA is deleted. There is no
// exception list. The rule is the fact blueprint.templates.private-package-cleanup.
//
//   a package with no GA version        nothing is deleted: there is no latest GA to count from
//   a version that is not X.Y.Z or      left alone and listed as skipped, because its order is unknown
//   X.Y.Z-<alpha|beta|rc>.N
//
// usage: node scripts/release/cleanup-private-packages.mjs [--yes] [--owner <org>] [--owner-type orgs|users]
//                                                          [--versions-file <json>] <package>...
//   without --yes   dry run: prints every keep and delete line and sends nothing (the default)
//   --yes           deletes the versions listed as delete through `gh api -X DELETE`
//   --owner         the organization or user that owns the packages (default: the owner of GITHUB_REPOSITORY)
//   --versions-file a JSON object { "<package>": [{ "id": 1, "name": "1.2.0" }, ...] } instead of asking GitHub (tests)
//   <package>       the package name, with or without its @scope/
// Output: one line per version, `keep <package> <version> (<reason>)`, `delete <package> <version> (<reason>)` or
// `skip <package> <version> (<reason>)`. Exit status: 0 done, 1 a deletion failed, 2 the arguments or GitHub are wrong.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const STAGE_RANK = { alpha: 0, beta: 1, rc: 2 };
const SHAPE = /^(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.(\d+))?$/;

// parse → { core: [x, y, z], stage: "ga" | "alpha" | "beta" | "rc", n } or null
export function parse(version) {
  const m = SHAPE.exec(version);
  if (!m) return null;
  return { core: [Number(m[1]), Number(m[2]), Number(m[3])], stage: m[4] ?? "ga", n: m[5] === undefined ? 0 : Number(m[5]) };
}

// compare(a, b) < 0 when a is older: the core first, then a prerelease is older than the release it leads to, then
// alpha < beta < rc, then the number
export function compare(a, b) {
  for (let i = 0; i < 3; i++) if (a.core[i] !== b.core[i]) return a.core[i] - b.core[i];
  const rank = (v) => (v.stage === "ga" ? 3 : STAGE_RANK[v.stage]);
  if (rank(a) !== rank(b)) return rank(a) - rank(b);
  return a.n - b.n;
}

// plan(["1.0.0", ...]) → { keep: [{ version, reason }], delete: [...], skip: [...] }
export function plan(versions) {
  const known = versions.map((version) => ({ version, v: parse(version) }));
  const skip = known.filter((k) => k.v === null).map((k) => ({ version: k.version, reason: "not X.Y.Z or X.Y.Z-<alpha|beta|rc>.N, order unknown" }));
  const ordered = known.filter((k) => k.v !== null).toSorted((a, b) => compare(a.v, b.v));
  const gas = ordered.filter((k) => k.v.stage === "ga");
  const latest = gas.at(-1);
  const keep = [];
  const del = [];
  for (const k of ordered) {
    if (latest === undefined) keep.push({ version: k.version, reason: "no GA version, nothing to count from" });
    else if (k === latest) keep.push({ version: k.version, reason: "latest GA" });
    else if (compare(k.v, latest.v) > 0) keep.push({ version: k.version, reason: "prerelease newer than the latest GA" });
    else del.push({ version: k.version, reason: k.v.stage === "ga" ? "older GA" : "prerelease older than the latest GA" });
  }
  return { keep, delete: del, skip };
}

function ghVersions(ownerType, owner, name) {
  const out = execFileSync("gh", ["api", "--paginate", `/${ownerType}/${owner}/packages/npm/${encodeURIComponent(name)}/versions`, "--jq", '.[] | [.id, .name] | @tsv'], { encoding: "utf8" });
  return out.split("\n").filter(Boolean).map((l) => {
    const [id, version] = l.split("\t");
    return { id: Number(id), name: version };
  });
}

function main(argv) {
  const opt = (k) => (argv.includes(`--${k}`) ? argv[argv.indexOf(`--${k}`) + 1] : undefined);
  const valued = new Set(["--owner", "--owner-type", "--versions-file"]);
  const packages = argv.filter((a, i) => !a.startsWith("--") && !valued.has(argv[i - 1]));
  if (packages.length === 0) throw new Error("name at least one package");
  const yes = argv.includes("--yes");
  const ownerType = opt("owner-type") ?? "orgs";
  const owner = opt("owner") ?? process.env.GITHUB_REPOSITORY?.split("/")[0];
  const file = opt("versions-file");
  if (file === undefined && !owner) throw new Error("give --owner, or run where GITHUB_REPOSITORY is set");
  const fixture = file === undefined ? null : JSON.parse(readFileSync(file, "utf8"));
  let failed = 0;
  for (const raw of packages) {
    const name = raw.replace(/^@[^/]+\//, "");
    const rows = fixture === null ? ghVersions(ownerType, owner, name) : (fixture[name] ?? fixture[raw] ?? []);
    const p = plan(rows.map((r) => r.name));
    const idOf = new Map(rows.map((r) => [r.name, r.id]));
    for (const k of p.keep) console.log(`keep ${name} ${k.version} (${k.reason})`);
    for (const k of p.skip) console.log(`skip ${name} ${k.version} (${k.reason})`);
    for (const d of p.delete) {
      console.log(`delete ${name} ${d.version} (${d.reason})${yes ? "" : " [dry run]"}`);
      if (!yes) continue;
      try {
        execFileSync("gh", ["api", "-X", "DELETE", `/${ownerType}/${owner}/packages/npm/${encodeURIComponent(name)}/versions/${idOf.get(d.version)}`], { stdio: "pipe" });
      } catch (e) {
        failed++;
        console.error(`could not delete ${name} ${d.version}: ${e.stderr?.toString().trim() ?? e.message}`);
      }
    }
  }
  if (!yes) console.log("dry run: nothing deleted, run again with --yes to delete");
  process.exit(failed > 0 ? 1 : 0);
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  try {
    main(process.argv.slice(2));
  } catch (e) {
    console.error(`cleanup-private-packages: ${e.message}`);
    process.exit(2);
  }
}
