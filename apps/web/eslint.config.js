import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import jsxA11y from 'eslint-plugin-jsx-a11y'
import tseslint from 'typescript-eslint'
import { testIdRules } from './eslint/testids.mjs'
import testIdBaseline from './eslint/testids.baseline.json' with { type: 'json' }

export default tseslint.config(
  { ignores: ['dist', 'coverage', 'node_modules', 'src/tailux/**/*.{js,jsx}'] },
  {
    extends: [js.configs.recommended, ...tseslint.configs.recommended, jsxA11y.flatConfigs.recommended],
    files: ['**/*.{ts,tsx}'],
    languageOptions: { ecmaVersion: 2022, globals: globals.browser },
    plugins: { 'react-hooks': reactHooks, 'react-refresh': reactRefresh },
    rules: {
      ...reactHooks.configs.recommended.rules,
      'react-refresh/only-export-components': ['warn', { allowConstantExport: true }],
    },
  },
  {
    // Stable data-testids on form fields (module-screen-element, kebab-case). See eslint/testids.mjs.
    files: ['src/**/*.tsx'],
    ignores: ['src/tailux/**', '**/*.test.tsx', ...Object.keys(testIdBaseline)],
    rules: { 'no-restricted-syntax': ['error', ...testIdRules] },
  },
  {
    // Ported Tailux modules export contexts/hooks next to components, like the template.
    files: ['src/tailux/**/*.{ts,tsx}'],
    rules: { 'react-refresh/only-export-components': 'off' },
  },
)
