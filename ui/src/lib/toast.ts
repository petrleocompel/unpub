// A small toast store. The Toaster component renders it with Radix Toast,
// which announces each toast politely (assertively for errors).

export type ToastKind = 'success' | 'error' | 'info'
export type ToastItem = { id: number; kind: ToastKind; title: string; description?: string }

let items: ToastItem[] = []
let nextId = 1
const listeners = new Set<() => void>()

function emit() {
  for (const listener of listeners) listener()
}

function push(kind: ToastKind, title: string, description?: string) {
  items = [...items, { id: nextId++, kind, title, description }].slice(-5)
  emit()
}

export const toast = {
  success: (title: string, description?: string) => push('success', title, description),
  error: (title: string, description?: string) => push('error', title, description),
  info: (title: string, description?: string) => push('info', title, description),
  dismiss(id: number) {
    items = items.filter((item) => item.id !== id)
    emit()
  },
  clear() {
    items = []
    emit()
  },
}

export function subscribeToasts(listener: () => void) {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function getToasts() {
  return items
}
