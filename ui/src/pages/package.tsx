import { useEffect, useRef } from 'react'
import { Archive, Ban, CloudDownload, Download, ExternalLink, FlaskConical } from 'lucide-react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router'
import { usePackage, usePackageStats } from '@/api/queries'
import type { Dependency, Package } from '@/api/types'
import { canManage, hostedUrl, useSession } from '@/auth/session'
import {
  DiscontinuedBadge,
  LatestBadge,
  PrereleaseBadge,
  ProxiedBadge,
  RetractedBadge,
  SdkBadge,
} from '@/components/badges'
import { BarChart } from '@/components/bar-chart'
import { CodeBlock, HashText } from '@/components/copy-button'
import { NativeSelect } from '@/components/native-select'
import { EmptyState, ErrorState, isNotFound } from '@/components/states'
import { DateTime, RelativeTime } from '@/components/time'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Page } from '@/layout/root'
import { formatNumber, isPrerelease } from '@/lib/format'
import { useTitle } from '@/lib/use-title'
import { PackageActionsMenu } from '@/packages/actions-menu'
import { Markdown } from '@/packages/markdown'
import { NotFoundPage } from './errors'

export const packageTabs = ['readme', 'changelog', 'versions', 'install', 'stats'] as const
export type PackageTab = (typeof packageTabs)[number]
const tabLabels: Record<PackageTab, string> = {
  readme: 'README',
  changelog: 'Changelog',
  versions: 'Versions',
  install: 'Install',
  stats: 'Stats',
}

export function packagePath(name: string, version?: string) {
  const base = `/packages/${encodeURIComponent(name)}`
  return version ? `${base}/versions/${encodeURIComponent(version)}` : base
}

export function PackagePage({ defaultTab = 'readme' }: { defaultTab?: PackageTab }) {
  const { name = '', version } = useParams()
  const [params] = useSearchParams()
  const navigate = useNavigate()
  const pkg = usePackage(name, version)
  const { config } = useSession()
  useTitle(version ? `${name} ${version}` : name)

  const tabParam = params.get('tab') as PackageTab | null
  const tab: PackageTab = tabParam && packageTabs.includes(tabParam) ? tabParam : defaultTab
  const shownTab = useRef(tab)
  useEffect(() => {
    shownTab.current = tab
  })

  if (pkg.isPending) return <PackageSkeleton />
  if (pkg.isError) {
    if (isNotFound(pkg.error)) {
      return version ? (
        <NotFoundPage what="version" />
      ) : (
        <>
          <NotFoundPage what="package" />
          {config.upstream.mode === 'redirect' && (
            <p className="-mt-12 pb-12 text-center text-sm text-muted-foreground">
              It may be on{' '}
              <a
                className="text-primary underline underline-offset-4"
                href={`${config.upstream.url.replace(/\/+$/, '')}/packages/${encodeURIComponent(name)}`}
              >
                {new URL(config.upstream.url).host}
              </a>
              .
            </p>
          )}
        </>
      )
    }
    return (
      <Page wide>
        <ErrorState error={pkg.error} onRetry={() => void pkg.refetch()} />
      </Page>
    )
  }

  const data = pkg.data
  return (
    <Page wide>
      <div className="grid gap-6">
        <PackageHeader pkg={data} />
        <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_18rem]">
          <Tabs
            value={tab}
            onValueChange={(value) => {
              // A click reports the tab twice, on press and on focus.
              if (value === shownTab.current) return
              shownTab.current = value as PackageTab
              const next = new URLSearchParams(params)
              if (value === 'readme') next.delete('tab')
              else next.set('tab', value)
              const search = next.toString()
              // The package URL, also from the stats alias; a new entry, so Back
              // returns to the previous tab.
              navigate({
                pathname: packagePath(name, version),
                search: search ? `?${search}` : '',
              })
            }}
            className="min-w-0"
          >
            <TabsList className="h-auto w-full flex-wrap justify-start sm:w-auto">
              {packageTabs.map((value) => (
                <TabsTrigger key={value} value={value}>
                  {tabLabels[value]}
                </TabsTrigger>
              ))}
            </TabsList>
            <TabsContent value="readme" className="pt-4">
              {data.readmeHtml ? (
                <Markdown html={data.readmeHtml} toc label="README" />
              ) : (
                <EmptyState title="No README">This version has no README.md.</EmptyState>
              )}
            </TabsContent>
            <TabsContent value="changelog" className="pt-4">
              {data.changelogHtml ? (
                <Markdown html={data.changelogHtml} toc label="Changelog" />
              ) : (
                <EmptyState title="No changelog">This version has no CHANGELOG.md.</EmptyState>
              )}
            </TabsContent>
            <TabsContent value="versions" className="pt-4">
              <VersionsTable pkg={data} />
            </TabsContent>
            <TabsContent value="install" className="pt-4">
              <InstallTab pkg={data} />
            </TabsContent>
            <TabsContent value="stats" className="pt-4">
              <StatsTab name={data.name} />
            </TabsContent>
          </Tabs>
          <Sidebar pkg={data} />
        </div>
      </div>
    </Page>
  )
}

