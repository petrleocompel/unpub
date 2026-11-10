import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { RouterProvider, type createBrowserRouter } from 'react-router'
import { ApiError } from '@/api/client'
import { ThemeProvider } from '@/lib/theme'

export function createQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 30_000,
        refetchOnWindowFocus: false,
        // Answers from the server are final; retry only when there was none.
        retry: (count, error) => error instanceof ApiError && error.isNetwork && count < 2,
      },
      mutations: { retry: false },
    },
  })
}

export function App({
  router,
  queryClient,
}: {
  router: ReturnType<typeof createBrowserRouter>
  queryClient: QueryClient
}) {
  return (
    <ThemeProvider>
      <QueryClientProvider client={queryClient}>
        <RouterProvider router={router} />
      </QueryClientProvider>
    </ThemeProvider>
  )
}
