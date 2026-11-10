import { Monitor, Moon, Sun } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useTheme, type Theme } from '@/lib/theme'

const order: Theme[] = ['system', 'light', 'dark']
const labels: Record<Theme, string> = {
  system: 'System theme',
  light: 'Light theme',
  dark: 'Dark theme',
}

/** Cycles system, light and dark. The choice is kept in localStorage. */
export function ThemeToggle() {
  const { theme, setTheme } = useTheme()
  const next = order[(order.indexOf(theme) + 1) % order.length] ?? 'system'
  const Icon = theme === 'dark' ? Moon : theme === 'light' ? Sun : Monitor
  return (
    <Button
      variant="ghost"
      size="icon-sm"
      onClick={() => setTheme(next)}
      aria-label={`${labels[theme]}. Switch to ${labels[next].toLowerCase()}`}
      title={`${labels[theme]} (switch to ${labels[next].toLowerCase()})`}
    >
      <Icon aria-hidden />
    </Button>
  )
}
