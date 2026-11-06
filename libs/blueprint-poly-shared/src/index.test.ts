import assert from 'node:assert/strict'
import { test } from 'node:test'
import { greet } from './index.ts'

test('greet names who is greeted', () => {
  assert.equal(greet('demo'), 'hello, demo')
})
