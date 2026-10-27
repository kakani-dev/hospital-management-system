import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { DataTable, type ColumnDef } from './DataTable'
import { ServerPagination } from './ServerPagination'

interface Row {
  id: string
  mrn: string
  name: string
}
const columns: ColumnDef<Row, unknown>[] = [
  { id: 'mrn', accessorKey: 'mrn', header: 'MRN' },
  { id: 'name', accessorKey: 'name', header: 'Name', enableSorting: false },
]
const rows: Row[] = [
  { id: '1', mrn: 'B-2', name: 'Bee' },
  { id: '2', mrn: 'A-1', name: 'Ay' },
]

describe('DataTable (Tailux table on TanStack)', () => {
  it('renders rows with row props and sorts by a sortable header (aria-sort on the th)', async () => {
    const user = userEvent.setup()
    render(
      <DataTable
        data={rows}
        columns={columns}
        caption="Patients"
        empty="None"
        getRowId={(r) => r.id}
        getRowProps={() => ({ 'data-testid': 'row' })}
        rowHeader="mrn"
      />,
    )
    const table = screen.getByRole('table', { name: 'Patients' })
    expect(within(table).getAllByTestId('row')).toHaveLength(2)
    expect(within(table).getAllByRole('rowheader').map((c) => c.textContent)).toEqual(['B-2', 'A-1'])
    // Non-sortable header is plain text, sortable one is a button.
    expect(within(table).queryByRole('button', { name: 'Name' })).not.toBeInTheDocument()
    await user.click(within(table).getByRole('button', { name: 'MRN' }))
    expect(within(table).getByRole('columnheader', { name: 'MRN' })).toHaveAttribute('aria-sort', 'ascending')
    expect(within(table).getAllByRole('rowheader').map((c) => c.textContent)).toEqual(['A-1', 'B-2'])
  })

  it('shows the loading row and the empty state', () => {
    const { rerender } = render(<DataTable data={[]} columns={columns} caption="t" empty="No patients" isLoading />)
    expect(screen.getByRole('status')).toHaveTextContent('Loading…')
    rerender(<DataTable data={[]} columns={columns} caption="t" empty="No patients" emptyTestId="empty" />)
    expect(screen.getByTestId('empty')).toHaveTextContent('No patients')
  })

  it('derives module-screen-element test ids from testId (table, rows, kebab-case cells, empty)', () => {
    const cols: ColumnDef<Row, unknown>[] = [
      { id: 'mrn', accessorKey: 'mrn', header: 'MRN' },
      { id: 'fullName', accessorKey: 'name', header: 'Name' },
      { id: 'due date', accessorFn: () => 'x', header: 'Due' },
    ]
    const { rerender } = render(<DataTable data={rows} columns={cols} caption="t" empty="None" testId="patients-list" />)
    expect(screen.getByTestId('patients-list')).toContainElement(screen.getByRole('table'))
    expect(screen.getAllByTestId('patients-list-row')).toHaveLength(2)
    expect(screen.getAllByTestId('patients-list-cell-mrn').map((c) => c.textContent)).toEqual(['B-2', 'A-1'])
    expect(screen.getAllByTestId('patients-list-cell-full-name')).toHaveLength(2)
    expect(screen.getAllByTestId('patients-list-cell-due-date')).toHaveLength(2)

    // Explicit row props / empty id still win over the derived ones.
    rerender(<DataTable data={rows} columns={cols} caption="t" empty="None" testId="patients-list" getRowProps={() => ({ 'data-testid': 'custom-row' })} />)
    expect(screen.getAllByTestId('custom-row')).toHaveLength(2)
    expect(screen.queryByTestId('patients-list-row')).not.toBeInTheDocument()
    rerender(<DataTable data={[]} columns={cols} caption="t" empty="No patients" testId="patients-list" />)
    expect(screen.getByTestId('patients-list-empty')).toHaveTextContent('No patients')
    rerender(<DataTable data={[]} columns={cols} caption="t" empty="No patients" testId="patients-list" emptyTestId="empty" />)
    expect(screen.getByTestId('empty')).toBeInTheDocument()
  })

  it('renders no test ids when testId is not given', () => {
    const { container } = render(<DataTable data={rows} columns={columns} caption="t" empty="None" />)
    expect(container.querySelector('[data-testid]')).toBeNull()
  })
})

describe('ServerPagination', () => {
  it('hides the pager for a single page and pages through the API result otherwise', async () => {
    const user = userEvent.setup()
    const onPageChange = vi.fn()
    const { rerender } = render(<ServerPagination page={1} pageSize={25} totalCount={2} onPageChange={onPageChange} />)
    expect(screen.queryByRole('navigation', { name: 'Pagination' })).not.toBeInTheDocument()
    expect(screen.getByText('1 - 2 of 2 entries')).toBeInTheDocument()

    rerender(<ServerPagination page={1} pageSize={25} totalCount={60} onPageChange={onPageChange} />)
    await user.click(screen.getByRole('button', { name: 'Page 3' }))
    expect(onPageChange).toHaveBeenCalledWith(3)
    await user.click(screen.getByRole('button', { name: 'Next page' }))
    expect(onPageChange).toHaveBeenLastCalledWith(2)
    expect(screen.getByRole('button', { name: 'Previous page' })).toBeDisabled()
    expect(screen.getByText('1 - 25 of 60 entries')).toBeInTheDocument()
  })
})
