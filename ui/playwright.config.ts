import { defineConfig, devices } from '@playwright/test'

// Run through e2e/run.sh, which starts the server and sets these.
const baseURL = process.env.UNPUB_E2E_BASE_URL ?? 'http://localhost:4123'

export default defineConfig({
  testDir: './e2e',
  timeout: 30_000,
  expect: { timeout: 7_000 },
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: 0,
  reporter: process.env.CI ? [['list'], ['html', { open: 'never' }]] : 'list',
  use: {
    baseURL,
    trace: 'retain-on-failure',
    permissions: ['clipboard-read', 'clipboard-write'],
  },
  projects: [
    {
      name: 'chromium',
      testIgnore: /screenshots\.spec\.ts/,
      use: { ...devices['Desktop Chrome'] },
    },
    // `npm run screenshots` only, so that a plain `playwright test` skips it.
    ...(process.env.UNPUB_E2E_SCREENSHOTS
      ? [
          {
            name: 'screenshots',
            testMatch: /screenshots\.spec\.ts/,
            use: { ...devices['Desktop Chrome'] },
          },
        ]
      : []),
  ],
})
