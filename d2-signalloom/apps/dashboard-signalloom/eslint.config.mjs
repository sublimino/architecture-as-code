import js from '@eslint/js'
import globals from 'globals'
import tseslint from 'typescript-eslint'
import reactHooks from 'eslint-plugin-react-hooks'

// Flat config for the dashboard SPA (ESLint 9+). The dashboard-ci "Lint" step
// runs `eslint src/ --ext .ts,.tsx --max-warnings 0`, so this config must keep
// the existing source clean. Scope: correctness-oriented rules (JS recommended,
// typescript-eslint recommended, react-hooks). Stylistic/HMR rules are omitted
// to avoid noise across components that intentionally co-export hooks/context.
export default tseslint.config(
  { ignores: ['dist', 'node_modules', 'coverage'] },
  {
    files: ['**/*.{ts,tsx}'],
    extends: [js.configs.recommended, ...tseslint.configs.recommended],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: { ...globals.browser },
    },
    plugins: { 'react-hooks': reactHooks },
    rules: {
      ...reactHooks.configs.recommended.rules,
    },
  },
  {
    // Test files also run in a Node/vitest context with jest-dom globals.
    files: ['**/*.test.{ts,tsx}', 'src/test-setup.ts'],
    languageOptions: {
      globals: { ...globals.browser, ...globals.node },
    },
  },
)
