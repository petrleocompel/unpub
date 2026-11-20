import { useEffect, useId, useRef, useState } from 'react'
import {
  Archive,
  Ban,
  BookOpen,
  Bug,
  ChartColumn,
  ChevronRight,
  CloudDownload,
  Code,
  Download,
  ExternalLink,
  FlaskConical,
  House,
  KeyRound,
} from 'lucide-react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router'
import { usePackage, usePackageStats } from '@/api/queries'
import type { Dependency, Package } from '@/api/types'
import { canManage, hostedUrl, useSession } from '@/auth/session'
import {
  DiscontinuedBadge,
  LatestBadge,
  PrereleaseBadge,
  ProxiedBadge,
  ReplacedByBadge,
  RetractedBadge,
  SdkBadge,
} from '@/components/badges'
import { BarChart } from '@/components/bar-chart'
import { Initials } from '@/components/avatar'
import { CodeBlock, CopyButton, HashText } from '@/components/copy-button'
import { NativeSelect } from '@/components/native-select'
import { EmptyState, ErrorState, isNotFound } from '@/components/states'
import { DateTime, RelativeTime } from '@/components/time'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { buttonVariants } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import { SegmentedControl } from '@/components/ui/segmented'
import { Skeleton } from '@/components/ui/skeleton'
import { Switch } from '@/components/ui/switch'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { Tabs, TabsContent, TabsCount, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Page } from '@/layout/root'
import { formatDate, formatNumber, isPrerelease } from '@/lib/format'
import { useTitle } from '@/lib/use-title'
import { cn } from '@/lib/utils'
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
        <NotFoundPage what="version" name={`${name} ${version}`} />
      ) : (
        <NotFoundPage
          what="package"
          name={name}
          upstream={
            config.upstream.mode === 'redirect'
              ? {
                  host: new URL(config.upstream.url).host,
                  href: `${config.upstream.url.replace(/\/+$/, '')}/packages/${encodeURIComponent(name)}`,
                }
              : undefined
          }
        />
      )
    }
    return (
      <Page wide>
        <ErrorState
          title="Could not load the package"
          error={pkg.error}
          onRetry={() => void pkg.refetch()}
        />
      </Page>
    )
  }

  const data = pkg.data
  const withSidebar = tab === 'readme' || tab === 'changelog' || tab === 'install'
  return (
    <Page full>
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
        className="flex-1 gap-0"
      >
        <PackageHeader pkg={data} />
        <div
          className={cn(
            'mx-auto grid w-full max-w-7xl gap-8 px-4 pt-5 pb-10 sm:px-6 sm:pt-7 sm:pb-14',
            withSidebar && 'lg:grid-cols-[minmax(0,1fr)_18.75rem] lg:gap-12',
          )}
        >
          <div className="min-w-0">
            <TabsContent value="readme">
              {data.readmeHtml ? (
                <Markdown html={data.readmeHtml} toc label="README" />
              ) : (
                <EmptyState title="No README">This version has no README.md.</EmptyState>
              )}
            </TabsContent>
            <TabsContent value="changelog">
              {data.changelogHtml ? (
                <Markdown html={data.changelogHtml} toc label="Changelog" />
              ) : (
                <EmptyState title="No changelog">This version has no CHANGELOG.md.</EmptyState>
              )}
            </TabsContent>
            <TabsContent value="versions">
              <VersionsTable pkg={data} />
            </TabsContent>
            <TabsContent value="install">
              <InstallTab pkg={data} />
            </TabsContent>
            <TabsContent value="stats">
              <StatsTab name={data.name} />
            </TabsContent>
          </div>
          {withSidebar && <Sidebar pkg={data} />}
        </div>
      </Tabs>
    </Page>
  )
}

/** The band on --surface that frames the header, notices and tabs. */
function Band({ children }: { children: React.ReactNode }) {
  return (
    <div className="border-b bg-surface">
      <div className="mx-auto grid w-full max-w-7xl gap-3 px-4 pt-5 sm:px-6 sm:pt-7">
        {children}
      </div>
    </div>
  )
}

