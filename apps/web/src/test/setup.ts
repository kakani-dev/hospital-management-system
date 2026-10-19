import '@testing-library/jest-dom/vitest'
import { afterEach } from 'vitest'
import { cleanup, configure } from '@testing-library/react'

// Sprint 2 pages chain several queries (me -> branches -> list -> patient names); under a loaded
// parallel run the default 1 s findBy/waitFor budget is too tight.
configure({ asyncUtilTimeout: 3000 })

// jsdom has no ResizeObserver; Headless UI's Combobox (TimeZoneField) observes its input on close.
if (!('ResizeObserver' in globalThis)) {
  class ResizeObserverStub {
    observe() {}
    unobserve() {}
    disconnect() {}
  }
  ;(globalThis as unknown as { ResizeObserver: typeof ResizeObserverStub }).ResizeObserver = ResizeObserverStub
}

afterEach(() => {
  cleanup()
  sessionStorage.clear()
})
