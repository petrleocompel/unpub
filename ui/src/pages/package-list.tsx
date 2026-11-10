import { Download, RotateCcw, SearchX } from 'lucide-react'
import { Link, useSearchParams } from 'react-router'
import { usePackages, type PackageListParams } from '@/api/queries'
import type { PackageSummary } from '@/api/types'
import { hostedUrl, useSession } from '@/auth/session'
import { DiscontinuedBadge, ReplacedByBadge, SdkBadge } from '@/components/badges'
import { CodeBlock } from '@/components/copy-button'
import { NativeSelect } from '@/components/native-select'
import { intParam, Pager } from '@/components/pager'
import { EmptyState, ErrorState, ListSkeleton } from '@/components/states'
import { RelativeTime } from '@/components/time'
import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import { Switch } from '@/components/ui/switch'
import { Page } from '@/layout/root'
import { formatNumber } from '@/lib/format'
import { useTitle } from '@/lib/use-title'

export const pageSizes = [20, 50, 100]
const sorts = ['relevance', 'downloads', 'updated', 'name'] as const
type Sort = (typeof sorts)[number]
const sortLabels: Record<Sort, string> = {
  relevance: 'Best match',
  downloads: 'Downloads',
  updated: 'Recently updated',
  name: 'Name',
}

/** The list parameters in the URL, as the classic page reads them. */
export function listParams(
  params: URLSearchParams,
): Required<Pick<PackageListParams, 'page' | 'size'>> & PackageListParams {
  const q = params.get('q')?.trim() ?? ''
  const sdk = params.get('sdk')
  const sort = params.get('sort') as Sort | null
  const discontinued = params.get('discontinued')
  return {
    q,
    sdk: sdk === 'dart' || sdk === 'flutter' ? sdk : undefined,
    discontinued: discontinued === '1' || discontinued === 'true',
    sort:
      sort && sorts.includes(sort) && (sort !== 'relevance' || q)
        ? sort
        : q
          ? 'relevance'
          : 'downloads',
    page: intParam(params, 'page', 1),
    size: pageSizes.includes(intParam(params, 'size', 20)) ? intParam(params, 'size', 20) : 20,
  }
}

export function PackageListPage() {
  const [params, setParams] = useSearchParams()
  const query = listParams(params)
  const packages = usePackages(query)
  const { config } = useSession()
  useTitle(query.q ? `Search: ${query.q}` : 'Packages')

  const set = (name: string, value: string | null) => {
    const next = new URLSearchParams(params)
    if (value === null || value === '') next.delete(name)
    else next.set(name, value)
    next.delete('page')
    setParams(next, { replace: true })
  }
  const filtered = !!(query.q || query.sdk || query.discontinued)

  return (
    <Page wide>
      <div className="grid gap-6">
        <div className="flex flex-wrap items-end justify-between gap-4">
          <h1 className="text-2xl font-semibold">
            {query.q ? (
              <>
                Results for <q className="font-mono">{query.q}</q>
              </>
            ) : (
              'Packages'
            )}
          </h1>
          <div
            className="flex flex-wrap items-center gap-4"
            role="group"
            aria-label="Filters and sorting"
          >
            <label className="flex items-center gap-2 text-sm">
              <span className="text-muted-foreground">SDK</span>
              <NativeSelect
                value={query.sdk ?? ''}
                onChange={(event) => set('sdk', event.target.value)}
                className="w-28"
              >
                <option value="">All</option>
                <option value="dart">Dart</option>
                <option value="flutter">Flutter</option>
              </NativeSelect>
            </label>
            <div className="flex items-center gap-2">
              <Switch
                id="show-discontinued"
                checked={query.discontinued}
                onCheckedChange={(checked) => set('discontinued', checked ? '1' : null)}
              />
              <Label htmlFor="show-discontinued" className="font-normal">
                Show discontinued
              </Label>
            </div>
            <label className="flex items-center gap-2 text-sm">
              <span className="text-muted-foreground">Sort</span>
              <NativeSelect
                value={query.sort}
                onChange={(event) => set('sort', event.target.value)}
                className="w-44"
              >
                {sorts
                  .filter((sort) => sort !== 'relevance' || query.q)
                  .map((sort) => (
                    <option key={sort} value={sort}>
                      {sortLabels[sort]}
                    </option>
                  ))}
              </NativeSelect>
            </label>
          </div>
        </div>

        {packages.isPending ? (
          <ListSkeleton rows={6} label="Loading packages" />
        ) : packages.isError ? (
          <ErrorState error={packages.error} onRetry={() => void packages.refetch()} />
        ) : packages.data.total === 0 ? (
          filtered ? (
            <EmptyState icon={SearchX} title="No packages match">
              <p>
                {query.q ? (
                  <>
                    Nothing matches <q className="font-mono">{query.q}</q>
                    {query.sdk || query.discontinued ? ' with these filters' : ''}.
                  </>
                ) : (
                  'No package matches these filters.'
                )}
              </p>
              <Button
                variant="outline"
                className="mt-3"
                onClick={() => setParams({}, { replace: false })}
              >
                <RotateCcw aria-hidden />
                Reset the search
              </Button>
            </EmptyState>
          ) : (
            <EmptyState title="No packages yet">
              <p>Publish the first one from its directory:</p>
              <CodeBlock
                className="mt-3 text-left"
                label="the publish command"
                code={`dart pub token add ${hostedUrl(config)}\ndart pub publish --server ${hostedUrl(config)}`}
              />
              <p className="mt-3">
                Or set <code className="font-mono">publish_to: {hostedUrl(config)}</code> in its
                pubspec.yaml.
              </p>
            </EmptyState>
          )
        ) : (
          <div className="grid gap-4" aria-busy={packages.isPlaceholderData}>
            <ul className="divide-y rounded-lg border" aria-label="Packages">
              {packages.data.items.map((item) => (
                <PackageRow key={item.name} item={item} />
              ))}
            </ul>
            <Pager
              page={packages.data.page}
              size={packages.data.size}
              total={packages.data.total}
              sizes={pageSizes}
              label="Package pages"
            />
          </div>
        )}
      </div>
    </Page>
  )
}

function PackageRow({ item }: { item: PackageSummary }) {
  return (
    <li className="grid gap-2 p-4 sm:grid-cols-[1fr_auto] sm:items-start">
      <div className="grid min-w-0 gap-1.5">
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
          <Link
            to={`/packages/${encodeURIComponent(item.name)}`}
            className="truncate text-lg font-semibold text-primary hover:underline"
          >
            {item.name}
          </Link>
          <span className="font-mono text-sm text-muted-foreground">{item.latest}</span>
        </div>
        <p className="line-clamp-2 text-sm text-muted-foreground">
          {item.description || <span className="italic">No description</span>}
        </p>
        <div className="flex flex-wrap gap-1.5">
          <SdkBadge flutter={item.isFlutter} />
          {item.isDiscontinued && <DiscontinuedBadge />}
          {item.replacedBy && <ReplacedByBadge name={item.replacedBy} />}
        </div>
      </div>
      <dl className="flex gap-4 text-sm text-muted-foreground sm:grid sm:justify-items-end sm:gap-1">
        <div className="flex items-center gap-1">
          <dt className="sr-only">Updated</dt>
          <dd>
            <RelativeTime value={item.updatedAt} />
          </dd>
        </div>
        <div className="flex items-center gap-1">
          <dt>
            <Download aria-hidden className="size-3.5" />
            <span className="sr-only">Downloads</span>
          </dt>
          <dd>{formatNumber(item.downloads)}</dd>
        </div>
      </dl>
    </li>
  )
}