function PackageSkeleton() {
  return (
    <Page full>
      <div aria-busy="true" aria-live="polite" className="flex-1">
        <span className="sr-only">Loading the package…</span>
        <Band>
          <Skeleton className="h-3 w-40" />
          <Skeleton className="h-8 w-80 max-w-full" />
          <Skeleton className="h-4 w-[32rem] max-w-full" />
          <div className="flex gap-2">
            <Skeleton className="h-5 w-12" />
            <Skeleton className="h-5 w-16" />
          </div>
          <div className="flex gap-4 pt-2 pb-3">
            <Skeleton className="h-3.5 w-16" />
            <Skeleton className="h-3.5 w-20" />
            <Skeleton className="h-3.5 w-16" />
          </div>
        </Band>
        <div className="mx-auto grid w-full max-w-7xl gap-8 px-4 pt-7 sm:px-6 lg:grid-cols-[minmax(0,1fr)_18.75rem] lg:gap-12">
          <div className="grid content-start gap-2.5">
            <Skeleton className="h-5 w-2/5" />
            <Skeleton className="h-3 w-full" />
            <Skeleton className="h-3 w-[96%]" />
            <Skeleton className="h-3 w-[88%]" />
            <Skeleton className="h-24 w-full" />
          </div>
          <div className="grid content-start gap-2.5">
            <Skeleton className="h-9 w-full" />
            <Skeleton className="h-3 w-4/5" />
            <Skeleton className="h-3 w-3/5" />
          </div>
        </div>
      </div>
    </Page>
  )
}

function Dot() {
  return (
    <span aria-hidden className="hidden size-[3px] rounded-full bg-muted-foreground/60 sm:block" />
  )
}

const inlineCode = 'rounded border bg-code px-[5px] py-px font-mono text-[0.88em]'
const link = 'font-medium text-primary hover:underline hover:underline-offset-3'

