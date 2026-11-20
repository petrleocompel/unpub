import js from '@eslint/js'
import jsxA11y from 'eslint-plugin-jsx-a11y'
import reactHooks from 'eslint-plugin-react-hooks'
import globals from 'globals'
import tseslint from 'typescript-eslint'

export default tseslint.config(
  { ignores: ['dist', 'coverage', 'playwright-report', 'test-results', 'src/api/schema.d.ts'] },
  {
    extends: [
      js.configs.recommended,
      ...tseslint.configs.recommended,
      jsxA11y.flatConfigs.recommended,
    ],
    files: ['**/*.{ts,tsx}'],
    languageOptions: {
      ecmaVersion: 2022,
      globals: { ...globals.browser, ...globals.node },
    },
    plugins: {
      'react-hooks': reactHooks,
    },
    rules: {
      ...reactHooks.configs.recommended.rules,
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
      ],
      // The client renders sanitized markdown on purpose, see src/packages/markdown.tsx.
      'react/no-danger': 'off',
      // Labels are associated through htmlFor with the ids of shadcn inputs.
      'jsx-a11y/label-has-associated-control': [
        'error',
        { assert: 'either', depth: 3, controlComponents: ['NativeSelect', 'Input'] },
      ],
      // Pages focus the first field of dialogs and the login form on purpose.
      'jsx-a11y/no-autofocus': 'off',
    },
  },
)
