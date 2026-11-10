import { Fragment } from 'react'
import { Lock } from 'lucide-react'
import { useSettings } from '@/api/queries'
import type { Settings } from '@/api/types'
import { CopyButton } from '@/components/copy-button'
import { Panel } from '@/components/dashboard/panel'
import { EmptyState, ErrorState, ListSkeleton } from '@/components/states'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { useTitle } from '@/lib/use-title'
import { AdminHeading } from './layout'

type Section = Settings['sections'][number]

/**
 * A number of days from the settings, such as `audit.retentionDays`, whose
 * value reads `30` or `0 (kept forever)`. Null while unknown.
 */
export function settingDays(settings: Settings | undefined, key: string) {
  const value = settings?.sections
    .flatMap((section) => section.settings)
    .find((setting) => setting.key === key)?.value
  const days = value === undefined ? NaN : Number.parseInt(value, 10)
  return Number.isInteger(days) ? days : null
}

/** The environment variable, breakable after each underscore. */
function EnvName({ name }: { name: string }) {
  return (
    <span>
      {name.split('_').map((part, index) => (
        <Fragment key={index}>
          {index > 0 && (
            <>
              _<wbr />
            </>
          )}
          {part}
        </Fragment>
      ))}
    </span>
  )
}

/** The key without its section: `publicUrl` in the `server` section. */
export function keyInSection(section: string, key: string) {
  return key.startsWith(`${section}.`) ? key.slice(section.length + 1) : key
}

function SettingsSection({ section }: { section: Section }) {
  const titleId = `settings-${section.name}`
  return (
    <Panel aria-labelledby={titleId}>
      <div className="border-b px-3.5 py-2.5 sm:px-4.5">
        <h2 id={titleId} className="font-mono text-sm leading-5.5 font-semibold">
          {section.name}
        </h2>
      </div>
      <dl className="divide-y">
        {section.settings.map((setting) => {
          const redacted = setting.value === '<redacted>'
          return (
            <div
              key={setting.key}
              className="grid gap-1 px-3.5 py-2.25 sm:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)] sm:px-4.5"
            >
              <dt className="grid min-w-0">
                <span className="font-mono text-[0.8125rem] break-all">
                  {keyInSection(section.name, setting.key)}
                </span>
                <span className="flex min-w-0 items-center gap-1 font-mono text-[0.6875rem] text-muted-foreground">
                  <span className="sr-only">Environment variable </span>
                  <EnvName name={setting.env} />
                  <CopyButton
                    text={setting.env}
                    label={setting.env}
                    size="icon-xs"
                    className="size-5 [&_svg]:size-3"
                  />
                </span>
              </dt>
              <dd className="font-mono text-[0.8125rem] break-all">
                {redacted ? (
                  <span className="inline-flex items-center gap-1 text-muted-foreground">
                    <Lock aria-hidden className="size-3" />
                    <span aria-hidden>•••••</span> redacted
                  </span>
                ) : (
                  setting.value || <span className="text-muted-foreground">(empty)</span>
                )}
              </dd>
            </div>
          )
        })}
      </dl>
    </Panel>
  )
}

export function SettingsPage() {
  useTitle('Settings')
  const settings = useSettings()
  const example = settings.data?.sections[0]?.settings[0]?.env ?? 'UNPUB_SERVER_PUBLIC_URL'
  return (
    <>
      <AdminHeading
        title="Settings"
        description={
          <>
            The effective configuration: <span className="font-mono">unpub.yaml</span>, then
            environment variables on top. Change it there and restart.
          </>
        }
      />
      {settings.isPending ? (
        <ListSkeleton rows={4} label="Loading the settings" />
      ) : settings.isError ? (
        <ErrorState error={settings.error} onRetry={() => void settings.refetch()} />
      ) : !settings.data.configured ? (
        <EmptyState title="No configuration">
          This server was embedded without a configuration file.
        </EmptyState>
      ) : (
        <div className="grid gap-4">
          <Alert variant="info">
            <Lock aria-hidden />
            <AlertDescription>
              <p>
                Secrets are redacted. Each key can be overridden by the variable shown under it, for
                example <code className="font-mono">{example}</code>.
              </p>
            </AlertDescription>
          </Alert>
          <div className="grid items-start gap-4 lg:grid-cols-2">
            {settings.data.sections.map((section) => (
              <SettingsSection key={section.name} section={section} />
            ))}
          </div>
        </div>
      )}
    </>
  )
}
