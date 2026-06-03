import '@testing-library/jest-dom/vitest'

// jsdom has no ResizeObserver; components that observe layout (e.g. the native
// sessions workspace terminal host) need a no-op stub under test.
if (typeof globalThis.ResizeObserver === 'undefined') {
  class ResizeObserverStub {
    observe() {}
    unobserve() {}
    disconnect() {}
  }
  globalThis.ResizeObserver = ResizeObserverStub as unknown as typeof ResizeObserver
}