function PackageHeader({ pkg }: { pkg: Package }) {
  const { me, config } = useSession()
  const { version } = useParams()
  const isLatest = pkg.version === pkg.latest
  const prerelease = isPrerelease(pkg.version)
  const upstream = config.upstream.url.replace(/\/+$/, '')
  const upstreamHost = new URL(upstream).host
  return (
    <Band>
      <nav aria-label="Breadcrumb">
        <ol className="flex flex-wrap items-center gap-1.5 text-[0.8125rem] text-muted-foreground">
          <li>
            <Link to="/packages" className="hover:text-foreground">
              Packages
            </Link>
          </li>
          <li aria-hidden>
            <ChevronRight className="size-3" />
          </li>
          <li>
            {version ? (
              <Link to={packagePath(pkg.name)} className="hover:text-foreground">
                {pkg.name}
              </Link>
            ) : (
              <span aria-current="page" className="text-foreground">
                {pkg.name}
              </span>
            )}
          </li>
          {version && (
            <>
              <li aria-hidden>
                <ChevronRight className="size-3" />
              </li>
              <li>
                <span aria-current="page" className="font-mono text-foreground">
                  {pkg.version}
                </span>
              </li>
            </>
          )}
        </ol>
      </nav>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="flex min-w-0 flex-wrap items-baseline gap-x-3.5 gap-y-1">
          <h1 className="flex min-w-0 flex-wrap items-baseline gap-x-3.5 gap-y-1">
            <span className="text-2xl leading-[1.875rem] font-[650] tracking-[-0.025em] break-words sm:text-[1.875rem] sm:leading-[2.375rem]">
              {pkg.name}
            </span>{' '}
            <span className="font-mono text-[0.9375rem] font-normal text-muted-foreground sm:text-lg">
              {pkg.version}
            </span>
          </h1>
          <CopyButton
            text={`${pkg.name}: ^${pkg.version}`}
            label={`${pkg.name}: ^${pkg.version}`}
            size="icon-xs"
            className="self-center"
          />
        </div>
        {canManage(me, pkg) && <PackageActionsMenu pkg={pkg} />}
      </div>
      {pkg.description && (
        <p className="max-w-[760px] text-[0.9375rem] leading-6 text-muted-foreground">
          {pkg.description}
        </p>
      )}
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-[0.84375rem] text-muted-foreground">
        <span>
          Published{' '}
          <span className="text-foreground">
            <RelativeTime value={pkg.published} />
          </span>
        </span>
        {pkg.uploader && (
          <>
            <Dot />
            <span>
              by <span className="text-foreground">{pkg.uploader}</span>
            </span>
          </>
        )}
        <Dot />
        <span className="flex items-center gap-1">
          <Download aria-hidden className="size-3.5" />
          <b className="font-medium text-foreground tabular-nums">
            {formatNumber(pkg.downloads.package)}
          </b>{' '}
          {pkg.private ? 'downloads' : 'downloads through unpub'}
        </span>
      </div>
      <div className="flex flex-wrap gap-1.5">
        <SdkBadge flutter={pkg.isFlutter} />
        {isLatest && <LatestBadge />}
        {prerelease && <PrereleaseBadge />}
        {pkg.retracted && <RetractedBadge />}
        {pkg.isDiscontinued && <DiscontinuedBadge />}
        {pkg.replacedBy && <ReplacedByBadge name={pkg.replacedBy} />}
        {!pkg.private && <ProxiedBadge />}
      </div>
      {pkg.isDiscontinued && (
        <Alert variant="warning" role="note">
          <Archive aria-hidden />
          <AlertDescription className="block">
            <strong>This package is discontinued.</strong> It gets no more updates.
            {pkg.replacedBy && (
              <>
                {' '}
                Use{' '}
                <Link to={packagePath(pkg.replacedBy)} className={cn(link, 'font-mono')}>
                  {pkg.replacedBy}
                </Link>{' '}
                instead.
              </>
            )}
          </AlertDescription>
        </Alert>
      )}
      {pkg.retracted && (
        <Alert variant="destructive" role="note">
          <Ban aria-hidden />
          <AlertDescription className="block">
            <strong>Version {pkg.version} is retracted.</strong>{' '}
            <code className={inlineCode}>dart pub get</code> no longer picks it for new resolutions;
            lockfiles that already use it keep working. The latest version is{' '}
            <Link to={packagePath(pkg.name)} className={cn(link, 'font-mono')}>
              {pkg.latest}
            </Link>
            .
          </AlertDescription>
        </Alert>
      )}
      {prerelease && !pkg.retracted && (
        <Alert variant="info" role="note">
          <FlaskConical aria-hidden />
          <AlertDescription className="block">
            <strong>{pkg.version} is a prerelease.</strong>{' '}
            {isLatest ? (
              'There is no stable version yet.'
            ) : (
              <>
                The latest stable version is{' '}
                <Link to={packagePath(pkg.name)} className={cn(link, 'font-mono')}>
                  {pkg.latest}
                </Link>
                .
              </>
            )}
          </AlertDescription>
        </Alert>
      )}
      {!pkg.private && (
        <Alert variant="info" role="note">
          <CloudDownload aria-hidden />
          <AlertDescription className="block">
            <strong>Cached from {upstreamHost}.</strong> unpub serves a copy for builds without
            internet access; publishing, retracting and uploaders happen on{' '}
            <a
              href={`${upstream}/packages/${encodeURIComponent(pkg.name)}`}
              className={cn(link, 'inline-flex items-center gap-1')}
            >
              {upstreamHost}/packages/{pkg.name}
              <ExternalLink aria-hidden className="size-3" />
            </a>
            .
          </AlertDescription>
        </Alert>
      )}
      <TabsList variant="line" className="mt-1.5 -mb-px border-b-0">
        {packageTabs.map((value) => (
          <TabsTrigger key={value} value={value}>
            {tabLabels[value]}
            {value === 'versions' && <TabsCount aria-hidden>{pkg.versions.length}</TabsCount>}
          </TabsTrigger>
        ))}
      </TabsList>
    </Band>
  )
}

/** The archive of [version], as the pub client downloads it. The server
 * accepts the session cookie there, so it also works on a private registry. */
export function archivePath(name: string, version: string) {
  return `/packages/${encodeURIComponent(name)}/versions/${encodeURIComponent(version)}.tar.gz`
}

