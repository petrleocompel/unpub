import {
  keepPreviousData,
  queryOptions,
  useMutation,
  useQuery,
  useQueryClient,
  type QueryKey,
} from '@tanstack/react-query'
import { api, ApiError, setCsrfToken, unwrap } from './client'
import type { Anonymous, Me, Role, Scope, WebhookEvent, WebhookInput } from './types'

// ---------------------------------------------------------------- session

export const configQuery = queryOptions({
  queryKey: ['config'],
  queryFn: () => unwrap(api.GET('/webapi/config')),
  staleTime: 5 * 60_000,
})

/** The current user, or null when nobody is logged in. */
export const meQuery = queryOptions({
  queryKey: ['me'],
  queryFn: async (): Promise<Me | null> => {
    try {
      // openapi-fetch drops the null `user` of Anonymous and the null `id`
      // of a static token's user.
      const answer = (await unwrap(api.GET('/webapi/me'))) as Me | Anonymous
      // Nobody is logged in: the server answers {"user": null}.
      if (answer.user === null) {
        setCsrfToken(null)
        return null
      }
      const me = answer
      setCsrfToken(me.csrfToken)
      return me
    } catch (error) {
      // An older server answers 401 when nobody is logged in.
      if (error instanceof ApiError && error.status === 401) {
        setCsrfToken(null)
        return null
      }
      throw error
    }
  },
  staleTime: 60_000,
})

export function useLogin() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (body: { email: string; password: string }) =>
      unwrap(api.POST('/webapi/login', { body })),
    onSuccess: async (result) => {
      setCsrfToken(result.csrfToken)
      // Everything read so far was read anonymously.
      client.removeQueries({ predicate: (q) => !['config', 'me'].includes(String(q.queryKey[0])) })
      await client.invalidateQueries({ queryKey: ['me'] })
    },
  })
}

/** Posts the logout; a 401 means there is no session left to end. */
async function postLogout() {
  try {
    await unwrap(api.POST('/webapi/logout'))
  } catch (error) {
    if (!(error instanceof ApiError && error.status === 401)) throw error
  }
}

/**
 * Ends the session. A refused CSRF token is read again and the logout retried
 * once; any other failure keeps the session, for the caller to report.
 */
export function useLogout() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: async () => {
      try {
        await postLogout()
      } catch (error) {
        if (!(error instanceof ApiError && error.code === 'csrf_failed')) throw error
        const me = await client.fetchQuery({ ...meQuery, staleTime: 0 })
        if (me) await postLogout()
      }
    },
    onSuccess: () => {
      setCsrfToken(null)
      client.setQueryData(['me'], null)
      client.removeQueries({ predicate: (q) => !['config', 'me'].includes(String(q.queryKey[0])) })
    },
  })
}

export function useChangePassword() {
  return useMutation({
    mutationFn: (body: { currentPassword: string; newPassword: string }) =>
      unwrap(api.POST('/webapi/me/password', { body })),
  })
}

// ---------------------------------------------------------------- packages

export type PackageListParams = {
  q?: string
  sdk?: 'dart' | 'flutter'
  discontinued?: boolean
  sort?: 'relevance' | 'downloads' | 'updated' | 'name'
  page?: number
  size?: number
}

export function packagesQuery(params: PackageListParams) {
  return queryOptions({
    queryKey: ['packages', params],
    queryFn: ({ signal }) =>
      unwrap(
        api.GET('/webapi/v2/packages', {
          params: {
            query: {
              q: params.q || undefined,
              sdk: params.sdk,
              discontinued: params.discontinued ? 'true' : undefined,
              sort: params.sort,
              page: params.page,
              size: params.size,
            },
          },
          signal,
        }),
      ),
    placeholderData: keepPreviousData,
  })
}

export function usePackages(params: PackageListParams) {
  return useQuery(packagesQuery(params))
}

export function packageQuery(name: string, version?: string) {
  return queryOptions({
    queryKey: ['package', name, version ?? null],
    queryFn: async ({ signal }) => {
      const result = version
        ? await unwrap(
            api.GET('/webapi/package/{name}/{version}', {
              params: { path: { name, version } },
              signal,
            }),
          )
        : await unwrap(api.GET('/webapi/package/{name}', { params: { path: { name } }, signal }))
      return result.data
    },
  })
}

export function usePackage(name: string, version?: string) {
  return useQuery(packageQuery(name, version))
}

export function usePackageStats(name: string, enabled = true) {
  return useQuery({
    queryKey: ['package', name, 'stats'],
    queryFn: ({ signal }) =>
      unwrap(api.GET('/webapi/package/{name}/stats', { params: { path: { name } }, signal })),
    enabled,
  })
}

/** Invalidates everything read about [name], and the lists. */
function usePackageInvalidation() {
  const client = useQueryClient()
  return (name: string) =>
    Promise.all([
      client.invalidateQueries({ queryKey: ['package', name] }),
      client.invalidateQueries({ queryKey: ['packages'] }),
      client.invalidateQueries({ queryKey: ['audit'] }),
    ])
}

