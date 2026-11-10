import { expect, test, type ConsoleMessage, type Page } from '@playwright/test'

const adminEmail = process.env.UNPUB_E2E_ADMIN_EMAIL ?? 'admin@e2e.example'
const adminPassword = process.env.UNPUB_E2E_ADMIN_PASSWORD ?? 'e2e-admin-password'

// Every console error fails the test: CSP violations are reported there.
let problems: string[] = []

test.beforeEach(({ page }) => {
  problems = []
  page.on('console', (message: ConsoleMessage) => {
    if (message.type() !== 'error') return
    // Anonymous visitors ask who they are: GET /webapi/me answers 401, which
    // Chrome logs as a failed resource. Nothing else may fail.
    if (
      message.text().includes('status of 401') &&
      new URL(message.location().url).pathname === '/webapi/me'
    ) {
      return
    }
    problems.push(`${message.text()} (${message.location().url})`)
  })
  page.on('pageerror', (error) => problems.push(error.message))
})

test.afterEach(() => {
  expect(problems, 'console errors and CSP violations').toEqual([])
})

async function login(page: Page) {
  await page.goto('/login?next=/account')
  await page.getByLabel('Email').fill(adminEmail)
  await page.getByLabel('Password').fill(adminPassword)
  await page.getByRole('button', { name: 'Log in' }).click()
  await expect(page).toHaveURL(/\/account$/)
}

test('the shell is served with the strict policy', async ({ request }) => {
  const response = await request.get('/', { headers: { Accept: 'text/html' } })
  expect(response.status()).toBe(200)
  const policy = response.headers()['content-security-policy'] ?? ''
  expect(policy).toContain("script-src 'self'")
  expect(policy).toContain("style-src 'self'")
  const html = await response.text()
  expect(html).not.toMatch(/<script(?![^>]*\bsrc=)[^>]*>/)
  expect(html).not.toMatch(/<style/)
  expect(html).not.toMatch(/\sstyle=/)
})

test('lists, searches and shows a package', async ({ page }) => {
  await page.goto('/')
  await expect(page.getByRole('link', { name: 'e2e_demo' })).toBeVisible()

  await page.keyboard.press('/')
  await expect(page.getByRole('searchbox', { name: 'Search packages' })).toBeFocused()
  await page.keyboard.type('demo')
  await expect(page).toHaveURL(/q=demo/)
  await expect(page.getByRole('heading', { name: /Results for/ })).toBeVisible()
  await page.getByRole('link', { name: 'e2e_demo' }).click()

  await expect(page).toHaveURL(/\/packages\/e2e_demo$/)
  await expect(page.getByRole('heading', { level: 1, name: 'e2e_demo 1.2.0' })).toBeVisible()
  const readme = page.getByRole('document', { name: 'README' })
  await expect(readme.getByRole('heading', { name: 'Usage' })).toBeVisible()
  await expect(readme.locator('pre code')).toContainText('greet')

  await page.getByRole('tab', { name: 'Install' }).click()
  await expect(page).toHaveURL(/tab=install/)
  await page.getByRole('button', { name: 'Copy the dart pub add command' }).click()
  await expect(page.getByText('Copied to the clipboard')).toBeVisible()
  const copied = await page.evaluate(() => navigator.clipboard.readText())
  expect(copied).toMatch(/^dart pub add e2e_demo --hosted-url http/)

  await page.getByRole('tab', { name: 'Versions' }).click()
  await expect(
    page.getByRole('tabpanel', { name: 'Versions' }).getByRole('link', { name: '1.2.0' }),
  ).toBeVisible()
})

test('logs in, creates a token, creates a user and reads the audit log', async ({ page }) => {
  await login(page)

  await page.getByLabel('Name', { exact: true }).fill('e2e-laptop')
  await page.getByRole('button', { name: 'Create token' }).click()
  const secretBox = page.getByRole('status').filter({ hasText: 'e2e-laptop' })
  await expect(secretBox).toBeVisible()
  await expect(secretBox).toContainText('dart pub token add')
  await expect(page.getByRole('cell', { name: 'e2e-laptop', exact: true })).toBeVisible()

  await page.goto('/admin/users')
  await page.getByRole('button', { name: 'Create user' }).click()
  const dialog = page.getByRole('dialog')
  await dialog.getByLabel('Email').fill('jane.doe@e2e.example')
  await dialog.getByLabel('Role').selectOption('reader')
  await dialog.getByLabel(/Initial password/).fill('jane-password-1')
  await dialog.getByRole('button', { name: 'Create user' }).click()
  await expect(dialog).toBeHidden()
  await expect(page.getByRole('cell', { name: 'jane.doe@e2e.example', exact: true })).toBeVisible()

  await page.getByRole('link', { name: 'Audit log' }).click()
  await expect(page.getByRole('cell', { name: 'user.created', exact: true }).first()).toBeVisible()
  await expect(page.getByRole('cell', { name: 'token.created', exact: true }).first()).toBeVisible()
  await expect(
    page.getByRole('cell', { name: 'package.published', exact: true }).first(),
  ).toBeVisible()
})

test('the classic pages still work', async ({ page }) => {
  const response = await page.goto('/classic/packages')
  expect(response?.status()).toBe(200)
  await expect(page.getByRole('link', { name: 'e2e_demo' }).first()).toBeVisible()
})
