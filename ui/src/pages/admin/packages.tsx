import { useState } from 'react'
import {
  ArrowDown,
  ArrowLeftRight,
  Ban,
  ChevronRight,
  ExternalLink,
  Search,
  Trash2,
  Undo2,
} from 'lucide-react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router'
import { usePackage, usePackages } from '@/api/queries'
import type { Package, Version } from '@/api/types'
import {
  DiscontinuedBadge,
  LatestBadge,
  PrereleaseBadge,
  ProxiedBadge,
  RetractedBadge,
} from '@/components/badges'
import { CompactTable } from '@/components/dashboard/compact-table'
import { Panel, PanelBody, PanelHeader } from '@/components/dashboard/panel'
import { intParam, Pager } from '@/components/pager'
import {
  EmptyState,
  ErrorState,
  isNotFound,
  NotFoundState,
  TableSkeleton,
} from '@/components/states'
import { RelativeTime } from '@/components/time'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { formatDate, formatNumber } from '@/lib/format'
import { useDebouncedParam } from '@/lib/use-debounced-param'
import { useTitle } from '@/lib/use-title'
import {
  DeletePackageDialog,
  DeleteVersionDialog,
  DiscontinueForm,
  RetractDialog,
  TransferDialog,
  UploadersEditor,
} from '@/packages/dialogs'
import { packagePath } from '@/pages/package'
import { AdminHeading } from './layout'

/** The uploaders of a list row, short: names before the @, the rest counted. */
export function shortUploaders(uploaders: string[]) {
  const names = uploaders.map((email) => email.split('@')[0] ?? email)
  return names.length <= 2 ? names.join(', ') : `${names[0]} +${names.length - 1}`
}

