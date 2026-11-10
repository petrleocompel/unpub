// Seeds a registry that looks like the data of docs/design, through the API
// only: packages published from the e2e_demo fixture under other names and
// versions, users of every role, tokens, webhooks with deliveries, and the
// audit events all of that leaves. Used by screenshots.spec.ts.
import { execFileSync } from 'node:child_process'
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, request, type APIRequestContext } from '@playwright/test'

const fixture = join(import.meta.dirname, 'fixtures', 'e2e_demo')

export type Account = { email: string; password: string }

export const reader: Account = {
  email: 'eva.svobodova@company.example',
  password: 'eva-password-1',
}
const publisher: Account = { email: 'jane.doe@company.example', password: 'jane-password-1' }

type Release = {
  version: string
  sdk?: string
  flutter?: string
  dependencies?: Record<string, string>
  /** Published with the publisher's token instead of the administrator's. */
  byPublisher?: boolean
}

type PackageSeed = {
  name: string
  description: string
  flutter?: boolean
  readme?: string
  releases: Release[]
  /** Downloads of the latest release; older ones get fewer. */
  downloads: number
}

const longReadme = `# my_company_core

Core models, the HTTP client and error types shared by every Company app. Every
app and most packages depend on it, so it follows semantic versioning strictly
and keeps a deprecation period of one minor version.

## Installation

\`\`\`yaml
dependencies:
  my_company_core:
    hosted: https://pub.company.example
    version: ^1.4.0
\`\`\`

Then run \`dart pub get\`. The registry is private: add a token first with
\`dart pub token add https://pub.company.example\`.

## Usage

\`\`\`dart
import 'package:my_company_core/my_company_core.dart';

Future<void> main() async {
  final client = CompanyClient(baseUrl: Uri.parse('https://api.company.example'));
  final order = await client.orders.get('A-1042');
  print(order.total.format()); // 1 249,00 Kč
}
\`\`\`

### Errors

Every failed call throws a subclass of \`CompanyException\`, never a raw
\`HttpException\`, so one \`on CompanyException\` covers them all.

| Exception             | When                                   | Retry      |
| --------------------- | -------------------------------------- | ---------- |
| \`NetworkException\`    | No connection, DNS or TLS failure      | Yes        |
| \`TimeoutException\`    | No answer within \`timeout\`             | Yes        |
| \`AuthException\`       | 401, the session expired               | After login |
| \`ValidationException\` | 400 or 422, with the field errors      | No         |
| \`ServerException\`     | 5xx                                    | With backoff |

### Money and dates

\`Money\` keeps the amount in minor units and the currency, and formats it for
the locale of the app. \`LocalDate\` is a date without a time zone, for
delivery dates and birthdays.

## Configuration

| Option          | Default  | Description                                   |
| --------------- | -------- | --------------------------------------------- |
| \`baseUrl\`       | required | The API gateway of the environment.           |
| \`timeout\`       | \`30s\`    | Per request, retries not included.            |
| \`retries\`       | \`3\`      | For idempotent requests only.                 |
| \`userAgent\`     | the app  | Sent as \`User-Agent\` and in the audit trail.  |
| \`logRequests\`   | \`false\`  | Logs method, path and status, never bodies.   |

## Testing

\`MockCompanyClient\` answers from fixtures in \`test/fixtures\`. Record new
fixtures with \`dart run my_company_core:record\` against the staging gateway.

## Migrating from 1.3

- \`Order.items\` is now an unmodifiable list.
- \`CompanyClient.close()\` must be awaited.
- \`Money.parse\` no longer accepts a comma as the decimal separator; use
  \`Money.parseLocalized\`.

## Troubleshooting

**\`HandshakeException\` on Android emulators.** The emulator's clock is wrong;
cold boot it.

**\`AuthException\` right after login.** Two clients share one token store with
different base URLs. Give each its own \`TokenStore\`.

## Contributing

Open a merge request against \`main\`. The CI runs the analyzer with
\`analysis_rules\`, the tests and a dry run of \`dart pub publish\`.
`

