import { useState } from 'react'
import { Ban, ExternalLink, RotateCcw, Search, Trash2, UserCog } from 'lucide-react'
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
import { intParam, Pager } from '@/components/pager'
import {
  EmptyState,
  ErrorState,
  isNotFound,
  NotFoundState,
  TableSkeleton,
} from '@/components/states'
import { DateTime, RelativeTime } from '@/components/time'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { formatNumber } from '@/lib/format'
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

  return (
    <>
      <AdminHeading
        title="Packages"
        description="Every package published here, discontinued ones included."
      />
      <div className="grid gap-4">
        <div className="relative max-w-sm">
          <label htmlFor="admin-package-search" className="sr-only">
            Search packages
          </label>
          <Search
            aria-hidden
            className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground"
          />
          <Input
            id="admin-package-search"
            type="search"
            className="pl-8"
            placeholder="Search packages"
            value={text}
            onChange={(event) => setText(event.target.value)}
          />
        </div>
        {packages.isPending ? (
          <TableSkeleton columns={5} />
        ) : packages.isError ? (
          <ErrorState error={packages.error} onRetry={() => void packages.refetch()} />
        ) : packages.data.total === 0 ? (
          <EmptyState title={q ? 'No packages match' : 'No packages yet'} />
        ) : (
          <>
            <div className="overflow-x-auto rounded-lg border">
              <Table>
                <caption className="sr-only">Packages</caption>
                <TableHeader>
                  <TableRow>
                    <TableHead scope="col" className="sticky left-0 bg-background">
                      Name
                    </TableHead>
                    <TableHead scope="col">Latest</TableHead>
                    <TableHead scope="col">State</TableHead>
                    <TableHead scope="col">Updated</TableHead>
                    <TableHead scope="col" className="text-right">
                      Downloads
                    </TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {packages.data.items.map((item) => (
                    <TableRow key={item.name}>
                      <TableCell className="sticky left-0 bg-background">
                        <Link
                          to={`/admin/packages/${encodeURIComponent(item.name)}`}
                          className="font-medium text-primary hover:underline"
                        >
                          {item.name}
                        </Link>
                      </TableCell>
                      <TableCell className="font-mono">{item.latest}</TableCell>
                      <TableCell>
                        {item.isDiscontinued ? (
                          <DiscontinuedBadge />
                        ) : (
                          <span className="text-muted-foreground">Active</span>
                        )}
                      </TableCell>
                      <TableCell>
                        <DateTime value={item.updatedAt} date />
                      </TableCell>
                      <TableCell className="text-right tabular-nums">
                        {formatNumber(item.downloads)}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
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

export function AdminPackagePage() {
  const { name = '' } = useParams()
  const pkg = usePackage(name)
  useTitle(`${name} · Admin`)

  if (pkg.isPending) {
    return (
      <>
        <AdminHeading title={name} />
        <TableSkeleton rows={6} columns={4} />
      </>
    )
  }
  if (pkg.isError) {
    return (
      <>
        <AdminHeading title={name} />
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

  return (
    <>
      <AdminHeading
        title={pkg.name}
        description={
          <span className="flex flex-wrap items-center gap-2">
            <span>
              {pkg.versions.length} version{pkg.versions.length === 1 ? '' : 's'}
            </span>
            <span>·</span>
            <span>{formatNumber(pkg.downloads.package)} downloads</span>
            {pkg.isDiscontinued && <DiscontinuedBadge />}
            {!pkg.private && <ProxiedBadge />}
          </span>
        }
        actions={
          <Link
            to={packagePath(pkg.name)}
            className="inline-flex items-center gap-1 text-sm text-primary hover:underline"
          >
            Public page
            <ExternalLink aria-hidden className="size-3.5" />
          </Link>
        }
      />
      <div className="grid gap-6">
        <Card>
          <CardHeader>
            <CardTitle>
              <h2>Discontinued</h2>
            </CardTitle>
            <CardDescription>
              Hide the package from the list and point users to a replacement.
            </CardDescription>
          </CardHeader>
          <CardContent className="max-w-md">
            <DiscontinueForm key={`${pkg.isDiscontinued}-${pkg.replacedBy}`} pkg={pkg} />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>
              <h2>Versions</h2>
            </CardTitle>
            <CardDescription>
              The last version cannot be deleted: delete the package instead.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="overflow-x-auto rounded-lg border">
              <Table>
                <caption className="sr-only">Versions of {pkg.name}</caption>
                <TableHeader>
                  <TableRow>
                    <TableHead scope="col">Version</TableHead>
                    <TableHead scope="col">Published</TableHead>
                    <TableHead scope="col">Uploader</TableHead>
                    <TableHead scope="col" className="text-right">
                      Downloads
                    </TableHead>
                    <TableHead scope="col">
                      <span className="sr-only">Actions</span>
                    </TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {pkg.versions.map((version) => (
                    <TableRow key={version.version}>
                      <TableCell>
                        <div className="flex flex-wrap items-center gap-2">
                          <Link
                            to={packagePath(pkg.name, version.version)}
                            className="font-mono text-primary hover:underline"
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
                      <TableCell className="max-w-56 truncate">{version.uploader ?? '–'}</TableCell>
                      <TableCell className="text-right tabular-nums">
                        {formatNumber(version.downloads)}
                      </TableCell>
                      <TableCell>
                        <div className="flex justify-end gap-1">
                          <Button variant="ghost" size="sm" onClick={() => setRetracting(version)}>
                            {version.retracted ? <RotateCcw aria-hidden /> : <Ban aria-hidden />}
                            {version.retracted ? 'Restore' : 'Retract'}
                            <span className="sr-only"> {version.version}</span>
                          </Button>
                          <Button
                            variant="ghost"
                            size="sm"
                            className="text-destructive"
                            disabled={pkg.versions.length < 2}
                            onClick={() => setDeleting(version)}
                          >
                            <Trash2 aria-hidden />
                            Delete
                            <span className="sr-only"> {version.version}</span>
                          </Button>
                        </div>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>
              <h2>Uploaders</h2>
            </CardTitle>
          </CardHeader>
          <CardContent className="max-w-lg">
            <UploadersEditor pkg={pkg} />
          </CardContent>
        </Card>

        <Card className="border-destructive/40">
          <CardHeader>
            <CardTitle>
              <h2>Danger zone</h2>
            </CardTitle>
          </CardHeader>
          <CardContent className="grid gap-4">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div>
                <p className="font-medium">Transfer ownership</p>
                <p className="text-sm text-muted-foreground">Make one user the only uploader.</p>
              </div>
              <Button variant="outline" onClick={() => setTransfer(true)}>
                <UserCog aria-hidden />
                Transfer…
              </Button>
            </div>
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div>
                <p className="font-medium">Delete the package</p>
                <p className="text-sm text-muted-foreground">
                  Every version, archive and statistic, for good.
                </p>
              </div>
              <Button variant="destructive" onClick={() => setDeletePackage(true)}>
                <Trash2 aria-hidden />
                Delete package…
              </Button>
            </div>
          </CardContent>
        </Card>
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
