import { expect, test, type ConsoleMessage, type Page } from '@playwright/test'

const adminEmail = process.env.UNPUB_E2E_ADMIN_EMAIL ?? 'admin@e2e.example'
const adminPassword = process.env.UNPUB_E2E_ADMIN_PASSWORD ?? 'e2e-admin-password'

// Every console error fails the test: CSP violations are reported there.
let problems: string[] = []

test.beforeEach(({ page }) => {
  problems = []
  page.on('console', (message: ConsoleMessage) => {
    if (message.type() !== 'error') return
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
  await page.getByLabel('Password', { exact: true }).fill(adminPassword)
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
  const versions = page.getByRole('tabpanel', { name: 'Versions' })
  await expect(versions.getByRole('link', { name: '1.2.0', exact: true })).toBeVisible()
  const download = versions.getByRole('link', { name: 'Download 1.2.0 archive' })
  await expect(download).toHaveAttribute('href', '/packages/e2e_demo/versions/1.2.0.tar.gz')
  const archive = await page.request.get((await download.getAttribute('href'))!)
  expect(archive.status()).toBe(200)
  expect((await archive.body()).subarray(0, 2)).toEqual(Buffer.from([0x1f, 0x8b]))
})

test('a heading reached by its fragment clears the sticky header', async ({ page }) => {
  for (const width of [390, 1280]) {
    await page.setViewportSize({ width, height: 720 })
    await page.goto('/packages/e2e_demo')
    const heading = page
      .getByRole('document', { name: 'README' })
      .getByRole('heading', { name: 'Troubleshooting' })
    await expect(heading).toBeAttached()
    await page.evaluate(() => {
      window.location.hash = 'md-troubleshooting'
    })
    const header = await page.locator('header').first().boundingBox()
    expect(header, 'the header').not.toBeNull()
    // Two rows on a phone, one from sm; the heading starts below either.
    const below = header!.y + header!.height
    await expect
      .poll(async () => (await heading.boundingBox())?.y ?? Infinity)
      .toBeLessThan(below + 40)
    expect((await heading.boundingBox())!.y).toBeGreaterThanOrEqual(below)
  }
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

// `UNPUB_E2E_SCREENSHOT=$PWD/../assets/screenshot.png npm run test:e2e`
// refreshes the screenshot of the README.
test('screenshot of the package list', async ({ page }) => {
  const out = process.env.UNPUB_E2E_SCREENSHOT
  test.skip(!out, 'Set UNPUB_E2E_SCREENSHOT to the file to write')
  await page.emulateMedia({ colorScheme: 'light', reducedMotion: 'reduce' })
  await page.setViewportSize({ width: 1440, height: 900 })
  // A theme chosen in a reused storage state would win over the media query.
  await page.addInitScript(() => localStorage.removeItem('unpub-theme'))
  await page.goto('/')
  await expect(page.locator('html')).not.toHaveClass(/\bdark\b/)
  await expect(page.getByRole('link', { name: 'e2e_demo' })).toBeVisible()
  await page.mouse.move(0, 0)
  await page.screenshot({ path: out, animations: 'disabled' })
})
