// Screenshots of every screen of docs/design on a seeded registry, at 1440 px
// and 390 px, light and dark. Run with `npm run screenshots`, which starts the
// server through e2e/run.sh. Writes NN-<screen>-<width>-<theme>.png and an
// index.html to UNPUB_SCREENSHOT_DIR, /tmp/unpub-screens by default.
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  expect,
  request,
  test,
  type Browser,
  type BrowserContext,
  type Page,
} from '@playwright/test'
import { reader, seed, type Account } from './seed'
import { indexHtml, type Shot } from './screenshots-index'

const baseURL = process.env.UNPUB_E2E_BASE_URL ?? 'http://localhost:4123'
const admin: Account = {
  email: process.env.UNPUB_E2E_ADMIN_EMAIL ?? 'ada.lovelace@company.example',
  password: process.env.UNPUB_E2E_ADMIN_PASSWORD ?? 'e2e-admin-password',
}
const out = process.env.UNPUB_SCREENSHOT_DIR || '/tmp/unpub-screens'

type Theme = 'light' | 'dark'
type Variant = { width: 1440 | 390; theme: Theme }
const variants: Variant[] = [
  { width: 1440, theme: 'light' },
  { width: 1440, theme: 'dark' },
  { width: 390, theme: 'light' },
  { width: 390, theme: 'dark' },
]
const height = { 1440: 900, 390: 844 }

type Who = 'anonymous' | 'admin' | 'reader'

type Screen = {
  /** NN-slug of docs/design/screens, with a state for the boards of 02. */
  id: string
  title: string
  who: Who
  path: string | (() => string)
  /** Waits for the data and brings the page into the state of the board. */
  ready: (page: Page) => Promise<void>
  /**
   * The state lives in the page (a dialog result, an expanded row): reach it
   * once, then change width and theme in place.
   */
  stateful?: boolean
  /** Runs after every change of width and theme of a stateful screen. */
  again?: (page: Page) => Promise<void>
  /** Runs after the screenshot, such as going back online. */
  after?: (page: Page) => Promise<void>
}

let webhookId = ''
const states: Record<Exclude<Who, 'anonymous'>, string> = {
  admin: join(tmpdir(), 'unpub-screens-admin.json'),
  reader: join(tmpdir(), 'unpub-screens-reader.json'),
}
const fileOf = (screen: Screen, variant: Variant) =>
  `${screen.id}-${variant.width}-${variant.theme}.png`

async function heading(page: Page, name: string | RegExp) {
  // The README may start with a heading of the same name.
  await expect(page.getByRole('heading', { level: 1, name }).first()).toBeVisible()
}

