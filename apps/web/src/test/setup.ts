import '@testing-library/jest-dom/vitest'
import { afterEach } from 'vitest'
import { cleanup, configure } from '@testing-library/react'

// Sprint 2 pages chain several queries (me -> branches -> list -> patient names); under a loaded
// parallel run the default 1 s findBy/waitFor budget is too tight.
configure({ asyncUtilTimeout: 3000 })

afterEach(() => {
  cleanup()
  sessionStorage.clear()
})
