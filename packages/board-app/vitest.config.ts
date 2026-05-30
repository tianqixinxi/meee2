import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

// Unit-test config — kept separate from vite.config.ts so the production build
// (which targets ../../Sources/Board/WebDist) is untouched. jsdom + globals so
// testing-library render tests work without per-file imports.
export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/test/setup.ts'],
    include: ['src/**/*.{test,spec}.{ts,tsx}'],
    coverage: {
      provider: 'v8',
      // text/text-summary → console + CI step summary; html → uploaded as a CI
      // artifact for drill-down; json-summary → machine-readable for tooling.
      reporter: ['text', 'text-summary', 'html', 'json-summary'],
      reportsDirectory: './coverage',
      include: ['src/components/planner/**'],
    },
  },
})
