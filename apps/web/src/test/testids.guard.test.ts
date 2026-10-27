import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { ESLint } from 'eslint'
import { describe, expect, it } from 'vitest'
import { testIdRules } from '../../eslint/testids.mjs'

const webRoot = resolve(__dirname, '../..')
const baseline: Record<string, number> = JSON.parse(readFileSync(`${webRoot}/eslint/testids.baseline.json`, 'utf8'))

async function lint(code: string, filePath = 'src/features/demo/DemoPage.tsx') {
  const eslint = new ESLint({ cwd: webRoot, overrideConfigFile: true, overrideConfig: [
    { files: ['**/*.tsx'], languageOptions: { parser: (await import('typescript-eslint')).parser, parserOptions: { ecmaFeatures: { jsx: true } } },
      rules: { 'no-restricted-syntax': ['error', ...testIdRules] } },
  ] })
  const [result] = await eslint.lintText(code, { filePath })
  return result?.messages.map((m) => m.message) ?? []
}

describe('data-testid check on form fields', () => {
  it.each([
    ['<FormField label="Name" />'],
    ['<SelectField label="Doctor"><option /></SelectField>'],
    ['<Textarea label="Notes" />'],
    ['<input aria-label="Phone" />'],
    ['<select aria-label="Status"><option /></select>'],
    ['<textarea aria-label="Advice" />'],
  ])('flags a field without a data-testid: %s', async (jsx) => {
    expect(await lint(`export const A = () => ${jsx}`)).toEqual([expect.stringContaining('need a data-testid')])
  })

  it.each([
    ['<FormField label="Name" data-testid="patients-register-first-name" />'],
    ['<input aria-label="Phone" data-testid={`billing-drawer-${"phone"}`} />'],
    ['<input {...props} />'],
    ['<button type="button">Save</button>'],
  ])('accepts %s', async (jsx) => {
    expect(await lint(`export const A = (props: object) => ${jsx}`)).toEqual([])
  })

  it.each(['Bill_Row', 'billRow', 'bill row', '-bill', 'bill--row'])('rejects non-kebab id "%s"', async (id) => {
    expect(await lint(`export const A = () => <div data-testid="${id}" />`)).toEqual([expect.stringContaining('kebab-case')])
  })

  it('files in the baseline only lose fields without ids, never gain them', async () => {
    const eslint = new ESLint({ cwd: webRoot, overrideConfig: { rules: { 'no-restricted-syntax': ['error', ...testIdRules] } } })
    const results = await eslint.lintFiles(Object.keys(baseline))
    const now = Object.fromEntries(results.map((r) => [
      r.filePath.slice(webRoot.length).replace(/^\//, ''),
      r.messages.filter((m) => m.ruleId === 'no-restricted-syntax').length,
    ]))
    const grown = Object.entries(baseline)
      .filter(([file, max]) => (now[file] ?? 0) > max)
      .map(([file, max]) => `${file}: ${now[file]} fields without data-testid (baseline ${max})`)
    expect(grown).toEqual([])
  }, 60_000)
})
