import { BranchesPage } from './BranchesPage'
import { MembersPage } from './MembersPage'

/**
 * One screen for the two tenant-admin jobs that used to be separate pages: invite staff and
 * manage branches. The forms are the existing members and branches pages, embedded.
 */
export function AdminDeskPage() {
  return (
    <div className="space-y-10">
      <div>
        <h1 className="text-xl font-semibold text-gray-800 dark:text-dark-50">Hospital desk</h1>
        <p className="mt-1 text-sm text-gray-600 dark:text-dark-200">Invite staff and manage branches without leaving this page.</p>
      </div>
      <section aria-labelledby="desk-staff" className="space-y-4">
        <h2 id="desk-staff" className="text-lg font-semibold text-gray-800 dark:text-dark-50">
          Staff
        </h2>
        <MembersPage embedded />
      </section>
      <section aria-labelledby="desk-branches" className="space-y-4">
        <h2 id="desk-branches" className="text-lg font-semibold text-gray-800 dark:text-dark-50">
          Branches
        </h2>
        <BranchesPage embedded />
      </section>
    </div>
  )
}