const packages: PackageSeed[] = [
  {
    name: 'my_company_core',
    description: 'Core models, the HTTP client and error types shared by every Company app.',
    readme: longReadme,
    releases: [
      { version: '1.0.0', sdk: '^3.0.0' },
      { version: '1.1.0', sdk: '^3.0.0' },
      { version: '1.2.0', sdk: '^3.2.0' },
      { version: '1.3.0', sdk: '^3.3.0', byPublisher: true },
      { version: '1.3.1', sdk: '^3.3.0', byPublisher: true },
      { version: '1.4.0', sdk: '^3.5.0' },
    ],
    downloads: 48,
  },
  {
    name: 'company_design_system',
    description: 'Widgets, themes and icons of the Company design system, with golden tests.',
    flutter: true,
    releases: [
      { version: '5.0.0', flutter: '>=3.22.0' },
      { version: '5.1.0', flutter: '>=3.22.0' },
      { version: '5.2.0', flutter: '>=3.24.0' },
      { version: '5.2.1', flutter: '>=3.24.0' },
    ],
    downloads: 31,
  },
  {
    name: 'flutter_bloc_extensions',
    description:
      'Retry, debounce and pagination helpers on top of flutter_bloc, used by the mobile apps.',
    flutter: true,
    releases: [
      { version: '1.8.1', flutter: '>=3.19.0', dependencies: { flutter_bloc: '^8.1.0' } },
      { version: '1.8.2', flutter: '>=3.19.0', dependencies: { flutter_bloc: '^8.1.0' } },
      { version: '2.0.0-beta.1', flutter: '>=3.24.0', dependencies: { flutter_bloc: '^9.0.0' } },
    ],
    downloads: 22,
  },
  {
    name: 'company_auth',
    description: 'Sign-in with the Company SSO, token refresh and secure storage.',
    flutter: true,
    releases: [
      { version: '3.0.0', flutter: '>=3.22.0', dependencies: { my_company_core: '^1.2.0' } },
      { version: '3.1.0', flutter: '>=3.22.0', dependencies: { my_company_core: '^1.4.0' } },
    ],
    downloads: 19,
  },
  {
    name: 'api_client_generated',
    description: 'Generated OpenAPI client for the Orders, Billing and Catalog services.',
    releases: [
      { version: '11.4.0', sdk: '^3.4.0', byPublisher: true },
      { version: '12.0.0+5', sdk: '^3.5.0', byPublisher: true },
    ],
    downloads: 17,
  },
  {
    name: 'analysis_rules',
    description: 'Lint rules every Company package and app enables.',
    releases: [
      { version: '3.2.0', sdk: '^3.0.0' },
      { version: '4.0.1', sdk: '^3.5.0' },
    ],
    downloads: 15,
  },
  {
    name: 'feature_flags',
    description: 'Remote feature flags with local overrides for QA builds.',
    flutter: true,
    releases: [{ version: '0.7.0', flutter: '>=3.22.0' }],
    downloads: 8,
  },
  {
    name: 'l10n_tools',
    description: 'Extracts, checks and merges ARB files across the app repositories.',
    releases: [{ version: '2.3.0', sdk: '^3.4.0' }],
    downloads: 6,
  },
  {
    name: 'geo_utils',
    description: 'Distance, bounding boxes and geohash helpers.',
    releases: [{ version: '1.0.0', sdk: '^3.0.0' }],
    downloads: 3,
  },
  {
    name: 'legacy_auth',
    description: 'Username and password sign-in against the old identity server.',
    flutter: true,
    releases: [
      { version: '2.4.0', flutter: '>=3.10.0' },
      { version: '2.4.3', flutter: '>=3.10.0' },
    ],
    downloads: 2,
  },
]

function pubspec(pkg: PackageSeed, release: Release) {
  const lines = [
    `name: ${pkg.name}`,
    `description: ${pkg.description}`,
    `version: ${release.version}`,
    'repository: https://git.company.example/mobile/' + pkg.name,
    'environment:',
    `  sdk: '${release.sdk ?? '^3.5.0'}'`,
  ]
  if (release.flutter) lines.push(`  flutter: '${release.flutter}'`)
  const dependencies = release.dependencies ?? {}
  if (pkg.flutter || Object.keys(dependencies).length) {
    lines.push('dependencies:')
    if (pkg.flutter) lines.push('  flutter:', '    sdk: flutter')
    for (const [name, constraint] of Object.entries(dependencies)) {
      lines.push(`  ${name}: '${constraint}'`)
    }
  }
  if (pkg.flutter) lines.push('flutter:', '  uses-material-design: true')
  return lines.join('\n') + '\n'
}

function readme(pkg: PackageSeed) {
  if (pkg.readme) return pkg.readme
  return `# ${pkg.name}

${pkg.description}

## Usage

\`\`\`dart
import 'package:${pkg.name}/${pkg.name}.dart';
\`\`\`

## Features

- Documented public API
- Tested on the Company CI
`
}

