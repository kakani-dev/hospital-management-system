import { useLayoutEffect, useEffect } from 'react'
import { isServer } from '@tailux/utils/isServer'

const useIsomorphicEffect = isServer ? useEffect : useLayoutEffect

export { useIsomorphicEffect }
