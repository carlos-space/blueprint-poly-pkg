// The version a component package describes, read from the repository's .release-please-manifest.json
// so `describes` and the version actually released never need a second edit. A repository that has not released
// yet has no manifest, and then nothing is described.
import { existsSync, readFileSync } from 'node:fs'

const root = new URL('../../', import.meta.url)

function readJson(name: string): Record<string, unknown> {
  return JSON.parse(readFileSync(new URL(name, root), 'utf8')) as Record<string, unknown>
}

/** `describes` for the release-please unit named `component`: `{ [component]: <manifest version> }`, or `{}`. */
export function describesOf(component: string): Record<string, string> {
  if (!existsSync(new URL('.release-please-manifest.json', root))) return {}
  const manifest = readJson('.release-please-manifest.json') as Record<string, string>
  const packages = (readJson('release-please-config.json').packages ?? {}) as Record<string, { component?: string }>
  const path =
    Object.keys(manifest).find((p) => (packages[p]?.component ?? p.split('/').pop()) === component) ??
    Object.keys(manifest).find((p) => p.split('/').pop() === component)
  const version = path === undefined ? undefined : manifest[path]
  return version === undefined ? {} : { [component]: version }
}