export function useRetract() {
  const invalidate = usePackageInvalidation()
  return useMutation({
    mutationFn: ({
      name,
      version,
      retract,
    }: {
      name: string
      version: string
      retract: boolean
    }) =>
      retract
        ? unwrap(
            api.POST('/api/packages/{name}/versions/{version}/retract', {
              params: { path: { name, version } },
            }),
          )
        : unwrap(
            api.POST('/api/packages/{name}/versions/{version}/unretract', {
              params: { path: { name, version } },
            }),
          ),
    onSuccess: (_, { name }) => invalidate(name),
  })
}

export function useDiscontinue() {
  const invalidate = usePackageInvalidation()
  return useMutation({
    mutationFn: ({
      name,
      isDiscontinued,
      replacedBy,
    }: {
      name: string
      isDiscontinued: boolean
      replacedBy?: string | null
    }) =>
      unwrap(
        api.PUT('/api/packages/{name}/discontinue', {
          params: { path: { name } },
          body: { isDiscontinued, replacedBy: isDiscontinued ? replacedBy || null : null },
        }),
      ),
    onSuccess: (_, { name }) => invalidate(name),
  })
}

export function useAddUploader() {
  const invalidate = usePackageInvalidation()
  return useMutation({
    mutationFn: ({ name, email }: { name: string; email: string }) =>
      unwrap(
        api.POST('/api/packages/{name}/uploaders', {
          params: { path: { name } },
          body: { email },
        }),
      ),
    onSuccess: (_, { name }) => invalidate(name),
  })
}

export function useRemoveUploader() {
  const invalidate = usePackageInvalidation()
  return useMutation({
    mutationFn: ({ name, email }: { name: string; email: string }) =>
      unwrap(
        api.DELETE('/api/packages/{name}/uploaders/{email}', {
          params: { path: { name, email } },
        }),
      ),
    onSuccess: (_, { name }) => invalidate(name),
  })
}

export function useTransferOwnership() {
  const invalidate = usePackageInvalidation()
  return useMutation({
    mutationFn: ({ name, email }: { name: string; email: string }) =>
      unwrap(
        api.PUT('/api/packages/{name}/owner', { params: { path: { name } }, body: { email } }),
      ),
    onSuccess: (_, { name }) => invalidate(name),
  })
}

export function useDeleteVersion() {
  const invalidate = usePackageInvalidation()
  return useMutation({
    mutationFn: ({ name, version }: { name: string; version: string }) =>
      unwrap(
        api.DELETE('/api/packages/{name}/versions/{version}', {
          params: { path: { name, version } },
        }),
      ),
    onSuccess: (_, { name }) => invalidate(name),
  })
}

export function useDeletePackage() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: ({ name }: { name: string }) =>
      unwrap(api.DELETE('/api/packages/{name}', { params: { path: { name } } })),
    onSuccess: (_, { name }) => {
      client.removeQueries({ queryKey: ['package', name] })
      return Promise.all([
        client.invalidateQueries({ queryKey: ['packages'] }),
        client.invalidateQueries({ queryKey: ['overview'] }),
      ])
    },
  })
}

// ---------------------------------------------------------------- tokens

export function useTokens(page: number, size = 20) {
  return useQuery({
    queryKey: ['tokens', page, size],
    queryFn: ({ signal }) =>
      unwrap(api.GET('/webapi/tokens', { params: { query: { page, size } }, signal })),
    placeholderData: keepPreviousData,
  })
}

export function useCreateToken() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (body: { name: string; scopes: Scope[]; expiresIn?: string }) =>
      unwrap(api.POST('/webapi/tokens', { body })),
    onSuccess: () => client.invalidateQueries({ queryKey: ['tokens'] }),
  })
}

export function useRevokeToken() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (id: string) =>
      unwrap(api.DELETE('/webapi/tokens/{id}', { params: { path: { id } } })),
    onSuccess: () => client.invalidateQueries({ queryKey: ['tokens'] }),
  })
}

// ---------------------------------------------------------------- users

export function useUsers(q: string, page: number, size = 50) {
  return useQuery({
    queryKey: ['users', q, page, size],
    queryFn: ({ signal }) =>
      unwrap(
        api.GET('/webapi/users', {
          params: { query: { q: q || undefined, page, size } },
          signal,
        }),
      ),
    placeholderData: keepPreviousData,
  })
}

function useInvalidate(...keys: QueryKey[]) {
  const client = useQueryClient()
  return () => Promise.all(keys.map((queryKey) => client.invalidateQueries({ queryKey })))
}

export function useCreateUser() {
  const invalidate = useInvalidate(['users'], ['overview'], ['audit'])
  return useMutation({
    mutationFn: (body: { email: string; role: Role; displayName?: string; password?: string }) =>
      unwrap(api.POST('/webapi/users', { body })),
    onSuccess: invalidate,
  })
}