function PackageSkeleton() {
  return (
    <Page wide>
      <div aria-busy="true" className="grid gap-6">
        <span className="sr-only">Loading the package…</span>
        <div className="grid gap-3">
          <Skeleton className="h-9 w-72" />
          <Skeleton className="h-4 w-96 max-w-full" />
          <Skeleton className="h-5 w-48" />
        </div>
        <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_18rem]">
          <div className="grid gap-3">
            <Skeleton className="h-9 w-96 max-w-full" />
            <Skeleton className="h-4 w-full" />
            <Skeleton className="h-4 w-11/12" />
            <Skeleton className="h-4 w-4/5" />
            <Skeleton className="h-32 w-full" />
          </div>
          <div className="grid content-start gap-3">
            <Skeleton className="h-24 w-full" />
            <Skeleton className="h-32 w-full" />
          </div>
        </div>
      </div>
    </Page>
  )
}

function PackageHeader({ pkg }: { pkg: Package }) {
  const { me, config } = useSession()
  const isLatest = pkg.version === pkg.latest
  const prerelease = isPrerelease(pkg.version)
  const upstream = config.upstream.url.replace(/\/+$/, '')
  return (
    <header className="grid gap-3">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="grid gap-1">
          <h1 className="flex flex-wrap items-baseline gap-x-3 text-3xl font-semibold break-all">
            {pkg.name}{' '}
            <span className="font-mono text-xl font-normal text-muted-foreground">
              {pkg.version}
            </span>
          </h1>
          {pkg.description && <p className="max-w-3xl text-muted-foreground">{pkg.description}</p>}
        </div>
        {canManage(me, pkg) && <PackageActionsMenu pkg={pkg} />}
      </div>
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2 text-sm text-muted-foreground">
        <span>
          Published <RelativeTime value={pkg.published} />
        </span>
        {pkg.uploader && <span>by {pkg.uploader}</span>}
        <span className="flex items-center gap-1">
          <Download aria-hidden className="size-3.5" />
          {formatNumber(pkg.downloads.package)} downloads
        </span>
        <span className="flex flex-wrap gap-1.5">
          <SdkBadge flutter={pkg.isFlutter} />
          {isLatest && <LatestBadge />}
          {prerelease && <PrereleaseBadge />}
          {pkg.retracted && <RetractedBadge />}
          {pkg.isDiscontinued && <DiscontinuedBadge />}
          {!pkg.private && <ProxiedBadge />}
        </span>
      </div>
      {pkg.isDiscontinued && (
        <Alert>
          <Archive aria-hidden />
          <AlertTitle>This package is discontinued</AlertTitle>
          <AlertDescription>
            {pkg.replacedBy ? (
              <p>
                Use{' '}
                <Link
                  to={packagePath(pkg.replacedBy)}
                  className="font-medium text-primary underline underline-offset-4"
                >
                  {pkg.replacedBy}
                </Link>{' '}
                instead.
              </p>
            ) : (
              <p>It is no longer maintained.</p>
            )}
          </AlertDescription>
        </Alert>
      )}
      {pkg.retracted && (
        <Alert variant="destructive">
          <Ban aria-hidden />
          <AlertTitle>Version {pkg.version} is retracted</AlertTitle>
          <AlertDescription>
            <p>
              pub does not pick it for new resolutions.{' '}
              <Link to={packagePath(pkg.name)} className="underline underline-offset-4">
                See the latest version, {pkg.latest}
              </Link>
              .
            </p>
          </AlertDescription>
        </Alert>
      )}
      {prerelease && !pkg.retracted && (
        <Alert>
          <FlaskConical aria-hidden />
          <AlertTitle>{pkg.version} is a prerelease</AlertTitle>
          <AlertDescription>
            <p>
              {isLatest
                ? 'There is no stable version yet.'
                : `The latest stable version is ${pkg.latest}.`}
            </p>
          </AlertDescription>
        </Alert>
      )}
      {!pkg.private && (
        <Alert>
          <CloudDownload aria-hidden />
          <AlertTitle>Proxied from {new URL(upstream).host}</AlertTitle>
          <AlertDescription>
            <p>
              This server keeps a copy.{' '}
              <a
                href={`${upstream}/packages/${encodeURIComponent(pkg.name)}`}
                className="underline underline-offset-4"
              >
                See it on {new URL(upstream).host}
              </a>
              .
            </p>
          </AlertDescription>
        </Alert>
      )}
    </header>
  )
}

