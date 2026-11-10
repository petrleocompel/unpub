import type {
  AuditEvent,
  Config,
  Me,
  Package,
  PackageSummary,
  Stats,
  Token,
  User,
  Version,
  Webhook,
} from '@/api/types'

const at = '2026-11-01T10:00:00.000Z'
/** The archive hash of the examples in docs/openapi.yaml. */
export const sha256 = '3b1f0c9e0d4a7b2c5e6f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d'

export function config(overrides: Partial<Config> = {}): Config {
  return {
    version: '3.0.0-dev.6',
    publicUrl: 'https://pub.example.com',
    readAccess: 'public',
    accounts: true,
    upstream: { url: 'https://pub.dev', mode: 'redirect' },
    features: { metrics: true, webhooks: true, spa: true, classic: true },
    ui: { mode: 'spa', basePath: '', classicPath: '/classic' },
    ...overrides,
  }
}

export function user(overrides: Partial<User> = {}): User {
  return {
    id: 'u1',
    email: 'jane.doe@company.example',
    displayName: 'Jane Doe',
    role: 'publisher',
    disabled: false,
    hasPassword: true,
    createdAt: at,
    updatedAt: at,
    lastLoginAt: null,
    ...overrides,
  }
}

export const admin = user({
  id: 'admin',
  email: 'admin@company.example',
  displayName: 'Admin',
  role: 'admin',
})

export function me(account: User = admin, csrfToken = 'csrf-123'): Me {
  return {
    user: account,
    scopes: account.role === 'reader' ? ['read'] : ['read', 'publish'],
    csrfToken,
  }
}

export function summary(name: string, overrides: Partial<PackageSummary> = {}): PackageSummary {
  return {
    name,
    latest: '1.0.0',
    description: `The ${name} package.`,
    updatedAt: at,
    downloads: 42,
    isDiscontinued: false,
    replacedBy: null,
    isFlutter: false,
    private: true,
    versionCount: 3,
    uploaders: ['jane.doe@company.example'],
    ...overrides,
  }
}

export function version(value: string, overrides: Partial<Version> = {}): Version {
  return {
    version: value,
    published: at,
    uploader: 'jane.doe@company.example',
    retracted: false,
    prerelease: value.includes('-'),
    downloads: 10,
    archiveSha256: null,
    createdAt: at,
    isRetracted: false,
    ...overrides,
  }
}

export function pkg(overrides: Partial<Package> = {}): Package {
  return {
    name: 'my_company_core',
    version: '1.4.0',
    latest: '1.4.0',
    description: 'Core utilities.',
    published: at,
    uploader: 'jane.doe@company.example',
    uploaders: ['jane.doe@company.example'],
    versions: [version('2.0.0-beta.3'), version('1.4.0'), version('1.0.0', { retracted: true })],
    readmeHtml:
      '<h1 id="md-core">Core</h1><p>Hello.</p><h2 id="md-usage">Usage</h2><p>Use it.</p><h2 id="md-api">API</h2>',
    changelogHtml: '<h2 id="md-140">1.4.0</h2><ul><li>Faster.</li></ul>',
    readme: '# Core\n\nHello.\n\n## Usage\n\nUse it.\n\n## API\n',
    changelog: '## 1.4.0\n\n- Faster.\n',
    dependencies: [
      { name: 'http', constraint: '^1.0.0', hosted: true, local: false },
      { name: 'my_company_log', constraint: '^2.0.0', hosted: true, local: true },
    ],
    devDependencies: [],
    environment: { sdk: '^3.5.0', flutter: null },
    platforms: [],
    retracted: false,
    retractedAt: null,
    isDiscontinued: false,
    replacedBy: null,
    discontinuedAt: null,
    archiveSha256: sha256,
    downloads: { version: 5, package: 1234 },
    private: true,
    isFlutter: false,
    homepage: null,
    repository: 'https://github.com/company/core',
    issueTracker: null,
    documentation: null,
    license: null,
    ...overrides,
  }
}

export function stats(name = 'my_company_core'): Stats {
  return {
    name,
    total: 1234,
    recent: 30,
    days: Array.from({ length: 30 }, (_, index) => ({
      day: `2026-10-${String(index + 1).padStart(2, '0')}`,
      count: index % 3,
    })),
    versions: [{ version: '1.4.0', downloads: 1000 }],
  }
}

export function token(overrides: Partial<Token> = {}): Token {
  return {
    id: 't1',
    userId: 'admin',
    name: 'laptop',
    prefix: 'up_3f9a',
    scopes: ['read', 'publish'],
    expiresAt: null,
    lastUsedAt: null,
    createdAt: at,
    revokedAt: null,
    ...overrides,
  }
}

export function auditEvent(overrides: Partial<AuditEvent> = {}): AuditEvent {
  return {
    at,
    action: 'package.published',
    actor: 'jane.doe@company.example',
    actorKind: 'token',
    token: 'up_3f9a',
    package: 'my_company_core',
    version: '1.4.0',
    target: null,
    ip: '10.0.0.12',
    details: { sha256 },
    ...overrides,
  }
}

export function webhook(overrides: Partial<Webhook> = {}): Webhook {
  return {
    id: 'w1',
    url: 'https://ci.company.example/hook',
    events: ['package.published'],
    description: 'CI',
    enabled: true,
    createdAt: at,
    updatedAt: at,
    createdBy: 'admin@company.example',
    ...overrides,
  }
}

export function page<T>(items: T[], page = 1, size = 20, total = items.length) {
  return { items, page, size, total }
}
