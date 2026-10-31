import type { ComponentType, SVGProps } from 'react'

export interface NavItem {
  id: string
  path: string
  title: string
  end?: boolean
  Icon?: ComponentType<SVGProps<SVGSVGElement>>
  /** aria-keyshortcuts for the link (reception shortcuts). */
  keys?: string
  /** Warm the route chunk on hover or keyboard focus. */
  onPrefetch?: () => void
  /** Small count pill after the title (e.g. open stock alerts); hidden when 0 or absent. */
  badge?: number
  badgeLabel?: string
}

export interface NavGroup {
  id: string
  title: string
  childs: NavItem[]
}
