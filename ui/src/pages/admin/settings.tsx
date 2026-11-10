import { Lock } from 'lucide-react'
import { useSettings } from '@/api/queries'
import { CopyButton } from '@/components/copy-button'
import { EmptyState, ErrorState, TableSkeleton } from '@/components/states'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { useTitle } from '@/lib/use-title'
import { AdminHeading } from './layout'

export function SettingsPage() {
  useTitle('Settings')
  const settings = useSettings()
  return (
    <>
      <AdminHeading
        title="Settings"
        description="The effective configuration, read only. Change it in the YAML file or with the environment variable shown, then restart."
      />
      {settings.isPending ? (
        <TableSkeleton rows={10} columns={3} />
      ) : settings.isError ? (
        <ErrorState error={settings.error} onRetry={() => void settings.refetch()} />
      ) : !settings.data.configured ? (
        <EmptyState title="No configuration">
          This server was embedded without a configuration file.
        </EmptyState>
      ) : (
        <div className="grid gap-6">
          {settings.data.sections.map((section) => (
            <Card key={section.name}>
              <CardHeader>
                <CardTitle>
                  <h2 className="font-mono capitalize">{section.name}</h2>
                </CardTitle>
              </CardHeader>
              <CardContent>
                <Table containerClassName="[--sticky-bg:var(--color-card)]" stickyFirstColumn>
                  <TableHeader>
                    <TableRow>
                      <TableHead scope="col" className="w-1/3">
                        Key
                      </TableHead>
                      <TableHead scope="col">Value</TableHead>
                      <TableHead scope="col">Environment variable</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {section.settings.map((setting) => {
                      const redacted = setting.value === '<redacted>'
                      return (
                        <TableRow key={setting.key}>
                          <TableCell className="font-mono text-xs">{setting.key}</TableCell>
                          <TableCell className="font-mono text-xs break-all">
                            {redacted ? (
                              <span className="inline-flex items-center gap-1 text-muted-foreground">
                                <Lock aria-hidden className="size-3" />
                                redacted
                              </span>
                            ) : (
                              setting.value || (
                                <span className="text-muted-foreground">(empty)</span>
                              )
                            )}
                          </TableCell>
                          <TableCell>
                            <span className="inline-flex items-center gap-1 font-mono text-xs text-muted-foreground">
                              {setting.env}
                              <CopyButton text={setting.env} label={setting.env} size="icon-xs" />
                            </span>
                          </TableCell>
                        </TableRow>
                      )
                    })}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </>
  )
}
