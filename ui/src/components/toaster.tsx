import { useSyncExternalStore } from 'react'
import { Toast } from 'radix-ui'
import { CircleAlert, CircleCheck, Info, X } from 'lucide-react'
import { getToasts, subscribeToasts, toast, type ToastKind } from '@/lib/toast'
import { cn } from '@/lib/utils'

const icons: Record<ToastKind, typeof Info> = {
  success: CircleCheck,
  error: CircleAlert,
  info: Info,
}

export function Toaster() {
  const items = useSyncExternalStore(subscribeToasts, getToasts, getToasts)
  return (
    // Results go after 5 s; errors stay until dismissed (board 02).
    <Toast.Provider swipeDirection="right" duration={5000} label="Notification">
      {items.map((item) => {
        const Icon = icons[item.kind]
        return (
          <Toast.Root
            key={item.id}
            type={item.kind === 'error' ? 'foreground' : 'background'}
            duration={item.kind === 'error' ? Infinity : 5000}
            onOpenChange={(open) => {
              if (!open) toast.dismiss(item.id)
            }}
            className={cn(
              'pointer-events-auto flex w-full items-start gap-2.5 rounded-[10px] border bg-popover py-3 pr-3 pl-3.5 text-[0.84375rem] leading-5 text-popover-foreground shadow-lg',
              'data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:animate-in data-[state=open]:slide-in-from-bottom-2',
            )}
          >
            <Icon
              aria-hidden
              className={cn(
                'mt-0.5 size-4 shrink-0',
                item.kind === 'success' && 'text-success',
                item.kind === 'error' && 'text-destructive',
                item.kind === 'info' && 'text-info',
              )}
            />
            <div className="grid min-w-0 flex-1">
              <Toast.Title className="font-semibold">{item.title}</Toast.Title>
              {item.description && (
                <Toast.Description className="break-words text-muted-foreground">
                  {item.description}
                </Toast.Description>
              )}
            </div>
            <Toast.Close
              aria-label="Dismiss"
              className="-my-0.5 inline-grid size-6.5 shrink-0 place-items-center rounded-[5px] text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
            >
              <X className="size-3.5" aria-hidden />
            </Toast.Close>
          </Toast.Root>
        )
      })}
      <Toast.Viewport className="fixed right-0 bottom-0 z-[100] flex max-h-screen w-full flex-col gap-3 p-4 outline-none sm:max-w-[408px] sm:p-6" />
    </Toast.Provider>
  )
}