const screens: Screen[] = [
  {
    id: '02-states-no-results',
    title: 'States: no results',
    who: 'anonymous',
    path: '/?q=payments_sdk',
    ready: async (page) => {
      await expect(page.getByRole('heading', { name: /Nothing matches/ })).toBeVisible()
    },
  },
  {
    id: '02-states-offline',
    title: 'States: offline banner',
    who: 'anonymous',
    path: '/',
    ready: async (page) => {
      await expect(page.getByRole('link', { name: 'my_company_core' })).toBeVisible()
      await page.context().setOffline(true)
      await expect(page.getByText('You are offline.', { exact: false })).toBeVisible()
    },
    after: (page) => page.context().setOffline(false),
  },
  {
    id: '02-states-forbidden',
    title: 'States: 403 for a reader on /admin',
    who: 'reader',
    path: '/admin',
    ready: async (page) => {
      await expect(page.getByText('403').first()).toBeVisible()
    },
  },
  {
    id: '03-package-list',
    title: 'Package list',
    who: 'anonymous',
    path: '/',
    ready: async (page) => {
      await expect(page.getByRole('link', { name: 'my_company_core' })).toBeVisible()
      // Discontinued packages are hidden by default.
      await expect(page.getByRole('link', { name: 'geo_utils' })).toBeVisible()
    },
  },
  {
    id: '04-package-readme',
    title: 'Package page, README',
    who: 'admin',
    path: '/packages/my_company_core',
    ready: async (page) => {
      await heading(page, /my_company_core/)
      const readme = page.getByRole('document', { name: 'README' })
      await expect(readme.getByRole('heading', { name: 'Configuration' })).toBeVisible()
    },
  },
  {
    id: '05-package-versions',
    title: 'Package page, Versions (retracted version, Actions menu)',
    who: 'admin',
    path: '/packages/my_company_core/versions/1.3.0?tab=versions',
    stateful: true,
    ready: async (page) => {
      await heading(page, /my_company_core/)
      const versions = page.getByRole('tabpanel', { name: 'Versions' })
      const retracted = versions.getByRole('switch', { name: 'Show retracted versions' })
      if ((await retracted.getAttribute('aria-checked')) !== 'true') await retracted.click()
      await expect(versions.getByRole('link', { name: '1.3.0', exact: true })).toBeVisible()
    },
    again: async (page) => {
      await page.keyboard.press('Escape')
      await page.getByRole('button', { name: 'Actions' }).click()
      await expect(page.getByRole('menu')).toBeVisible()
    },
  },
  {
    id: '06-package-install',
    title: 'Package page, Install (discontinued, copied)',
    who: 'anonymous',
    path: '/packages/legacy_auth?tab=install',
    ready: async (page) => {
      await heading(page, /legacy_auth/)
      await expect(page.getByText('company_auth').first()).toBeVisible()
      await page
        .getByRole('button', { name: /^Copy the (flutter|dart) pub add command$/ })
        .first()
        .click()
      await expect(page.getByText('Copied to the clipboard').first()).toBeVisible()
    },
  },
  {
    id: '07-package-stats',
    title: 'Package page, Stats',
    who: 'anonymous',
    path: '/packages/my_company_core/stats',
    ready: async (page) => {
      await heading(page, /my_company_core/)
      await expect(page.getByRole('tabpanel', { name: 'Stats' })).toBeVisible()
    },
  },
  {
    id: '08-login',
    title: 'Login, wrong password',
    who: 'anonymous',
    path: '/login',
    stateful: true,
    ready: async (page) => {
      await page.getByLabel('Email').fill(admin.email)
      await page.getByLabel('Password', { exact: true }).fill('not-the-password')
      await page.getByRole('button', { name: 'Log in' }).click()
      await expect(page.getByText('The email or the password is not right.')).toBeVisible()
    },
  },
  {
    id: '09-not-found',
    title: 'Not found, with a suggestion',
    who: 'anonymous',
    path: '/packages/my_company_cor',
    ready: async (page) => {
      await expect(page.getByText(/Did you mean/)).toBeVisible()
    },
  },
  {
    id: '10-account',
    title: 'Account, token just created',
    who: 'admin',
    path: '/account',
    stateful: true,
    ready: async (page) => {
      await page.getByLabel('Name', { exact: true }).fill('laptop-pub')
      await page.getByRole('button', { name: 'Create token' }).click()
      await expect(page.getByRole('status').filter({ hasText: 'laptop-pub' })).toBeVisible()
      await expect(page.getByRole('cell', { name: 'laptop-pub', exact: true })).toBeVisible()
      // The toast would cover the password form; the one-shot box is the state.
      await page.getByRole('button', { name: 'Dismiss' }).click()
      await expect(page.getByRole('button', { name: 'Dismiss' })).toHaveCount(0)
    },
  },
  {
    id: '11-admin-overview',
    title: 'Admin, Overview',
    who: 'admin',
    path: '/admin',
    ready: async (page) => {
      await expect(page.getByText('my_company_core').first()).toBeVisible()
    },
  },
  {
    id: '12-admin-users',
    title: 'Admin, Users',
    who: 'admin',
    path: '/admin/users',
    ready: async (page) => {
      await expect(
        page.getByRole('cell', { name: 'old.contractor@company.example', exact: true }),
      ).toBeVisible()
    },
  },
  {
    id: '13-admin-packages',
    title: 'Admin, Packages',
    who: 'admin',
    path: '/admin/packages',
    ready: async (page) => {
      await expect(page.getByRole('link', { name: 'my_company_core' }).first()).toBeVisible()
    },
  },
  {
    id: '14-admin-package',
    title: 'Admin, Package',
    who: 'admin',
    path: '/admin/packages/my_company_core',
    ready: async (page) => {
      await expect(page.getByText('1.3.0').first()).toBeVisible()
      await expect(page.getByText('jane.doe@company.example').first()).toBeVisible()
    },
  },
  {
    id: '15-admin-audit-log',
    title: 'Admin, Audit log (row expanded)',
    who: 'admin',
    path: '/admin/audit',
    stateful: true,
    ready: async (page) => {
      await expect(page.getByRole('cell', { name: 'package.published' }).first()).toBeVisible()
      await page.getByRole('button', { name: 'Show details' }).first().click()
      await expect(page.getByRole('button', { name: 'Hide details' })).toBeVisible()
    },
  },
  {
    id: '16-admin-webhooks',
    title: 'Admin, Webhooks',
    who: 'admin',
    path: '/admin/webhooks',
    ready: async (page) => {
      await expect(page.getByText('Retired build server')).toBeVisible()
    },
  },
  {
    id: '17-admin-webhook',
    title: 'Admin, Webhook (delivery payload open)',
    who: 'admin',
    path: () => `/admin/webhooks/${webhookId}`,
    stateful: true,
    ready: async (page) => {
      const first = page.locator('button[id^="delivery-"]').first()
      await expect(first).toBeVisible()
      await first.click()
      await expect(page.getByRole('button', { name: 'Close the payload' })).toBeVisible()
    },
  },
  {
    id: '18-admin-settings',
    title: 'Admin, Settings',
    who: 'admin',
    path: '/admin/settings',
    ready: async (page) => {
      await expect(page.getByText('UNPUB_SERVER_PORT').first()).toBeVisible()
    },
  },
]

