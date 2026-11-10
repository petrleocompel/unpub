import { useSyncExternalStore } from 'react'
import { Toast } from 'radix-ui'
import { CircleCheck, Info, OctagonX, X } from 'lucide-react'
import { getToasts, subscribeToasts, toast, type ToastKind } from '@/lib/toast'
import { cn } from '@/lib/utils'

const icons: Record<ToastKind, typeof Info> = {
  success: CircleCheck,
  error: OctagonX,
  info: Info,
}

export function Toaster() {
  const items = useSyncExternalStore(subscribeToasts, getToasts, getToasts)
  return (
    <Toast.Provider swipeDirection="right" duration={6000} label="Notification">
      {items.map((item) => {
        const Icon = icons[item.kind]
        return (
          <Toast.Root
            key={item.id}
            type={item.kind === 'error' ? 'foreground' : 'background'}
            duration={item.kind === 'error' ? 10000 : 6000}
            onOpenChange={(open) => {
              if (!open) toast.dismiss(item.id)
            }}
            className={cn(
              'pointer-events-auto flex w-full items-start gap-3 rounded-lg border bg-popover p-4 text-popover-foreground shadow-lg',
              'data-[state=closed]:animate-out data-[state=open]:animate-in',
              item.kind === 'error' && 'border-destructive/50',
            )}
          >
            <Icon
              aria-hidden
              className={cn(
                'mt-0.5 size-4 shrink-0',
                item.kind === 'success' && 'text-success',
                item.kind === 'error' && 'text-destructive',
              )}
            />
            <div className="grid flex-1 gap-1">
              <Toast.Title className="text-sm font-medium">{item.title}</Toast.Title>
              {item.description && (
                <Toast.Description className="text-sm text-muted-foreground">
                  {item.description}
                </Toast.Description>
              )}
            </div>
            <Toast.Close
              aria-label="Dismiss"
              className="rounded-sm opacity-70 transition-opacity hover:opacity-100 focus-visible:opacity-100"
            >
              <X className="size-4" aria-hidden />
            </Toast.Close>
          </Toast.Root>
        )
      })}
      <Toast.Viewport className="fixed right-0 bottom-0 z-[100] flex max-h-screen w-full flex-col gap-2 p-4 outline-none sm:max-w-sm" />
    </Toast.Provider>
  )
}
