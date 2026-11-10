import { useId, useState, type FormEvent } from 'react'
import { Loader2, LogIn } from 'lucide-react'
import { Navigate, useNavigate, useSearchParams } from 'react-router'
import { ApiError, errorMessage, formatWait } from '@/api/client'
import { useLogin } from '@/api/queries'
import { useSession } from '@/auth/session'
import { Field, FormError, invalidField } from '@/components/form'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Page } from '@/layout/root'
import { isSafeNext } from '@/lib/base'
import { toast } from '@/lib/toast'
import { useTitle } from '@/lib/use-title'

function loginError(error: unknown) {
  if (error instanceof ApiError) {
    if (error.status === 401) return 'The email or the password is wrong.'
    if (error.status === 429) {
      return error.retryAfter
        ? `Too many failed attempts. Try again in ${formatWait(error.retryAfter)}.`
        : 'Too many failed attempts. Try again later.'
    }
  }
  return errorMessage(error)
}

export function LoginPage() {
  const id = useId()
  const [params] = useSearchParams()
  const navigate = useNavigate()
  const { me, config } = useSession()
  const login = useLogin()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  useTitle('Log in')

  const nextParam = params.get('next')
  const next = isSafeNext(nextParam) && !nextParam.startsWith('/login') ? nextParam : '/'

  if (me && !login.isPending && !login.isSuccess) return <Navigate to={next} replace />

  const submit = (event: FormEvent) => {
    event.preventDefault()
    login.mutate(
      { email: email.trim(), password },
      {
        onSuccess: (result) => {
          toast.success('Logged in', result.user.email)
          navigate(next, { replace: true })
        },
        onError: () => setPassword(''),
      },
    )
  }

  return (
    <Page>
      <div className="mx-auto grid max-w-sm gap-6 py-8">
        <Card>
          <CardHeader>
            <CardTitle>
              <h1 className="text-xl">Log in to unpub</h1>
            </CardTitle>
            <CardDescription>
              {config.readAccess === 'authenticated'
                ? 'This registry is private. Log in to browse its packages.'
                : 'Log in to manage your tokens and packages.'}
            </CardDescription>
          </CardHeader>
          <CardContent>
            {config.accounts ? (
              <form onSubmit={submit} className="grid gap-4" noValidate={false}>
                <Field id={`${id}-email`} label="Email">
                  <Input
                    id={`${id}-email`}
                    type="email"
                    autoComplete="username"
                    required
                    autoFocus
                    value={email}
                    onChange={(event) => setEmail(event.target.value)}
                    {...invalidField(`${id}-error`, login.isError)}
                  />
                </Field>
                <Field id={`${id}-password`} label="Password">
                  <Input
                    id={`${id}-password`}
                    type="password"
                    autoComplete="current-password"
                    required
                    value={password}
                    onChange={(event) => setPassword(event.target.value)}
                    {...invalidField(`${id}-error`, login.isError)}
                  />
                </Field>
                <FormError
                  id={`${id}-error`}
                  message={login.isError ? loginError(login.error) : null}
                />
                <Button type="submit" disabled={login.isPending}>
                  {login.isPending ? (
                    <Loader2 aria-hidden className="animate-spin" />
                  ) : (
                    <LogIn aria-hidden />
                  )}
                  Log in
                </Button>
              </form>
            ) : (
              <p className="text-sm text-muted-foreground">This server has no user accounts.</p>
            )}
          </CardContent>
        </Card>
        <p className="text-center text-sm text-muted-foreground">
          No account? Ask an administrator of this registry: there is no self sign-up.
        </p>
      </div>
    </Page>
  )
}
