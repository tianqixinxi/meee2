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
      reporter: ['text', 'text-summary'],
      include: ['src/components/planner/**'],
    },
  },
})
