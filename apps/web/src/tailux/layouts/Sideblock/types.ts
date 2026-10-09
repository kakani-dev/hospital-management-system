import type { ComponentType, SVGProps } from 'react'

export interface NavItem {
  id: string
  path: string
  title: string
  end?: boolean
  Icon?: ComponentType<SVGProps<SVGSVGElement>>
  /** aria-keyshortcuts for the link (reception shortcuts). */
  keys?: string
}

export interface NavGroup {
  id: string
  title: string
  childs: NavItem[]
}
