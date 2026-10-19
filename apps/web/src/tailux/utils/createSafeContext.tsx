// Ported from Tailux starter src/utils/createSafeContext.jsx (typed).
import { createContext, useContext, type ReactNode } from 'react'

export function createSafeContext<T>(errorMessage: string) {
  const Context = createContext<T | null>(null)

  const useSafeContext = (): T => {
    const ctx = useContext(Context)
    if (ctx === null) {
      throw new Error(errorMessage)
    }
    return ctx
  }

  const Provider = ({ children, value }: { value: T; children: ReactNode }) => (
    <Context.Provider value={value}>{children}</Context.Provider>
  )

  return [Provider, useSafeContext] as const
}
