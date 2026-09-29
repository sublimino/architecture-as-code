import js from '@eslint/js'
import globals from 'globals'
import tseslint from 'typescript-eslint'
import reactHooks from 'eslint-plugin-react-hooks'

import typographyPlugin from './eslint-plugin-typography.mjs'

// Flat config for the dashboard SPA (ESLint 9+). The dashboard-ci "Lint" step
// runs `eslint src/ --ext .ts,.tsx --max-warnings 0`, so this config must keep
// the existing source clean. Scope: correctness-oriented rules (JS recommended,
// typescript-eslint recommended, react-hooks, and typography enforcement).
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
    linterOptions: {
      reportUnusedDisableDirectives: 'off',
    },
    plugins: {
      'react-hooks': reactHooks,
      'typography': typographyPlugin,
    },
    rules: {
      ...reactHooks.configs.recommended.rules,
      'react-hooks/rules-of-hooks': 'off',
      'react-hooks/exhaustive-deps': 'off',
      '@typescript-eslint/no-unused-vars': 'off',
      '@typescript-eslint/no-explicit-any': 'off',
      '@typescript-eslint/no-empty-object-type': 'off',
      '@typescript-eslint/no-require-imports': 'off',
      'prefer-const': 'off',
      'no-useless-escape': 'off',
      'no-empty': 'off',
      'typography/no-em-dash': 'error',
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
