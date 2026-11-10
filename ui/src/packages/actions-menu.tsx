import { useState } from 'react'
import {
  Archive,
  ArchiveRestore,
  ChevronDown,
  Ban,
  RotateCcw,
  Trash2,
  UserCog,
  Users,
} from 'lucide-react'
import { useNavigate } from 'react-router'
import type { Package } from '@/api/types'
import { useSession } from '@/auth/session'
import { Button } from '@/components/ui/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import {
  DeletePackageDialog,
  DeleteVersionDialog,
  DiscontinueDialog,
  RetractDialog,
  TransferDialog,
  UploadersDialog,
} from './dialogs'

type DialogName =
  'retract' | 'discontinue' | 'uploaders' | 'transfer' | 'delete-version' | 'delete-package'

/** The actions of uploaders and administrators on the package page. */
export function PackageActionsMenu({ pkg }: { pkg: Package }) {
  const { isAdmin } = useSession()
  const navigate = useNavigate()
  const [dialog, setDialog] = useState<DialogName | null>(null)
  const open = (name: DialogName) => ({
    open: dialog === name,
    onOpenChange: (value: boolean) => setDialog(value ? name : null),
  })

  return (
    <>
      <DropdownMenu modal={false}>
        <DropdownMenuTrigger asChild>
          <Button variant="outline" size="sm">
            Actions
            <ChevronDown aria-hidden />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-60">
          <DropdownMenuLabel className="font-mono text-xs font-normal text-muted-foreground">
            {pkg.name} {pkg.version}
          </DropdownMenuLabel>
          <DropdownMenuItem onSelect={() => setDialog('retract')}>
            {pkg.retracted ? <RotateCcw aria-hidden /> : <Ban aria-hidden />}
            {pkg.retracted ? 'Restore this version…' : 'Retract this version…'}
          </DropdownMenuItem>
          <DropdownMenuItem onSelect={() => setDialog('discontinue')}>
            {pkg.isDiscontinued ? <ArchiveRestore aria-hidden /> : <Archive aria-hidden />}
            {pkg.isDiscontinued ? 'Continue the package…' : 'Discontinue the package…'}
          </DropdownMenuItem>
          <DropdownMenuItem onSelect={() => setDialog('uploaders')}>
            <Users aria-hidden />
            Manage uploaders…
          </DropdownMenuItem>
          {isAdmin && (
            <>
              <DropdownMenuSeparator />
              <DropdownMenuItem onSelect={() => setDialog('transfer')}>
                <UserCog aria-hidden />
                Transfer ownership…
              </DropdownMenuItem>
              <DropdownMenuItem
                variant="destructive"
                disabled={pkg.versions.length < 2}
                onSelect={() => setDialog('delete-version')}
              >
                <Trash2 aria-hidden />
                Delete this version…
              </DropdownMenuItem>
              <DropdownMenuItem variant="destructive" onSelect={() => setDialog('delete-package')}>
                <Trash2 aria-hidden />
                Delete the package…
              </DropdownMenuItem>
            </>
          )}
        </DropdownMenuContent>
      </DropdownMenu>
      <RetractDialog
        name={pkg.name}
        version={pkg.version}
        retracted={pkg.retracted}
        {...open('retract')}
      />
      <DiscontinueDialog pkg={pkg} {...open('discontinue')} />
      <UploadersDialog pkg={pkg} {...open('uploaders')} />
      {isAdmin && (
        <>
          <TransferDialog pkg={pkg} {...open('transfer')} />
          <DeleteVersionDialog
            name={pkg.name}
            version={pkg.version}
            onDeleted={() =>
              navigate(`/packages/${encodeURIComponent(pkg.name)}`, { replace: true })
            }
            {...open('delete-version')}
          />
          <DeletePackageDialog
            name={pkg.name}
            onDeleted={() => navigate('/packages', { replace: true })}
            {...open('delete-package')}
          />
        </>
      )}
    </>
  )
}
