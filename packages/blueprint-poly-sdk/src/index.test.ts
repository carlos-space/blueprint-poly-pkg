import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createClient } from './index.ts'

test('url joins the path onto the base without doubling the slash', () => {
  const client = createClient('https://example.com/')
  assert.equal(client.baseUrl, 'https://example.com')
  assert.equal(client.url('/healthz'), 'https://example.com/healthz')
})
