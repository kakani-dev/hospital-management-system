// Ported from Tailux starter src/app/layouts/Sideblock/index.jsx: sticky header, main content
// column and the fixed sidebar panel (layout geometry comes from styles/layouts.css). The page
// content is passed as children so the HMS shell keeps its banners and <Outlet/>.
import type { ReactNode } from 'react'
import { BreakpointProvider } from '../../contexts/breakpoint/Provider'
import { SidebarProvider } from '../../contexts/sidebar/Provider'
import { Header } from './Header'
import { Sidebar } from './Sidebar'
import type { NavGroup } from './types'

export function Sideblock({
  navigation,
  appName,
  headerStart,
  headerEnd,
  children,
}: {
  navigation: NavGroup[]
  appName: string
  headerStart?: ReactNode
  headerEnd?: ReactNode
  children: ReactNode
}) {
  return (
    <BreakpointProvider>
      <SidebarProvider>
        <Header start={headerStart} end={headerEnd} />
        <main id="main-content" tabIndex={-1} className="main-content transition-content grid grid-cols-1 content-start outline-hidden">
          {children}
        </main>
        <Sidebar navigation={navigation} appName={appName} />
      </SidebarProvider>
    </BreakpointProvider>
  )
}

export type { NavGroup, NavItem } from './types'
