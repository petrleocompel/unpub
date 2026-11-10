import {
  Archive,
  Ban,
  ChevronRight,
  CircleAlert,
  CloudDownload,
  FlaskConical,
  ShieldCheck,
  Star,
} from 'lucide-react'
import { Link } from 'react-router'
import { Badge } from '@/components/ui/badge'
import type { Role, Scope } from '@/api/types'
import { cn } from '@/lib/utils'

export function SdkBadge({ flutter }: { flutter: boolean }) {
  return (
    <Badge variant="secondary" className="gap-[5px] rounded-[5px] font-semibold">
      <span
        aria-hidden
        className={cn(
          'size-1.5',
          flutter
            ? 'rounded-full bg-[color-mix(in_oklab,var(--primary)_55%,var(--success))]'
            : 'rounded-[2px] bg-primary',
        )}
      />
      {flutter ? 'Flutter' : 'Dart'}
    </Badge>
  )
}

export function DiscontinuedBadge() {
  return (
    <Badge variant="warning">
      <Archive aria-hidden />
      Discontinued
    </Badge>
  )
}

export function RetractedBadge() {
  return (
    <Badge variant="danger">
      <Ban aria-hidden />
      Retracted
    </Badge>
  )
}

export function PrereleaseBadge() {
  return (
    <Badge variant="outline">
      <FlaskConical aria-hidden />
      Prerelease
    </Badge>
  )
}

export function LatestBadge() {
  return (
    <Badge variant="primary">
      <Star aria-hidden />
      Latest
    </Badge>
  )
}

export function ProxiedBadge() {
  return (
    <Badge variant="outline">
      <CloudDownload aria-hidden />
      From pub.dev
    </Badge>
  )
}

export function ReplacedByBadge({ name }: { name: string }) {
  return (
    <Badge variant="outline" asChild>
      <Link to={`/packages/${encodeURIComponent(name)}`}>
        Replaced by <span className="font-mono font-medium">{name}</span>
        <ChevronRight aria-hidden />
      </Link>
    </Badge>
  )
}

export function DisabledBadge() {
  return (
    <Badge variant="danger">
      <CircleAlert aria-hidden />
      Disabled
    </Badge>
  )
}

export function RoleBadge({ role }: { role: Role }) {
  return (
    <Badge variant={role === 'admin' ? 'default' : 'secondary'} className="capitalize">
      {role === 'admin' && <ShieldCheck aria-hidden />}
      {role}
    </Badge>
  )
}

export function ScopeBadge({ scope }: { scope: Scope }) {
  return (
    <Badge variant="outline" className="rounded-[5px] font-mono font-normal">
      {scope}
    </Badge>
  )
}

const statusLabels: Record<string, string> = {
  pending: 'Pending',
  succeeded: 'Delivered',
  failed: 'Failed',
}

export function DeliveryStatusBadge({ status }: { status: string }) {
  return (
    <Badge
      variant={
        status === 'succeeded'
          ? 'success'
          : status === 'failed'
            ? 'danger'
            : status === 'pending'
              ? 'warning'
              : 'outline'
      }
    >
      <span
        aria-hidden
        className={cn(
          'size-[7px] rounded-full',
          status === 'succeeded' && 'bg-success',
          status === 'failed' && 'bg-destructive',
          status === 'pending' && 'bg-warning',
        )}
      />
      {statusLabels[status] ?? status}
    </Badge>
  )
}
