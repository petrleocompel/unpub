import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { createBrowserRouter } from 'react-router'
import { App, createQueryClient } from './app'
import { basePath } from './lib/base'
import { applyTheme } from './lib/theme'
import { routes } from './routes'
import './index.css'

// Before the first render, so the page does not flash light in dark mode.
applyTheme()

const router = createBrowserRouter(routes, { basename: basePath || '/' })

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App router={router} queryClient={createQueryClient()} />
  </StrictMode>,
)
