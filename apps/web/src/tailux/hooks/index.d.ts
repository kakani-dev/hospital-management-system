// Type declarations for the Tailux starter hooks HMS uses (plain JS, ported from js/starter/src/hooks).
import type { DependencyList, Ref, RefCallback, useLayoutEffect } from 'react'

export declare function useDisclosure(
  initialState?: boolean,
  callbacks?: { onOpen?: () => void; onClose?: () => void },
): [boolean, { open: () => void; close: () => void; toggle: () => void }]
export declare function useDidUpdate(fn: () => void | (() => void), dependencies?: DependencyList): void
export declare const useIsomorphicEffect: typeof useLayoutEffect
export declare function useId(staticId?: string, suffix?: string): string
export declare function useMediaQuery(query: string, options?: { defaultValue?: boolean; initializeWithValue?: boolean }): boolean
export declare function useLocalStorage<T>(
  key: string,
  initialValue: T | (() => T),
  options?: { initializeWithValue?: boolean; serializer?: (v: T) => string; deserializer?: (v: string) => T },
): [T, (value: T | ((prev: T) => T)) => void, () => void]
export declare function mergeRefs<T>(...refs: Array<Ref<T> | undefined>): RefCallback<T>
export declare function useMergedRef<T>(...refs: Array<Ref<T> | undefined>): RefCallback<T>
export declare function assignRef<T>(ref: Ref<T> | undefined, value: T): void