export function AdminPackagesPage() {
  useTitle('Packages · Admin')
  const [params] = useSearchParams()
  const [text, setText, q] = useDebouncedParam('q')
  const page = intParam(params, 'page', 1)
  const size = 100
  const packages = usePackages({
    q,
    discontinued: true,
    sort: q ? 'relevance' : 'name',
    page,
    size,
  })
  const total = packages.data && !q ? packages.data.total : null

  return (
    <>
      <AdminHeading
        title="Packages"
        description={
          <>
            {total !== null && `${formatNumber(total)} package${total === 1 ? '' : 's'}, `}
            discontinued ones included. Open one to moderate it.
          </>
        }
      />
      <div className="grid gap-4">
        <div className="relative max-w-90 min-w-50">
          <label htmlFor="admin-package-search" className="sr-only">
            Search packages by name
          </label>
          <Search
            aria-hidden
            className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground"
          />
          <Input
            id="admin-package-search"
            type="search"
            className="h-8 pl-8 text-[0.8125rem] md:text-[0.8125rem]"
            placeholder="Search packages"
            value={text}
            onChange={(event) => setText(event.target.value)}
          />
        </div>
        {packages.isPending ? (
          <TableSkeleton columns={7} />
        ) : packages.isError ? (
          <ErrorState error={packages.error} onRetry={() => void packages.refetch()} />
        ) : packages.data.total === 0 ? (
          <EmptyState title={q ? 'No packages match' : 'No packages yet'} />
        ) : (
          <>
            <CompactTable>
              <caption className="sr-only">Packages, {q ? 'best match first' : 'by name'}</caption>
              <TableHeader>
                <TableRow>
                  <TableHead scope="col" aria-sort={q ? undefined : 'ascending'}>
                    <span className="inline-flex items-center gap-1">
                      Name
                      {!q && <ArrowDown aria-hidden className="size-3" />}
                    </span>
                  </TableHead>
                  <TableHead scope="col">Latest</TableHead>
                  <TableHead scope="col" className="text-right">
                    Versions
                  </TableHead>
                  <TableHead scope="col">Uploaders</TableHead>
                  <TableHead scope="col">Status</TableHead>
                  <TableHead scope="col" className="text-right">
                    Downloads
                  </TableHead>
                  <TableHead scope="col">Updated</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {packages.data.items.map((item) => (
                  <TableRow key={item.name}>
                    <TableCell>
                      <Link
                        to={`/admin/packages/${encodeURIComponent(item.name)}`}
                        className="font-medium text-primary hover:underline"
                      >
                        {item.name}
                      </Link>
                    </TableCell>
                    <TableCell className="font-mono">{item.latest}</TableCell>
                    <TableCell className="text-right tabular-nums">
                      {formatNumber(item.versionCount)}
                    </TableCell>
                    <TableCell className="max-w-64 text-muted-foreground">
                      {item.uploaders.length === 0 ? (
                        'None'
                      ) : (
                        <span className="block truncate" title={item.uploaders.join(', ')}>
                          {shortUploaders(item.uploaders)}
                        </span>
                      )}
                    </TableCell>
                    <TableCell>
                      {item.isDiscontinued ? (
                        <DiscontinuedBadge />
                      ) : (
                        <span className="text-muted-foreground">Active</span>
                      )}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {formatNumber(item.downloads)}
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      <RelativeTime value={item.updatedAt} />
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </CompactTable>
            <Pager
              page={packages.data.page}
              size={packages.data.size}
              total={packages.data.total}
              label="Package pages"
            />
          </>
        )}
      </div>
    </>
  )
}

function Breadcrumb({ name }: { name: string }) {
  return (
    <nav aria-label="Breadcrumb">
      <ol className="flex flex-wrap items-center gap-1.5 text-[0.8125rem] text-muted-foreground">
        <li>
          <Link to="/admin/packages" className="hover:text-foreground hover:underline">
            Packages
          </Link>
        </li>
        <li aria-hidden>
          <ChevronRight className="size-3" />
        </li>
        <li aria-current="page" className="text-foreground">
          {name}
        </li>
      </ol>
    </nav>
  )
}

export function AdminPackagePage() {
  const { name = '' } = useParams()
  const pkg = usePackage(name)
  useTitle(`${name} · Admin`)

  if (pkg.isPending) {
    return (
      <>
        <AdminHeading title={name} above={<Breadcrumb name={name} />} />
        <TableSkeleton rows={6} columns={4} />
      </>
    )
  }
  if (pkg.isError) {
    return (
      <>
        <AdminHeading title={name} above={<Breadcrumb name={name} />} />
        {isNotFound(pkg.error) ? (
          <NotFoundState what="package" />
        ) : (
          <ErrorState error={pkg.error} onRetry={() => void pkg.refetch()} />
        )}
      </>
    )
  }
  return <PackageModeration pkg={pkg.data} />
}

function PackageModeration({ pkg }: { pkg: Package }) {
  const navigate = useNavigate()
  const [retracting, setRetracting] = useState<Version | null>(null)
  const [deleting, setDeleting] = useState<Version | null>(null)
  const [transfer, setTransfer] = useState(false)
  const [deletePackage, setDeletePackage] = useState(false)
  const count = pkg.versions.length
  const created = pkg.versions.reduce<string | null>(
    (first, version) => (!first || version.published < first ? version.published : first),
    null,
  )

  return (
    <>
      <AdminHeading
        above={<Breadcrumb name={pkg.name} />}
        title={
          <span className="flex flex-wrap items-baseline gap-2">
            {pkg.name}
            <span className="font-mono text-[0.9375rem] font-normal text-muted-foreground">
              {pkg.latest}
            </span>
          </span>
        }
        description={
          <span className="flex flex-wrap items-center gap-x-1.5 gap-y-1">
            <span>
              {formatNumber(count)} version{count === 1 ? '' : 's'}
            </span>
            <span aria-hidden>·</span>
            <span>{formatNumber(pkg.downloads.package)} downloads</span>
            {created && (
              <>
                <span aria-hidden>·</span>
                <span>created {formatDate(created)}</span>
              </>
            )}
            {pkg.isDiscontinued && <DiscontinuedBadge />}
            {!pkg.private && <ProxiedBadge />}
          </span>
        }
        actions={
          <Button variant="outline" size="sm" asChild>
            <Link to={packagePath(pkg.name)}>
              <ExternalLink aria-hidden />
              Public page
            </Link>
          </Button>
        }
      />
      <div className="grid items-start gap-6 lg:grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)]">
        <Panel aria-labelledby="versions-title">
          <PanelHeader title="Versions" titleId="versions-title">
            <span className="text-xs text-muted-foreground">
              Retracting is reversible; deleting is not.
            </span>
          </PanelHeader>
          <CompactTable boxed={false} containerClassName="rounded-b-lg">
            <caption className="sr-only">Versions of {pkg.name}, newest first</caption>
            <TableHeader>
              <TableRow>
                <TableHead scope="col">Version</TableHead>
                <TableHead scope="col">Published</TableHead>
                <TableHead scope="col">By</TableHead>
                <TableHead scope="col">Status</TableHead>
                <TableHead scope="col" className="text-right">
                  Actions
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {pkg.versions.map((version) => (
                <TableRow key={version.version} data-muted={version.retracted || undefined}>
                  <TableCell>
                    <Link
                      to={packagePath(pkg.name, version.version)}
                      className="font-mono hover:text-primary hover:underline"
                    >
                      {version.version}
                    </Link>
                  </TableCell>
                  <TableCell>
                    <RelativeTime value={version.published} />
                  </TableCell>
                  <TableCell className="max-w-56 truncate text-muted-foreground">
                    {version.uploader?.split('@')[0] ?? '–'}
                  </TableCell>
                  <TableCell>
                    <div className="flex gap-1">
                      {version.version === pkg.latest && <LatestBadge />}
                      {version.prerelease && <PrereleaseBadge />}
                      {version.retracted && <RetractedBadge />}
                      {version.version !== pkg.latest &&
                        !version.prerelease &&
                        !version.retracted && <span className="text-muted-foreground">—</span>}
                    </div>
                  </TableCell>
                  <TableCell>
                    <div className="flex justify-end gap-1">
                      <Button variant="outline" size="xs" onClick={() => setRetracting(version)}>
                        {version.retracted ? <Undo2 aria-hidden /> : <Ban aria-hidden />}
                        {version.retracted ? 'Restore' : 'Retract'}
                        <span className="sr-only"> {version.version}</span>
                      </Button>
                      <Button
                        variant="ghost"
                        size="icon-xs"
                        className="text-destructive hover:text-destructive"
                        disabled={count < 2}
                        title={
                          count < 2 ? 'The last version: delete the package instead' : undefined
                        }
                        aria-label={`Delete version ${version.version}`}
                        onClick={() => setDeleting(version)}
                      >
                        <Trash2 aria-hidden />
                      </Button>
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </CompactTable>
        </Panel>

        <div className="grid gap-6">
          <Panel aria-labelledby="discontinue-title">
            <PanelHeader title="Discontinue" titleId="discontinue-title" />
            <PanelBody>
              <DiscontinueForm key={`${pkg.isDiscontinued}-${pkg.replacedBy}`} pkg={pkg} />
            </PanelBody>
          </Panel>

          <Panel aria-labelledby="uploaders-title">
            <PanelHeader title="Uploaders" titleId="uploaders-title">
              <span className="text-xs text-muted-foreground">Can publish and retract</span>
            </PanelHeader>
            <PanelBody>
              <UploadersEditor pkg={pkg} />
            </PanelBody>
          </Panel>

          <Panel aria-labelledby="danger-title" className="border-destructive/35">
            <PanelHeader
              title="Danger zone"
              titleId="danger-title"
              titleClassName="text-destructive"
            />
            <div className="divide-y">
              <div className="flex flex-wrap items-center justify-between gap-3 px-3.5 py-3.5 sm:px-4.5">
                <div className="grid">
                  <p className="text-[0.8125rem] font-medium">Transfer ownership</p>
                  <p className="text-xs text-muted-foreground">
                    Replace every uploader with one account.
                  </p>
                </div>
                <Button variant="outline" size="sm" onClick={() => setTransfer(true)}>
                  <ArrowLeftRight aria-hidden />
                  Transfer…
                </Button>
              </div>
              <div className="flex flex-wrap items-center justify-between gap-3 px-3.5 py-3.5 sm:px-4.5">
                <div className="grid">
                  <p className="text-[0.8125rem] font-medium">Delete package</p>
                  <p className="text-xs text-muted-foreground">
                    All {formatNumber(count)} version{count === 1 ? '' : 's'}, archives and
                    statistics. Cannot be undone.
                  </p>
                </div>
                <Button
                  variant="destructive"
                  size="sm"
                  aria-label="Delete package…"
                  onClick={() => setDeletePackage(true)}
                >
                  <Trash2 aria-hidden />
                  Delete…
                </Button>
              </div>
            </div>
          </Panel>
        </div>
      </div>

      <RetractDialog
        name={pkg.name}
        version={retracting?.version ?? ''}
        retracted={retracting?.retracted ?? false}
        open={retracting !== null}
        onOpenChange={(open) => !open && setRetracting(null)}
      />
      <DeleteVersionDialog
        name={pkg.name}
        version={deleting?.version ?? ''}
        open={deleting !== null}
        onOpenChange={(open) => !open && setDeleting(null)}
      />
      <TransferDialog pkg={pkg} open={transfer} onOpenChange={setTransfer} />
      <DeletePackageDialog
        name={pkg.name}
        open={deletePackage}
        onOpenChange={setDeletePackage}
        onDeleted={() => navigate('/admin/packages', { replace: true })}
      />
    </>
  )
}