async function loginState(account: Account, path: string) {
  const api = await request.newContext({ baseURL })
  const response = await api.post('/webapi/login', { data: account })
  expect(response.ok(), `login ${account.email}`).toBe(true)
  await api.storageState({ path })
  await api.dispose()
}

async function newContext(browser: Browser, who: Who, variant: Variant) {
  const context = await browser.newContext({
    baseURL,
    storageState: who === 'anonymous' ? undefined : states[who],
    viewport: { width: variant.width, height: height[variant.width] },
    colorScheme: variant.theme,
    reducedMotion: 'reduce',
    permissions: ['clipboard-read', 'clipboard-write'],
  })
  // The theme follows the emulated colour scheme, so that it can change in
  // place on a stateful screen.
  await context.addInitScript(() => localStorage.removeItem('unpub-theme'))
  return context
}

async function setVariant(page: Page, variant: Variant) {
  await page.setViewportSize({ width: variant.width, height: height[variant.width] })
  await page.emulateMedia({ colorScheme: variant.theme, reducedMotion: 'reduce' })
  const html = page.locator('html')
  if (variant.theme === 'dark') await expect(html).toHaveClass(/\bdark\b/)
  else await expect(html).not.toHaveClass(/\bdark\b/)
}

/** No skeleton, no request in flight, fonts loaded. */
async function settle(page: Page) {
  await page.waitForLoadState('networkidle').catch(() => {})
  await expect(page.locator('[aria-busy="true"]')).toHaveCount(0)
  await page.evaluate(() => document.fonts.ready)
}

async function shoot(page: Page, screen: Screen, variant: Variant) {
  await settle(page)
  if (!screen.again) await page.mouse.move(0, 0)
  // A click further down scrolled the page, and the sticky header with it.
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'instant' }))
  await page.screenshot({
    path: join(out, fileOf(screen, variant)),
    fullPage: true,
    animations: 'disabled',
  })
}

test.setTimeout(180_000)

// A failed test restarts the worker and so this hook: seed() leaves an
// already seeded registry as it is.
test.beforeAll(async () => {
  test.setTimeout(300_000)
  mkdirSync(out, { recursive: true })
  webhookId = await seed(baseURL, admin)
  await loginState(admin, states.admin)
  await loginState(reader, states.reader)
})

// From the files on disk, so that a run with a failed screen still gets one.
test.afterAll(() => {
  const shots: Shot[] = screens.flatMap((screen) =>
    variants
      .filter((variant) => existsSync(join(out, fileOf(screen, variant))))
      .map((variant) => ({
        screen: screen.id,
        title: screen.title,
        file: fileOf(screen, variant),
        ...variant,
      })),
  )
  writeFileSync(join(out, 'index.html'), indexHtml(shots))
})

for (const screen of screens) {
  test(screen.id, async ({ browser }) => {
    const path = () => (typeof screen.path === 'string' ? screen.path : screen.path())
    if (screen.stateful) {
      const context: BrowserContext = await newContext(browser, screen.who, variants[0])
      const page = await context.newPage()
      await page.goto(path())
      await settle(page)
      await screen.ready(page)
      for (const variant of variants) {
        await setVariant(page, variant)
        await screen.again?.(page)
        await shoot(page, screen, variant)
      }
      await screen.after?.(page)
      await context.close()
      return
    }
    for (const variant of variants) {
      const context = await newContext(browser, screen.who, variant)
      const page = await context.newPage()
      await page.goto(path())
      await settle(page)
      await screen.ready(page)
      await setVariant(page, variant)
      await shoot(page, screen, variant)
      await screen.after?.(page)
      await context.close()
    }
  })
}