export function useUpdateUser() {
  const invalidate = useInvalidate(['users'], ['me'], ['audit'])
  return useMutation({
    mutationFn: ({
      id,
      ...body
    }: {
      id: string
      role?: Role
      displayName?: string
      disabled?: boolean
    }) => unwrap(api.PATCH('/webapi/users/{id}', { params: { path: { id } }, body })),
    onSuccess: invalidate,
  })
}

export function useSetUserPassword() {
  const invalidate = useInvalidate(['users'], ['audit'])
  return useMutation({
    mutationFn: ({ id, password }: { id: string; password: string }) =>
      unwrap(
        api.POST('/webapi/users/{id}/password', { params: { path: { id } }, body: { password } }),
      ),
    onSuccess: invalidate,
  })
}

// ---------------------------------------------------------------- admin

export function useOverview() {
  return useQuery({
    queryKey: ['overview'],
    queryFn: ({ signal }) => unwrap(api.GET('/webapi/admin/overview', { signal })),
  })
}

export function useSettings(enabled = true) {
  return useQuery({
    queryKey: ['settings'],
    queryFn: ({ signal }) => unwrap(api.GET('/webapi/settings', { signal })),
    staleTime: 5 * 60_000,
    enabled,
  })
}

export type AuditFilters = {
  action?: string
  actor?: string
  package?: string
  from?: string
  to?: string
  page?: number
  size?: number
}

export function useAudit(filters: AuditFilters) {
  return useQuery({
    queryKey: ['audit', filters],
    queryFn: ({ signal }) =>
      unwrap(
        api.GET('/webapi/audit', {
          params: {
            query: Object.fromEntries(
              Object.entries(filters).filter(([, value]) => value !== undefined && value !== ''),
            ),
          },
          signal,
        }),
      ),
    placeholderData: keepPreviousData,
  })
}

// ---------------------------------------------------------------- webhooks

export function useWebhooks(page: number, size = 50) {
  return useQuery({
    queryKey: ['webhooks', page, size],
    queryFn: ({ signal }) =>
      unwrap(api.GET('/webapi/webhooks', { params: { query: { page, size } }, signal })),
    placeholderData: keepPreviousData,
  })
}

export function webhookQuery(id: string) {
  return queryOptions({
    queryKey: ['webhook', id],
    queryFn: ({ signal }) =>
      unwrap(api.GET('/webapi/webhooks/{id}', { params: { path: { id } }, signal })),
  })
}

export function useWebhook(id: string) {
  return useQuery(webhookQuery(id))
}

export function useDeliveries(id: string, page: number, size = 20) {
  return useQuery({
    queryKey: ['webhook', id, 'deliveries', page, size],
    queryFn: ({ signal }) =>
      unwrap(
        api.GET('/webapi/webhooks/{id}/deliveries', {
          params: { path: { id }, query: { page, size } },
          signal,
        }),
      ),
    placeholderData: keepPreviousData,
  })
}

export function useCreateWebhook() {
  const invalidate = useInvalidate(['webhooks'], ['overview'], ['audit'])
  return useMutation({
    mutationFn: (body: WebhookInput) => unwrap(api.POST('/webapi/webhooks', { body })),
    onSuccess: invalidate,
  })
}

export function useUpdateWebhook() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: ({
      id,
      ...body
    }: {
      id: string
      url?: string
      events?: WebhookEvent[]
      description?: string
      enabled?: boolean
    }) => unwrap(api.PATCH('/webapi/webhooks/{id}', { params: { path: { id } }, body })),
    onSuccess: (_, { id }) =>
      Promise.all([
        client.invalidateQueries({ queryKey: ['webhooks'] }),
        client.invalidateQueries({ queryKey: ['webhook', id] }),
        client.invalidateQueries({ queryKey: ['audit'] }),
      ]),
  })
}

export function useRotateWebhookSecret() {
  const invalidate = useInvalidate(['audit'])
  return useMutation({
    mutationFn: (id: string) =>
      unwrap(api.POST('/webapi/webhooks/{id}/secret', { params: { path: { id } } })),
    onSuccess: invalidate,
  })
}

export function useDeleteWebhook() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (id: string) =>
      unwrap(api.DELETE('/webapi/webhooks/{id}', { params: { path: { id } } })),
    onSuccess: (_, id) => {
      client.removeQueries({ queryKey: ['webhook', id] })
      return Promise.all([
        client.invalidateQueries({ queryKey: ['webhooks'] }),
        client.invalidateQueries({ queryKey: ['overview'] }),
      ])
    },
  })
}

export function useRedeliver() {
  const client = useQueryClient()
  return useMutation({
    mutationFn: ({ id, delivery }: { id: string; delivery: string }) =>
      unwrap(
        api.POST('/webapi/webhooks/{id}/deliveries/{delivery}/redeliver', {
          params: { path: { id, delivery } },
        }),
      ),
    onSuccess: (_, { id }) => client.invalidateQueries({ queryKey: ['webhook', id] }),
  })
}