function VersionsTable({ pkg }: { pkg: Package }) {
  return (
    <div className="overflow-x-auto rounded-lg border">
      <Table>
        <caption className="sr-only">Versions of {pkg.name}, highest first</caption>
        <TableHeader>
          <TableRow>
            <TableHead scope="col">Version</TableHead>
            <TableHead scope="col">Published</TableHead>
            <TableHead scope="col">Uploader</TableHead>
            <TableHead scope="col" className="text-right">
              Downloads
            </TableHead>
            <TableHead scope="col">SHA-256</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {pkg.versions.map((version) => (
            <TableRow
              key={version.version}
              data-current={version.version === pkg.version || undefined}
              className="data-[current]:bg-muted/50"
            >
              <TableCell>
                <div className="flex flex-wrap items-center gap-2">
                  <Link
                    to={packagePath(pkg.name, version.version)}
                    className="font-mono font-medium text-primary hover:underline"
                    aria-current={version.version === pkg.version ? 'page' : undefined}
                  >
                    {version.version}
                  </Link>
                  {version.version === pkg.latest && <LatestBadge />}
                  {version.prerelease && <PrereleaseBadge />}
                  {version.retracted && <RetractedBadge />}
                </div>
              </TableCell>
              <TableCell>
                <DateTime value={version.published} date />
              </TableCell>
              <TableCell className="max-w-56 truncate">{version.uploader ?? '–'}</TableCell>
              <TableCell className="text-right tabular-nums">
                {formatNumber(version.downloads)}
              </TableCell>
              <TableCell>
                {version.version === pkg.version && pkg.archiveSha256 ? (
                  <HashText hash={pkg.archiveSha256} label={`SHA-256 of ${version.version}`} />
                ) : (
                  <Link
                    to={`${packagePath(pkg.name, version.version)}?tab=versions`}
                    className="text-xs text-muted-foreground hover:underline"
                  >
                    Show
                  </Link>
                )}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  )
}

function InstallTab({ pkg }: { pkg: Package }) {
  const { config } = useSession()
  const url = hostedUrl(config)
  const constraint = `^${pkg.latest}`
  const pinned = pkg.version !== pkg.latest ? pkg.version : null
  return (
    <div className="grid gap-6">
      {config.readAccess === 'authenticated' && (
        <section className="grid gap-2">
          <h2 className="font-semibold">Add a token</h2>
          <p className="text-sm text-muted-foreground">
            This server needs a token to read packages. Create one on your{' '}
            <Link to="/account" className="text-primary underline underline-offset-4">
              account page
            </Link>{' '}
            and add it to the pub client once:
          </p>
          <CodeBlock code={`dart pub token add ${url}`} label="the token command" />
        </section>
      )}
      <section className="grid gap-2">
        <h2 className="font-semibold">With Dart</h2>
        <CodeBlock
          code={`dart pub add ${pkg.name}${pinned ? `:${pinned}` : ''} --hosted-url ${url}`}
          label="the dart pub add command"
        />
      </section>
      <section className="grid gap-2">
        <h2 className="font-semibold">With Flutter</h2>
        <CodeBlock
          code={`flutter pub add ${pkg.name}${pinned ? `:${pinned}` : ''} --hosted-url ${url}`}
          label="the flutter pub add command"
        />
      </section>
      <section className="grid gap-2">
        <h2 className="font-semibold">In pubspec.yaml</h2>
        <CodeBlock
          code={`dependencies:\n  ${pkg.name}:\n    hosted: ${url}\n    version: ${pinned ?? constraint}`}
          label="the pubspec snippet"
        />
      </section>
      <p className="text-sm text-muted-foreground">
        Or set <code className="font-mono">PUB_HOSTED_URL={url}</code> to use this server for every
        package it has.
      </p>
    </div>
  )
}

function StatsTab({ name }: { name: string }) {
  const stats = usePackageStats(name)
  if (stats.isPending) {
    return (
      <div aria-busy="true" className="grid gap-4">
        <span className="sr-only">Loading statistics…</span>
        <Skeleton className="h-20 w-full" />
        <Skeleton className="h-44 w-full" />
      </div>
    )
  }
  if (stats.isError) return <ErrorState error={stats.error} onRetry={() => void stats.refetch()} />
  const data = stats.data
  return (
    <div className="grid gap-6">
      <dl className="grid grid-cols-2 gap-4 sm:max-w-md">
        <div className="rounded-lg border p-4">
          <dt className="text-sm text-muted-foreground">Total downloads</dt>
          <dd className="text-2xl font-semibold tabular-nums">{formatNumber(data.total)}</dd>
        </div>
        <div className="rounded-lg border p-4">
          <dt className="text-sm text-muted-foreground">Last 30 days</dt>
          <dd className="text-2xl font-semibold tabular-nums">{formatNumber(data.recent)}</dd>
        </div>
      </dl>
      <section className="grid gap-3" aria-labelledby="stats-days">
        <h2 id="stats-days" className="font-semibold">
          Downloads per day
        </h2>
        <BarChart
          data={data.days}
          label={`Downloads per day of ${name} for the last 30 days. The table below has the numbers.`}
        />
        <details className="rounded-lg border">
          <summary className="cursor-pointer px-4 py-2 text-sm font-medium">
            Show as a table
          </summary>
          <Table>
            <caption className="sr-only">Downloads per day, oldest first</caption>
            <TableHeader>
              <TableRow>
                <TableHead scope="col">Day</TableHead>
                <TableHead scope="col" className="text-right">
                  Downloads
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {data.days.map((day) => (
                <TableRow key={day.day}>
                  <TableCell>
                    <DateTime value={day.day} date />
                  </TableCell>
                  <TableCell className="text-right tabular-nums">
                    {formatNumber(day.count)}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </details>
      </section>
      <section className="grid gap-3" aria-labelledby="stats-versions">
        <h2 id="stats-versions" className="font-semibold">
          Downloads per version
        </h2>
        {data.versions.length === 0 ? (
          <p className="text-sm text-muted-foreground">No downloads yet.</p>
        ) : (
          <div className="overflow-x-auto rounded-lg border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead scope="col">Version</TableHead>
                  <TableHead scope="col" className="text-right">
                    Downloads
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.versions.map((version) => (
                  <TableRow key={version.version}>
                    <TableCell className="font-mono">
                      <Link
                        to={packagePath(name, version.version)}
                        className="text-primary hover:underline"
                      >
                        {version.version}
                      </Link>
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {formatNumber(version.downloads)}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </section>
    </div>
  )
}

function Sidebar({ pkg }: { pkg: Package }) {
  const navigate = useNavigate()
  const [params] = useSearchParams()
  const latest = pkg.versions.find((version) => version.version === pkg.latest)
  const links = [
    ['Repository', pkg.repository],
    ['Homepage', pkg.homepage],
    ['Issue tracker', pkg.issueTracker],
    ['Documentation', pkg.documentation],
  ].filter((link): link is [string, string] => !!link[1] && /^https?:\/\//.test(link[1]))
  const tab = params.get('tab')

  return (
    <aside aria-label="Package details" className="grid content-start gap-6 text-sm">
      <SidebarSection title="Latest version">
        <p>
          <Link
            to={packagePath(pkg.name)}
            className="font-mono font-medium text-primary hover:underline"
          >
            {pkg.latest}
          </Link>
          {latest && (
            <span className="text-muted-foreground">
              {' · '}
              <RelativeTime value={latest.published} />
            </span>
          )}
        </p>
      </SidebarSection>
      <SidebarSection title="Version">
        <label htmlFor="version-select" className="sr-only">
          Show version
        </label>
        <NativeSelect
          id="version-select"
          value={pkg.version}
          className="w-full font-mono"
          onChange={(event) => {
            const version = event.target.value
            const path =
              version === pkg.latest ? packagePath(pkg.name) : packagePath(pkg.name, version)
            navigate(tab ? `${path}?tab=${tab}` : path)
          }}
        >
          {pkg.versions.map((version) => (
            <option key={version.version} value={version.version}>
              {version.version}
              {version.version === pkg.latest ? ' (latest)' : ''}
              {version.prerelease ? ' (prerelease)' : ''}
              {version.retracted ? ' (retracted)' : ''}
            </option>
          ))}
        </NativeSelect>
      </SidebarSection>
      {(pkg.environment.sdk || pkg.environment.flutter) && (
        <SidebarSection title="SDK constraints">
          <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
            {pkg.environment.sdk && (
              <>
                <dt className="text-muted-foreground">Dart</dt>
                <dd className="font-mono">{pkg.environment.sdk}</dd>
              </>
            )}
            {pkg.environment.flutter && (
              <>
                <dt className="text-muted-foreground">Flutter</dt>
                <dd className="font-mono">{pkg.environment.flutter}</dd>
              </>
            )}
          </dl>
        </SidebarSection>
      )}
      {pkg.platforms.length > 0 && (
        <SidebarSection title="Platforms">
          <ul className="flex flex-wrap gap-1.5">
            {pkg.platforms.map((platform) => (
              <li key={platform} className="rounded-md border px-2 py-0.5 text-xs">
                {platform}
              </li>
            ))}
          </ul>
        </SidebarSection>
      )}
      {links.length > 0 && (
        <SidebarSection title="Links">
          <ul className="grid gap-1">
            {links.map(([label, href]) => (
              <li key={label}>
                <a
                  href={href}
                  rel="nofollow noopener"
                  className="inline-flex items-center gap-1 text-primary hover:underline"
                >
                  {label}
                  <ExternalLink aria-hidden className="size-3" />
                </a>
              </li>
            ))}
          </ul>
        </SidebarSection>
      )}
      {pkg.license && (
        <SidebarSection title="License">
          <p>{pkg.license}</p>
        </SidebarSection>
      )}
      <Dependencies title="Dependencies" items={pkg.dependencies} />
      <Dependencies title="Dev dependencies" items={pkg.devDependencies} />
      <SidebarSection title="Uploaders">
        {pkg.uploaders.length === 0 ? (
          <p className="text-muted-foreground">None</p>
        ) : (
          <ul className="grid gap-1">
            {pkg.uploaders.map((uploader) => (
              <li key={uploader} className="truncate">
                {uploader}
              </li>
            ))}
          </ul>
        )}
      </SidebarSection>
    </aside>
  )
}

function SidebarSection({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="grid gap-2">
      <h2 className="text-xs font-semibold tracking-wide text-muted-foreground uppercase">
        {title}
      </h2>
      {children}
    </section>
  )
}

function Dependencies({ title, items }: { title: string; items: Dependency[] }) {
  const { config } = useSession()
  if (items.length === 0) return null
  const upstream = config.upstream.url.replace(/\/+$/, '')
  return (
    <SidebarSection title={title}>
      <ul className="grid gap-1">
        {items.map((dependency) => (
          <li key={dependency.name} className="flex flex-wrap items-baseline gap-x-2">
            {dependency.local ? (
              <Link to={packagePath(dependency.name)} className="text-primary hover:underline">
                {dependency.name}
              </Link>
            ) : dependency.hosted ? (
              <a
                href={`${upstream}/packages/${encodeURIComponent(dependency.name)}`}
                className="text-primary hover:underline"
              >
                {dependency.name}
              </a>
            ) : (
              <span>{dependency.name}</span>
            )}
            {dependency.constraint && (
              <span className="font-mono text-xs text-muted-foreground">
                {dependency.constraint}
              </span>
            )}
          </li>
        ))}
      </ul>
    </SidebarSection>
  )
}
