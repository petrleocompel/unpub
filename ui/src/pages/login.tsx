import { useEffect, useId, useState, type FormEvent } from 'react'
import { Eye, EyeOff, Loader2, Lock, LogIn } from 'lucide-react'
import { Navigate, useNavigate, useSearchParams } from 'react-router'
import { ApiError, errorMessage, formatWait } from '@/api/client'
import { useLogin } from '@/api/queries'
import { hostedUrl, useSession } from '@/auth/session'
import { Field, FormError, invalidField } from '@/components/form'
import { IconTile } from '@/components/states'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Page } from '@/layout/root'
import { isSafeNext } from '@/lib/base'
import { toast } from '@/lib/toast'
import { useTitle } from '@/lib/use-title'

/** 42 → "0:42", 120 → "2:00". */
export function formatCountdown(seconds: number) {
  const whole = Math.max(0, Math.ceil(seconds))
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`
}

/**
 * A wait that ends at [until], ticking every second: `block(seconds)`
 * starts it, `secondsLeft` is 0 once it has passed.
 */
function useCountdown() {
  const [clock, setClock] = useState<{ until: number; now: number } | null>(null)
  useEffect(() => {
    if (!clock || clock.now >= clock.until) return
    const timer = window.setTimeout(
      () => setClock((current) => current && { ...current, now: Date.now() }),
      1000,
    )
    return () => window.clearTimeout(timer)
  }, [clock])
  return {
    secondsLeft: clock ? Math.max(0, (clock.until - clock.now) / 1000) : 0,
    block: (seconds: number) => {
      const now = Date.now()
      setClock({ until: now + seconds * 1000, now })
    },
  }
}

export function LoginPage() {
  const id = useId()
  const [params] = useSearchParams()
  const navigate = useNavigate()
  const { me, config } = useSession()
  const login = useLogin()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [showPassword, setShowPassword] = useState(false)
  // A 429 with Retry-After: no attempt before then.
  const { secondsLeft, block } = useCountdown()
  const blocked = secondsLeft > 0
  useTitle('Log in')

  const nextParam = params.get('next')
  const next = isSafeNext(nextParam) && !nextParam.startsWith('/login') ? nextParam : '/'

  if (me && !login.isPending && !login.isSuccess) return <Navigate to={next} replace />

  const submit = (event: FormEvent) => {
    event.preventDefault()
    if (blocked) return
    login.mutate(
      { email: email.trim(), password },
      {
        onSuccess: (result) => {
          toast.success('Logged in', result.user.email)
          navigate(next, { replace: true })
        },
        onError: (error) => {
          setPassword('')
          if (error instanceof ApiError && error.status === 429 && error.retryAfter) {
            block(error.retryAfter)
          }
        },
      },
    )
  }

  const error = login.isError ? login.error : null
  const rateLimited = error instanceof ApiError && error.status === 429
  const message = !error ? null : rateLimited ? (
    <>
      <b>Too many attempts.</b>{' '}
      {error.retryAfter ? (
        blocked ? (
          <>
            {/* The countdown ticks for the eye; the alert is announced once. */}
            <span aria-hidden>Try again in {formatCountdown(secondsLeft)}.</span>
            <span className="sr-only">Try again in {formatWait(error.retryAfter)}.</span>
          </>
        ) : (
          'You can try again now.'
        )
      ) : (
        'Try again later.'
      )}
    </>
  ) : error instanceof ApiError && error.status === 401 ? (
    'The email or the password is not right.'
  ) : (
    errorMessage(error)
  )

  return (
    <Page full>
      <div className="grid flex-1 place-items-start justify-items-center bg-surface px-4 py-8 sm:place-items-center sm:py-14">
        <div className="grid w-full max-w-[400px] gap-5 rounded-xl border bg-card p-5.5 shadow-sm sm:p-7">
          <div className="grid justify-items-start gap-2">
            <IconTile icon={Lock} />
            <h1 className="text-xl font-semibold">Log in to unpub</h1>
            <p className="text-[0.8125rem] leading-[1.375rem] text-muted-foreground">
              {config.readAccess === 'authenticated' ? (
                <>
                  <span className="font-mono">{new URL(hostedUrl(config)).host}</span> is a private
                  registry. Log in to browse packages and create tokens.
                </>
              ) : (
                'Log in to manage your tokens and packages.'
              )}
            </p>
          </div>
          {config.accounts ? (
            <form onSubmit={submit} className="grid gap-5">
              <FormError
                id={`${id}-error`}
                message={message}
                tone={rateLimited ? 'warning' : 'error'}
              />
              <Field id={`${id}-email`} label="Email">
                <Input
                  id={`${id}-email`}
                  type="email"
                  autoComplete="username"
                  required
                  autoFocus
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                  {...invalidField(`${id}-error`, login.isError && !rateLimited)}
                />
              </Field>
              <Field id={`${id}-password`} label="Password">
                <div className="relative">
                  <Input
                    id={`${id}-password`}
                    type={showPassword ? 'text' : 'password'}
                    autoComplete="current-password"
                    required
                    value={password}
                    className="pr-10"
                    onChange={(event) => setPassword(event.target.value)}
                    {...invalidField(`${id}-error`, login.isError && !rateLimited)}
                  />
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon-xs"
                    className="absolute top-1/2 right-[5px] -translate-y-1/2 text-muted-foreground"
                    aria-label={showPassword ? 'Hide password' : 'Show password'}
                    aria-pressed={showPassword}
                    aria-controls={`${id}-password`}
                    onClick={() => setShowPassword((shown) => !shown)}
                  >
                    {showPassword ? <EyeOff aria-hidden /> : <Eye aria-hidden />}
                  </Button>
                </div>
              </Field>
              <Button type="submit" className="h-10 w-full" disabled={login.isPending || blocked}>
                {login.isPending ? (
                  <Loader2 aria-hidden className="animate-spin" />
                ) : (
                  <LogIn aria-hidden />
                )}
                Log in
              </Button>
            </form>
          ) : (
            <p className="text-[0.8125rem] text-muted-foreground">
              This server has no user accounts.
            </p>
          )}
          <p className="text-center text-xs text-muted-foreground">
            No account? Ask an administrator of this registry; there is no self sign-up.
          </p>
        </div>
      </div>
    </Page>
  )
}
