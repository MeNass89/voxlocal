import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitest/config'

const harness = fileURLToPath(new URL('../../', import.meta.url))

export default defineConfig({
  test: {
    // The spec lives with the other harness tests (plan H3); dsh imports resolve through
    // tests/runtime.ts inside this package.
    dir: harness,
    include: ['tests/test_portail_tools.spec.ts'],
    environment: 'node',
    testTimeout: 20_000,
  },
  server: { fs: { allow: [harness] } },
})