function VersionsTable({ pkg }: { pkg: Package }) {
  const switchId = useId()
  const retracted = pkg.versions.filter((version) => version.retracted).length
  const [showRetracted, setShowRetracted] = useState(false)
  // The version being viewed stays, retracted or not.
  const shown =
    showRetracted || retracted === 0
      ? pkg.versions
      : pkg.versions.filter((version) => !version.retracted || version.version === pkg.version)
  const hidden = pkg.versions.length - shown.length
  return (
    <div className="grid gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 className="text-[1.0625rem] leading-6 font-semibold">
          {pkg.versions.length} {pkg.versions.length === 1 ? 'version' : 'versions'}
        </h2>
        {retracted > 0 && (
          <div className="flex items-center gap-2 text-[0.8125rem]">
            <Switch
              id={switchId}
              checked={showRetracted}
              onCheckedChange={setShowRetracted}
              aria-label="Show retracted versions"
            />
            <Label htmlFor={switchId} aria-hidden className="font-normal">
              Show retracted
            </Label>
          </div>
        )}
      </div>
      <Table containerClassName="rounded-lg border bg-card" stickyFirstColumn>
        <caption className="sr-only">
          Versions of {pkg.name}, highest first
          {hidden > 0 && `, without ${hidden} retracted`}
        </caption>
        <TableHeader>
          <TableRow>
            <TableHead scope="col" aria-sort="descending">
              Version
            </TableHead>
            <TableHead scope="col">Published</TableHead>
            <TableHead scope="col">Uploader</TableHead>
            <TableHead scope="col" className="text-right">
              Downloads
            </TableHead>
            <TableHead scope="col">SHA-256</TableHead>
            <TableHead scope="col">
              <span className="sr-only">Archive</span>
            </TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {shown.map((version) => (
            <TableRow
              key={version.version}
              data-current={version.version === pkg.version || undefined}
              className="data-[current]:bg-surface"
            >
              <TableCell>
                <div className="flex items-center gap-2">
                  <Link
                    to={packagePath(pkg.name, version.version)}
                    className={cn(link, 'font-mono')}
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
                <RelativeTime value={version.published} />
              </TableCell>
              <TableCell className="max-w-56 truncate text-muted-foreground">
                {version.uploader ?? '–'}
              </TableCell>
              <TableCell className="text-right tabular-nums">
                {formatNumber(version.downloads)}
              </TableCell>
              <TableCell>
                <VersionHash pkg={pkg} version={version} />
              </TableCell>
              <TableCell className="text-right">
                {/* A plain link: the archive is a route of the server, not of the client. */}
                <a
                  href={archivePath(pkg.name, version.version)}
                  download
                  aria-label={`Download ${version.version} archive`}
                  title={`Download ${version.version} archive`}
                  className={cn(
                    buttonVariants({ variant: 'ghost', size: 'icon-xs' }),
                    'text-muted-foreground hover:text-foreground',
                  )}
                >
                  <Download aria-hidden />
                </a>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
      <p className="text-xs leading-4 text-muted-foreground">
        Dates are relative; hover or focus for the absolute time. The row of the version you are
        viewing is highlighted.
        {hidden > 0 &&
          ` ${hidden} retracted ${hidden === 1 ? 'version is' : 'versions are'} hidden.`}
      </p>
    </div>
  )
}

/** The short hash of the archive of [version] with a copy button, or a dash
 * when the server does not know it. */
function VersionHash({ pkg, version }: { pkg: Package; version: Package['versions'][number] }) {
  const hash = version.archiveSha256 ?? (version.version === pkg.version ? pkg.archiveSha256 : null)
  if (!hash) {
    return (
      <span className="text-muted-foreground" title="Not known">
        –<span className="sr-only">Not known</span>
      </span>
    )
  }
  return <HashText hash={hash} label={`SHA-256 of ${version.version}`} />
}

function Step({ n, title, children }: { n: number; title: string; children: React.ReactNode }) {
  return (
    <section className="grid gap-3">
      <h2 className="flex items-center gap-2 text-[1.0625rem] leading-6 font-semibold">
        <span
          aria-hidden
          className="grid size-6 shrink-0 place-items-center rounded-full bg-secondary text-xs font-semibold text-secondary-foreground"
        >
          {n}
        </span>
        {title}
      </h2>
      {children}
    </section>
  )
}

function InstallTab({ pkg }: { pkg: Package }) {
  const { config, me } = useSession()
  const url = hostedUrl(config)
  const constraint = `^${pkg.latest}`
  const pinned = pkg.version !== pkg.latest ? pkg.version : null
  const add = `${pkg.name}${pinned ? `:${pinned}` : ''} --hosted-url ${url}`
  return (
    <div className="grid max-w-[820px] gap-8">
      <Step n={1} title="Add it to your app">
        <p className="text-[0.8125rem] text-muted-foreground">
          Run one of these in the directory of your <code className={inlineCode}>pubspec.yaml</code>
          .
        </p>
        <CodeBlock
          title="Dart"
          prompt
          code={`dart pub add ${add}`}
          label="the dart pub add command"
        />
        <CodeBlock
          title="Flutter"
          prompt
          code={`flutter pub add ${add}`}
          label="the flutter pub add command"
        />
      </Step>
      <Step n={2} title="Or edit pubspec.yaml">
        <CodeBlock
          title="pubspec.yaml"
          code={`dependencies:\n  ${pkg.name}:\n    hosted: ${url}\n    version: ${pinned ?? constraint}`}
          label="the pubspec snippet"
        />
      </Step>
      <Step n={3} title="Import it">
        <CodeBlock code={`import 'package:${pkg.name}/${pkg.name}.dart';`} label="the import" />
      </Step>
      {config.readAccess === 'authenticated' && (
        <Alert variant="info" role="note">
          <KeyRound aria-hidden />
          <AlertDescription className="w-full justify-items-stretch gap-2.5">
            <p>
              <strong>Private registry.</strong> Tell <code className={inlineCode}>dart pub</code>{' '}
              your token once.{' '}
              {me ? 'Create a read token on your ' : 'Log in and create a read token on your '}
              <Link to="/account" className={link}>
                account page
              </Link>
              , then run:
            </p>
            <CodeBlock prompt code={`dart pub token add ${url}`} label="the token command" />
          </AlertDescription>
        </Alert>
      )}
      <p className="text-[0.8125rem] text-muted-foreground">
        Or set <code className={inlineCode}>PUB_HOSTED_URL={url}</code> to use this server for every
        package it has.
      </p>
    </div>
  )
}

function StatCard({ label, value, note }: { label: string; value: string; note?: string }) {
  return (
    <div className="rounded-lg border bg-card px-4.5 py-4">
      <dt className="text-[0.8125rem] text-muted-foreground">{label}</dt>
      <dd className="text-[1.625rem] leading-8 font-semibold tracking-[-0.02em] tabular-nums">
        {value}
      </dd>
      {note && <dd className="text-xs text-muted-foreground">{note}</dd>}
    </div>
  )
}

function StatsTab({ name }: { name: string }) {
  const stats = usePackageStats(name)
  const [view, setView] = useState<'chart' | 'table'>('chart')
  if (stats.isPending) {
    return (
      <div aria-busy="true" aria-live="polite" className="grid gap-6">
        <span className="sr-only">Loading statistics…</span>
        <div className="grid gap-4 sm:grid-cols-3">
          <Skeleton className="h-24 w-full" />
          <Skeleton className="h-24 w-full" />
          <Skeleton className="h-24 w-full" />
        </div>
        <Skeleton className="h-72 w-full" />
      </div>
    )
  }
  if (stats.isError) {
    return (
      <ErrorState
        title="Could not load the statistics"
        error={stats.error}
        onRetry={() => void stats.refetch()}
      />
    )
  }
  const data = stats.data
  const busiest = data.days.reduce<(typeof data.days)[number] | null>(
    (best, day) => (day.count > (best?.count ?? 0) ? day : best),
    null,
  )
  const top = Math.max(1, ...data.versions.map((version) => version.downloads))
  const first = data.days[0]
  const last = data.days[data.days.length - 1]
  return (
    <div className="grid gap-6">
      <dl className="grid gap-4 sm:grid-cols-3">
        <StatCard label="Total downloads" value={formatNumber(data.total)} />
        <StatCard label="Last 30 days" value={formatNumber(data.recent)} />
        <StatCard
          label="Busiest day"
          value={busiest ? formatNumber(busiest.count) : '–'}
          note={busiest ? formatDate(busiest.day) : 'No downloads in 30 days'}
        />
      </dl>
      <section className="rounded-lg border bg-card" aria-labelledby="stats-days">
        <div className="flex flex-wrap items-center justify-between gap-3 border-b px-3.5 py-3.5 sm:px-4.5">
          <h2 id="stats-days" className="text-[0.9375rem] leading-[1.375rem] font-semibold">
            Downloads per day, last 30 days
          </h2>
          <SegmentedControl
            label="Display"
            value={view}
            onValueChange={setView}
            options={[
              {
                value: 'chart',
                label: (
                  <>
                    <ChartColumn aria-hidden /> Chart
                  </>
                ),
              },
              { value: 'table', label: 'Table' },
            ]}
          />
        </div>
        {view === 'chart' ? (
          <div className="px-3.5 py-4.5 sm:px-4.5">
            <BarChart
              data={data.days}
              label={`Downloads per day of ${name}${first && last ? ` from ${formatDate(first.day)} to ${formatDate(last.day)}` : ''}: ${formatNumber(data.recent)} in total${busiest ? `, busiest ${formatDate(busiest.day)} with ${formatNumber(busiest.count)}` : ''}. The Table view lists every day.`}
            />
          </div>
        ) : (
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
        )}
      </section>
      <section className="rounded-lg border bg-card" aria-labelledby="stats-versions">
        <div className="flex flex-wrap items-center justify-between gap-3 border-b px-3.5 py-3.5 sm:px-4.5">
          <h2 id="stats-versions" className="text-[0.9375rem] leading-[1.375rem] font-semibold">
            Downloads per version
          </h2>
          <span className="text-xs text-muted-foreground">all time</span>
        </div>
        <div className="px-3.5 py-4.5 sm:px-4.5">
          {data.versions.length === 0 ? (
            <p className="text-[0.8125rem] text-muted-foreground">No downloads yet.</p>
          ) : (
            <ul className="grid gap-3">
              {data.versions.map((version) => (
                <li
                  key={version.version}
                  className="grid grid-cols-[minmax(5rem,auto)_minmax(0,1fr)_auto] items-center gap-3 sm:grid-cols-[7.5rem_minmax(0,1fr)_4.5rem]"
                >
                  <Link
                    to={packagePath(name, version.version)}
                    className={cn(link, 'truncate font-mono text-[0.8125rem]')}
                  >
                    {version.version}
                  </Link>
                  <Meter value={version.downloads / top} />
                  <span className="text-right text-[0.8125rem] tabular-nums">
                    {formatNumber(version.downloads)}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>
      </section>
    </div>
  )
}

/** A 6 px bar filled to [value] (0 to 1), drawn as SVG: no style attribute. */
function Meter({ value }: { value: number }) {
  const width = Math.max(0, Math.min(100, value * 100))
  return (
    <svg
      aria-hidden
      viewBox="0 0 100 6"
      preserveAspectRatio="none"
      className="h-1.5 w-full overflow-hidden rounded-full"
    >
      <rect width={100} height={6} className="fill-muted" />
      <rect width={width} height={6} className="fill-chart-bar" />
    </svg>
  )
}

const linkIcons = {
  Repository: Code,
  Homepage: House,
  'Issue tracker': Bug,
  Documentation: BookOpen,
} as const

function Sidebar({ pkg }: { pkg: Package }) {
  const navigate = useNavigate()
  const [params] = useSearchParams()
  const links = (
    [
      ['Repository', pkg.repository],
      ['Homepage', pkg.homepage],
      ['Issue tracker', pkg.issueTracker],
      ['Documentation', pkg.documentation],
    ] as const
  ).filter(
    (link): link is readonly [keyof typeof linkIcons, string] =>
      !!link[1] && /^https?:\/\//.test(link[1]),
  )
  const tab = params.get('tab')
  const newest = pkg.versions[0]
  const newerPrerelease =
    newest && newest.prerelease && newest.version !== pkg.latest ? newest.version : null

  return (
    <aside
      aria-label="Package details"
      className="grid content-start gap-6 border-t pt-6 lg:border-t-0 lg:pt-0"
    >
      <SidebarSection title="Version">
        <label htmlFor="version-select" className="sr-only">
          Show version
        </label>
        <NativeSelect
          id="version-select"
          value={pkg.version}
          className="w-full"
          onChange={(event) => {
            const version = event.target.value
            const path =
              version === pkg.latest ? packagePath(pkg.name) : packagePath(pkg.name, version)
            navigate(tab ? `${path}?tab=${tab}` : path)
          }}
        >
          {pkg.versions.map((version) => (
            <option key={version.version} value={version.version}>
              {[
                version.version,
                version.version === pkg.latest && 'latest',
                version.prerelease && 'prerelease',
                version.retracted && 'retracted',
              ]
                .filter(Boolean)
                .join(' · ')}
            </option>
          ))}
        </NativeSelect>
        <p className="text-xs text-muted-foreground">
          {pkg.versions.length} {pkg.versions.length === 1 ? 'version' : 'versions'}
          {newerPrerelease && ` · newest prerelease ${newerPrerelease}`}
        </p>
      </SidebarSection>
      <SidebarSection title="Metadata">
        <dl className="grid gap-1.5 text-[0.84375rem]">
          <div className="flex justify-between gap-3">
            <dt className="text-muted-foreground">Dart SDK</dt>
            {pkg.environment.sdk ? (
              <dd className="text-right font-mono text-[0.8125rem]">{pkg.environment.sdk}</dd>
            ) : (
              <dd className="text-muted-foreground">any</dd>
            )}
          </div>
          <div className="flex justify-between gap-3">
            <dt className="text-muted-foreground">Flutter</dt>
            {pkg.environment.flutter ? (
              <dd className="text-right font-mono text-[0.8125rem]">{pkg.environment.flutter}</dd>
            ) : (
              <dd className="text-muted-foreground">{pkg.isFlutter ? 'any' : 'not required'}</dd>
            )}
          </div>
          <div className="flex justify-between gap-3">
            <dt className="text-muted-foreground">License</dt>
            {pkg.license ? (
              <dd className="text-right">{pkg.license}</dd>
            ) : (
              <dd className="text-muted-foreground">none given</dd>
            )}
          </div>
        </dl>
        {pkg.platforms.length > 0 && (
          <ul className="flex flex-wrap gap-1" aria-label="Platforms">
            {pkg.platforms.map((platform) => (
              <li
                key={platform}
                className="inline-flex h-5.5 items-center rounded-[5px] border bg-muted px-[7px] font-mono text-[0.71875rem]"
              >
                {platform}
              </li>
            ))}
          </ul>
        )}
      </SidebarSection>
      <Dependencies title="Dependencies" items={pkg.dependencies} />
      <Dependencies title="Dev dependencies" items={pkg.devDependencies} />
      <SidebarSection title="Uploaders">
        {pkg.uploaders.length === 0 ? (
          <p className="text-[0.84375rem] text-muted-foreground">None</p>
        ) : (
          <ul className="grid gap-1.5">
            {pkg.uploaders.map((uploader) => (
              <li key={uploader} className="flex min-w-0 items-center gap-2 text-[0.84375rem]">
                <Initials email={uploader} />
                <span className="truncate">{uploader}</span>
              </li>
            ))}
          </ul>
        )}
      </SidebarSection>
      {links.length > 0 && (
        <SidebarSection title="Links">
          <ul className="grid gap-1.5 text-[0.84375rem]">
            {links.map(([label, href]) => {
              const Icon = linkIcons[label]
              return (
                <li key={label}>
                  <a
                    href={href}
                    rel="nofollow noopener"
                    className={cn(link, 'inline-flex items-center gap-1.5')}
                  >
                    <Icon aria-hidden className="size-3.5" />
                    {label}
                  </a>
                </li>
              )
            })}
          </ul>
        </SidebarSection>
      )}
    </aside>
  )
}

function SidebarSection({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="grid gap-2">
      <h2 className="text-xs font-semibold tracking-[0.06em] text-muted-foreground uppercase">
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
  const host = new URL(upstream).host
  return (
    <SidebarSection title={title}>
      <ul className="grid">
        {items.map((dependency) => (
          <li
            key={dependency.name}
            className="flex items-baseline justify-between gap-2 py-[3px] font-mono text-[0.8125rem]"
          >
            {dependency.local ? (
              <Link to={packagePath(dependency.name)} className={cn(link, 'min-w-0 truncate')}>
                {dependency.name}
              </Link>
            ) : dependency.hosted ? (
              <a
                href={`${upstream}/packages/${encodeURIComponent(dependency.name)}`}
                className={cn(link, 'inline-flex min-w-0 items-center gap-1')}
              >
                <span className="truncate">{dependency.name}</span>{' '}
                <ExternalLink aria-hidden className="size-3 shrink-0" />
                <span className="sr-only">on {host}</span>
              </a>
            ) : (
              <span className="min-w-0 truncate">{dependency.name}</span>
            )}
            {dependency.constraint && (
              <span className="shrink-0 text-xs text-muted-foreground">
                {dependency.constraint}
              </span>
            )}
          </li>
        ))}
      </ul>
    </SidebarSection>
  )
}
