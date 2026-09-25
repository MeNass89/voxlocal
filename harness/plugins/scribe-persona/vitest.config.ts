import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitest/config'

const harness = fileURLToPath(new URL('../../', import.meta.url))

export default defineConfig({
  test: {
    // The spec lives with the other harness tests; dsh imports resolve through tests/runtime.ts
    // inside this package.
    dir: harness,
    include: ['tests/test_scribe_persona.spec.ts'],
    environment: 'node',
    testTimeout: 20_000,
  },
  server: { fs: { allow: [harness] } },
})
