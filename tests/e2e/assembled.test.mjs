// Assembled-system checks against BUILT artifacts (dist/), not sources. Run after `pnpm -r build`: `pnpm test:e2e`.
// Unit tests prove each unit alone; this proves the built units still fit together, which is what a train ships.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const root = join(import.meta.dirname, "..", "..");
const units = [
  {
    "name": "blueprint-poly-sdk",
    "dir": "packages/blueprint-poly-sdk",
    "lang": "ts",
    "kind": "sdk"
  },
  {
    "name": "blueprint-poly-shared",
    "dir": "libs/blueprint-poly-shared",
    "lang": "ts",
    "kind": "package"
  }
];
const version = (dir) => JSON.parse(readFileSync(join(root, dir, "package.json"), "utf8")).version;

for (const unit of units.filter((u) => u.lang === "ts")) {
  test(`${unit.name}: dist/index.js loads and exports its API`, async () => {
    const file = join(root, unit.dir, "dist/index.js");
    assert.ok(existsSync(file), `${file} is missing: run pnpm -r build first`);
    const api = await import(pathToFileURL(file).href);
    assert.ok(Object.keys(api).length > 0, "dist/index.js exports nothing");
    if (typeof api.greet === "function") assert.equal(api.greet("e2e"), "hello, e2e");
  });
}

for (const unit of units.filter((u) => u.lang === "workers" && u.kind === "web")) {
  test(`${unit.name}: the built page carries the unit version`, () => {
    const healthz = JSON.parse(readFileSync(join(root, unit.dir, "public/healthz.json"), "utf8"));
    assert.equal(healthz.version, version(unit.dir));
    assert.match(readFileSync(join(root, unit.dir, "public/index.html"), "utf8"), /hello, /);
  });
}

for (const unit of units.filter((u) => u.lang === "workers" && u.kind === "service")) {
  test(`${unit.name}: the Workers bundle was built into dist/`, () => {
    const dir = join(root, unit.dir, "dist");
    assert.ok(existsSync(dir), `${dir} is missing: run pnpm -r build first`);
    assert.ok(readdirSync(dir).some((f) => f.endsWith(".js")), "dist/ has no .js bundle");
  });
}