function changelog(pkg: PackageSeed, upTo: number) {
  return pkg.releases
    .slice(0, upTo + 1)
    .reverse()
    .map((r) => `## ${r.version}\n\n- Release ${r.version} of ${pkg.name}.\n`)
    .join('\n')
}

/** A .tar.gz of the fixture with the pubspec, README and CHANGELOG of [release]. */
function archive(dir: string, pkg: PackageSeed, index: number) {
  const release = pkg.releases[index]
  const root = join(dir, `${pkg.name}-${release.version}`)
  mkdirSync(join(root, 'lib'), { recursive: true })
  writeFileSync(join(root, 'pubspec.yaml'), pubspec(pkg, release))
  writeFileSync(join(root, 'README.md'), readme(pkg))
  writeFileSync(join(root, 'CHANGELOG.md'), changelog(pkg, index))
  copyFileSync(join(fixture, 'LICENSE'), join(root, 'LICENSE'))
  writeFileSync(
    join(root, 'lib', `${pkg.name}.dart`),
    readFileSync(join(fixture, 'lib', 'e2e_demo.dart')),
  )
  const file = `${root}.tar.gz`
  execFileSync(
    'tar',
    ['-czf', file, '-C', root, 'pubspec.yaml', 'README.md', 'CHANGELOG.md', 'LICENSE', 'lib'],
    {
      env: { ...process.env, COPYFILE_DISABLE: '1' },
    },
  )
  return readFileSync(file)
}

async function ok<T>(response: Awaited<ReturnType<APIRequestContext['get']>>): Promise<T> {
  expect(response.ok(), `${response.url()}: ${response.status()} ${await response.text()}`).toBe(
    true,
  )
  return (await response.json()) as T
}

/** A logged-in API session, with the CSRF header the cookie needs. */
async function session(baseURL: string, account: Account) {
  const api = await request.newContext({ baseURL })
  const { csrfToken } = await ok<{ csrfToken: string }>(
    await api.post('/webapi/login', { data: account }),
  )
  const headers = { 'X-CSRF-Token': csrfToken }
  return {
    api,
    get: <T>(path: string) => api.get(path).then((r) => ok<T>(r)),
    send: <T>(method: 'post' | 'put' | 'patch' | 'delete', path: string, data?: unknown) =>
      api[method](path, { headers, data }).then((r) => ok<T>(r)),
  }
}

async function createToken(
  s: Awaited<ReturnType<typeof session>>,
  name: string,
  scopes: string[],
  expiresIn: string,
) {
  return s.send<{ token: { id: string }; secret: string }>('post', '/webapi/tokens', {
    name,
    scopes,
    expiresIn,
  })
}

async function publish(baseURL: string, token: string, bytes: Buffer) {
  const api = await request.newContext({
    baseURL,
    extraHTTPHeaders: { Authorization: `Bearer ${token}` },
  })
  try {
    const { url, fields } = await ok<{ url: string; fields?: Record<string, string> }>(
      await api.get('/api/packages/versions/new'),
    )
    const upload = await api.post(url, {
      multipart: {
        ...fields,
        file: { name: 'package.tar.gz', mimeType: 'application/gzip', buffer: bytes },
      },
      maxRedirects: 0,
    })
    const finish = upload.headers()['location']
    expect(finish, `upload: ${upload.status()} ${await upload.text()}`).toBeTruthy()
    expect(finish).not.toContain('error=')
    await ok(await api.get(finish))
  } finally {
    await api.dispose()
  }
}

