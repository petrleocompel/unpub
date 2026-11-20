import { Download, Package, RotateCcw, SearchX } from 'lucide-react'
import { Link, useSearchParams } from 'react-router'
import { usePackages, type PackageListParams } from '@/api/queries'
import type { PackageSummary } from '@/api/types'
import { hostedUrl, useSession } from '@/auth/session'
import { DiscontinuedBadge, ProxiedBadge, ReplacedByBadge, SdkBadge } from '@/components/badges'
import { CodeBlock } from '@/components/copy-button'
import { NativeSelect } from '@/components/native-select'
import { intParam, Pager } from '@/components/pager'
import { EmptyState, ErrorState, ListSkeleton } from '@/components/states'
import { RelativeTime } from '@/components/time'
import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import { SegmentedControl } from '@/components/ui/segmented'
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

const sdkOptions: { value: '' | 'dart' | 'flutter'; label: string }[] = [
  { value: '', label: 'All' },
  { value: 'dart', label: 'Dart' },
  { value: 'flutter', label: 'Flutter' },
]
const sdkNames = { dart: 'Dart', flutter: 'Flutter' }

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
    // A choice, not typing: a history entry, so Back undoes it.
    setParams(next)
  }
  const filtered = !!(query.q || query.sdk || query.discontinued)
  const host = new URL(hostedUrl(config)).host

  return (
    <Page wide>
      <div className="grid gap-6">
        <div className="flex flex-wrap items-end justify-between gap-4">
          <div className="grid gap-1">
            <h1 className="text-[1.375rem] leading-[1.875rem] font-semibold tracking-[-0.015em] sm:text-2xl sm:leading-8">
              {query.q ? (
                <>
                  Results for <q className="font-mono">{query.q}</q>
                </>
              ) : (
                'Packages'
              )}
            </h1>
            {packages.data && (
              <p className="text-[0.8125rem] text-muted-foreground">
                {query.q || query.sdk
                  ? `${formatNumber(packages.data.total)} ${packages.data.total === 1 ? 'result' : 'results'}`
                  : `${formatNumber(packages.data.total)} ${packages.data.total === 1 ? 'package' : 'packages'}`}{' '}
                on <span className="font-mono">{host}</span>
              </p>
            )}
          </div>
          <div
            className="flex flex-wrap items-center gap-x-4 gap-y-3"
            role="group"
            aria-label="Filters and sorting"
          >
            <SegmentedControl
              label="SDK"
              value={query.sdk ?? ''}
              options={sdkOptions}
              onValueChange={(value) => set('sdk', value)}
            />
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
            <label className="flex items-center gap-2">
              <span className="text-[0.8125rem] text-muted-foreground">Sort</span>
              <NativeSelect
                small
                value={query.sort}
                onChange={(event) => set('sort', event.target.value)}
                className="w-42"
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
          <ErrorState
            title="Could not load the packages"
            error={packages.error}
            onRetry={() => void packages.refetch()}
          />
        ) : packages.data.total === 0 ? (
          filtered ? (
            <EmptyState
              icon={SearchX}
              title={
                query.q ? (
                  <>
                    Nothing matches “<span className="font-mono">{query.q}</span>”
                  </>
                ) : (
                  'No packages match'
                )
              }
            >
              <p>
                {query.sdk ? `With the filter SDK: ${sdkNames[query.sdk]}. ` : ''}
                {query.q
                  ? query.sdk
                    ? 'Check the spelling, or search all SDKs.'
                    : 'Check the spelling, or try a shorter part of the name.'
                  : 'No package matches these filters.'}
              </p>
              <div className="flex flex-wrap justify-center gap-2">
                <Button variant="outline" size="sm" onClick={() => setParams({})}>
                  <RotateCcw aria-hidden />
                  Reset the search
                </Button>
                {query.q && query.sdk && (
                  <Button variant="ghost" size="sm" onClick={() => set('sdk', null)}>
                    Search all SDKs
                  </Button>
                )}
              </div>
            </EmptyState>
          ) : (
            <EmptyState icon={Package} title="No packages yet">
              <p>Publish the first one from its directory. Add your token once, then publish:</p>
              <CodeBlock
                className="w-full"
                prompt
                label="the publish commands"
                code={`dart pub token add ${hostedUrl(config)}\ndart pub publish --server ${hostedUrl(config)}`}
              />
              <p className="text-xs">
                Or set{' '}
                <code className="rounded border bg-code px-[5px] py-px font-mono text-[0.88em]">
                  publish_to: {hostedUrl(config)}
                </code>{' '}
                in pubspec.yaml.
              </p>
            </EmptyState>
          )
        ) : (
          <div className="grid gap-5" aria-busy={packages.isPlaceholderData}>
            <ul className="divide-y rounded-lg border bg-card" aria-label="Packages">
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
    <li className="grid gap-x-6 gap-y-2 px-4 py-3.5 first:rounded-t-lg last:rounded-b-lg hover:bg-muted/60 sm:grid-cols-[minmax(0,1fr)_auto] sm:px-5 sm:py-4">
      <div className="grid min-w-0 gap-1.5">
        <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <Link
            to={`/packages/${encodeURIComponent(item.name)}`}
            className="min-w-0 truncate text-[1.0625rem] leading-6 font-semibold tracking-[-0.01em] text-primary hover:underline hover:underline-offset-3"
          >
            {item.name}
          </Link>
          <span className="font-mono text-[0.8125rem] text-muted-foreground">{item.latest}</span>
        </div>
        <p className="line-clamp-2 text-[0.8125rem] leading-5 text-muted-foreground">
          {item.description || <span className="italic">No description</span>}
        </p>
        <div className="flex flex-wrap gap-1.5">
          <SdkBadge flutter={item.isFlutter} />
          {item.isDiscontinued && <DiscontinuedBadge />}
          {item.replacedBy && <ReplacedByBadge name={item.replacedBy} />}
          {!item.private && <ProxiedBadge />}
        </div>
      </div>
      <dl className="flex items-center gap-4 text-[0.8125rem] text-muted-foreground tabular-nums sm:grid sm:content-start sm:justify-items-end sm:gap-1">
        <div className="flex items-center gap-1">
          <dt>
            <Download aria-hidden className="size-3.5" />
            <span className="sr-only">Downloads</span>
          </dt>
          <dd className="font-medium text-foreground">{formatNumber(item.downloads)}</dd>
        </div>
        <div>
          <dt className="sr-only">Updated</dt>
          <dd>
            <RelativeTime value={item.updatedAt} />
          </dd>
        </div>
      </dl>
    </li>
  )
}
