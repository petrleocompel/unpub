import '../auth/accounts.dart';
import '../auth/authenticator.dart';
import '../version.dart';
import 'assets.dart';
import 'html.dart';

/// What every page needs to know about the request it answers.
class PageContext {
  /// Who is signed in, if anyone.
  final Principal? principal;

  /// The path of the request, to mark the current navigation entry.
  final String path;

  /// The search text, kept in the search box of the header.
  final String? query;

  /// Whether the server has user accounts, so a login link makes sense.
  final bool accountsEnabled;

  const PageContext({
    required this.principal,
    required this.path,
    this.query,
    this.accountsEnabled = true,
  });

  /// The CSRF token forms must carry, when signed in with a session.
  String? get csrfToken => principal?.session?.csrfToken;

  bool get isAdmin => principal?.isAdmin ?? false;

  bool get hasSession => principal?.session != null;
}

/// A hidden field holding the CSRF token of the session.
Html csrfField(PageContext context) => el('input', {
      'type': 'hidden',
      'name': 'csrf_token',
      'value': context.csrfToken ?? '',
    });

/// A form posting to [action] with the CSRF token, holding [children].
Html postForm(
  PageContext context,
  String action,
  Object? children, {
  String? className,
  String? confirm,
}) =>
    el('form', {
      'method': 'post',
      'action': action,
      'class': className,
      'data-confirm': confirm,
    }, [
      csrfField(context),
      children
    ]);

Html _navLink(PageContext context, String href, String label,
    {bool Function(String path)? current}) {
  final isCurrent = (current ?? (path) => path == href)(context.path);
  return el(
      'a', {'href': href, 'aria-current': isCurrent ? 'page' : null}, label);
}

/// A complete document with the header, navigation and footer around [body].
Html layout(
  PageContext context, {
  required String title,
  required Object? body,
}) {
  final principal = context.principal;
  return Html.join([
    const Html.trusted('<!DOCTYPE html>'),
    el('html', {
      'lang': 'en'
    }, [
      el('head', const {}, [
        el('meta', {'charset': 'utf-8'}),
        el('meta', {
          'name': 'viewport',
          'content': 'width=device-width, initial-scale=1',
        }),
        el('title', const {}, '$title · unpub'),
        el('link', {'rel': 'stylesheet', 'href': stylesheet.href}),
        el('script', {'src': script.href, 'defer': true}),
      ]),
      el('body', const {}, [
        el('header', {
          'class': 'site-header'
        }, [
          el('div', {
            'class': 'wrap'
          }, [
            el('a', {'class': 'brand', 'href': '/'}, 'unpub'),
            el('form', {
              'class': 'site-search',
              'role': 'search',
              'method': 'get',
              'action': '/packages',
            }, [
              el('label', {'for': 'site-q', 'class': 'visually-hidden'},
                  'Search packages'),
              el('input', {
                'type': 'search',
                'id': 'site-q',
                'name': 'q',
                'value': context.query ?? '',
                'placeholder': 'Search packages',
              }),
              el('button', {'type': 'submit'}, 'Search'),
            ]),
            el('nav', {
              'class': 'site-nav',
              'aria-label': 'Main'
            }, [
              _navLink(context, '/packages', 'Packages',
                  current: (path) => path == '/' || path == '/packages'),
              if (context.isAdmin)
                _navLink(context, '/admin/users', 'Admin',
                    current: (path) => path.startsWith('/admin')),
              if (principal != null && principal.userId != null)
                _navLink(context, '/account', 'Account'),
              if (context.hasSession)
                postForm(
                    context,
                    '/logout',
                    el('button', {'type': 'submit', 'class': 'link'},
                        'Log out (${principal!.email})'))
              else if (principal == null && context.accountsEnabled)
                _navLink(context, '/login', 'Log in'),
            ]),
          ]),
        ]),
        el('main', {'class': 'wrap', 'id': 'content'}, body),
        el('footer', {
          'class': 'site-footer'
        }, [
          el('div', {
            'class': 'wrap'
          }, [
            'unpub $packageVersion · ',
            el('a', {'href': 'https://github.com/petrleocompel/unpub'},
                'source'),
          ]),
        ]),
      ]),
    ]),
  ]);
}

/// A short human readable role name.
String roleLabel(Role role) => switch (role) {
      Role.admin => 'Administrator',
      Role.publisher => 'Publisher',
      Role.reader => 'Reader',
    };

/// [time] as an ISO date in UTC.
String formatDate(DateTime? time) {
  if (time == null) return '';
  final utc = time.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year}-${two(utc.month)}-${two(utc.day)}';
}

/// [time] as an ISO date and minute in UTC.
String formatDateTime(DateTime? time) {
  if (time == null) return '';
  final utc = time.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${formatDate(utc)} ${two(utc.hour)}:${two(utc.minute)} UTC';
}

/// A `<time>` element for [time].
Html timeElement(DateTime? time, {bool withTime = false}) {
  if (time == null) return Html.text('–');
  return el('time', {'datetime': time.toUtc().toIso8601String()},
      withTime ? formatDateTime(time) : formatDate(time));
}

/// A message box for [notice] or [error].
Html messages({String? notice, String? error}) => Html.join([
      if (notice != null)
        el('p', {'class': 'notice', 'role': 'status'}, notice),
      if (error != null) el('p', {'class': 'error', 'role': 'alert'}, error),
    ]);