/** Answers 204 to every webhook delivery. */
async function receiver(): Promise<{ server: Server; url: string }> {
  const server = createServer((req, res) => {
    req.resume()
    req.on('end', () => {
      res.statusCode = 204
      res.end()
    })
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const { port } = server.address() as AddressInfo
  return { server, url: `http://127.0.0.1:${port}/hooks/unpub` }
}

const hookDescription = 'Rebuild apps that depend on a new version'

/** Seeds the registry once and answers the id of the delivered webhook. */
export async function seed(baseURL: string, admin: Account): Promise<string> {
  const ada = await session(baseURL, admin)
  const existing = await ada.get<{ items: { id: string; description: string }[] }>(
    '/webapi/webhooks',
  )
  const seeded = existing.items.find((hook) => hook.description === hookDescription)
  if (seeded) {
    await ada.api.dispose()
    return seeded.id
  }
  const work = mkdtempSync(join(tmpdir(), 'unpub-seed-'))
  const hooks = await receiver()
  try {
    // The administrator's name, users of every role, one disabled.
    const me = await ada.get<{ user: { id: string } }>('/webapi/me')
    await ada.send('patch', `/webapi/users/${me.user.id}`, { displayName: 'Ada Lovelace' })
    const users = [
      {
        email: publisher.email,
        role: 'publisher',
        displayName: 'Jane Doe',
        password: publisher.password,
      },
      {
        email: reader.email,
        role: 'reader',
        displayName: 'Eva Svobodová',
        password: reader.password,
      },
      { email: 'ci-bot@company.example', role: 'publisher', displayName: 'CI' },
      {
        email: 'lukas.dvorak@company.example',
        role: 'publisher',
        displayName: 'Lukáš Dvořák',
        password: 'lukas-password-1',
      },
      {
        email: 'old.contractor@company.example',
        role: 'reader',
        displayName: 'Contractor',
        password: 'contractor-password-1',
      },
    ]
    const ids: Record<string, string> = {}
    for (const user of users) {
      const created = await ada.send<{ user: { id: string } }>('post', '/webapi/users', user)
      ids[user.email] = created.user.id
    }
    await ada.send('patch', `/webapi/users/${ids['old.contractor@company.example']}`, {
      disabled: true,
    })

    // Tokens of the administrator; one revoked.
    const release = await createToken(ada, 'release-script', ['read', 'publish'], 'never')
    await createToken(ada, 'github-actions', ['read'], '90d')
    const old = await createToken(ada, 'old-macbook', ['read'], '30d')
    await ada.send('delete', `/webapi/tokens/${old.token.id}`)

    const jane = await session(baseURL, publisher)
    const janeToken = await createToken(jane, 'ci-publish', ['read', 'publish'], '1y')
    await jane.api.dispose()

    // Two webhooks before the publishes, so that these are delivered: one to
    // the receiver above, one to a closed port, paused afterwards.
    const delivered = await ada.send<{ webhook: { id: string } }>('post', '/webapi/webhooks', {
      url: hooks.url,
      events: ['package.published', 'version.retracted', 'package.discontinued'],
      description: hookDescription,
    })
    const failing = await ada.send<{ webhook: { id: string } }>('post', '/webapi/webhooks', {
      url: 'http://127.0.0.1:9/hook',
      events: ['package.published'],
      description: 'Retired build server',
    })

    // Packages, in an order that leaves the list sorted like the design.
    for (const pkg of [...packages].reverse()) {
      for (let i = 0; i < pkg.releases.length; i++) {
        const byPublisher = !!pkg.releases[i].byPublisher
        if (byPublisher && i > 0 && !pkg.releases[i - 1].byPublisher) {
          await ada.send('post', `/api/packages/${pkg.name}/uploaders`, { email: publisher.email })
        }
        const token = byPublisher ? janeToken.secret : release.secret
        await publish(baseURL, token, archive(work, pkg, i))
      }
    }
    await ada.send('post', '/api/packages/my_company_core/versions/1.3.0/retract')
    await ada.send('put', '/api/packages/legacy_auth/discontinue', {
      isDiscontinued: true,
      replacedBy: 'company_auth',
    })

    // Downloads as dart pub counts them.
    const pub = await request.newContext({
      baseURL,
      extraHTTPHeaders: { 'User-Agent': 'Dart pub 3.9.0' },
    })
    for (const pkg of packages) {
      const releases = pkg.releases.length
      for (let i = 0; i < releases; i++) {
        const { version } = pkg.releases[i]
        const times = Math.max(1, Math.round(pkg.downloads / (releases - i)))
        for (let n = 0; n < times; n++) {
          const response = await pub.get(
            `/packages/${pkg.name}/versions/${encodeURIComponent(version)}.tar.gz`,
            { maxRedirects: 0 },
          )
          expect(response.status(), `${pkg.name} ${version}`).toBeLessThan(400)
        }
      }
    }
    await pub.dispose()

    // Wait for every delivery to finish, then pause the failing webhook.
    await expect
      .poll(
        async () => {
          let pending = 0
          for (const id of [delivered.webhook.id, failing.webhook.id]) {
            const { deliveries } = await ada.get<{ deliveries: { pending: number } }>(
              `/webapi/webhooks/${id}`,
            )
            pending += deliveries.pending
          }
          return pending
        },
        { timeout: 60_000, intervals: [500] },
      )
      .toBe(0)
    await ada.send('patch', `/webapi/webhooks/${failing.webhook.id}`, { enabled: false })

    return delivered.webhook.id
  } finally {
    hooks.server.closeAllConnections()
    await new Promise((resolve) => hooks.server.close(resolve))
    await ada.api.dispose()
    rmSync(work, { recursive: true, force: true })
  }
}
