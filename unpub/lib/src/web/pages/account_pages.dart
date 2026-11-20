import '../../auth/account_service.dart';
import '../../auth/accounts.dart';
import '../html.dart';
import '../layout.dart';

/// The login form.
Html loginPage(
  PageContext context, {
  required String loginToken,
  String? next,
  String? email,
  String? error,
}) =>
    layout(context, title: 'Log in', body: [
      el('h1', const {}, 'Log in'),
      messages(error: error),
      el('form', {
        'class': 'form',
        'method': 'post',
        'action': '/login',
      }, [
        el('input',
            {'type': 'hidden', 'name': 'login_token', 'value': loginToken}),
        if (next != null)
          el('input', {'type': 'hidden', 'name': 'next', 'value': next}),
        el('label', const {}, [
          'Email',
          el('input', {
            'type': 'email',
            'name': 'email',
            'value': email ?? '',
            'autocomplete': 'username',
            'required': true,
            'autofocus': email == null,
          }),
        ]),
        el('label', const {}, [
          'Password',
          el('input', {
            'type': 'password',
            'name': 'password',
            'autocomplete': 'current-password',
            'required': true,
            'autofocus': email != null,
          }),
        ]),
        el('div', const {},
            el('button', {'type': 'submit', 'class': 'primary'}, 'Log in')),
      ]),
    ]);

/// How long a new token may live, as offered by the form.
const tokenExpiryChoices = [
  ('', 'Never'),
  ('7d', '7 days'),
  ('30d', '30 days'),
  ('90d', '90 days'),
  ('52w', '1 year'),
];

class AccountView {
  final User user;
  final List<ApiToken> tokens;

  /// The scopes a new token can get.
  final Set<Scope> grantableScopes;

  /// A token created by this request, whose secret is shown once.
  final CreatedToken? created;
  final String hostedUrl;
  final DateTime now;
  final String? notice;
  final String? error;

  const AccountView({
    required this.user,
    required this.tokens,
    required this.grantableScopes,
    required this.hostedUrl,
    required this.now,
    this.created,
    this.notice,
    this.error,
  });
}

String _tokenState(ApiToken token, DateTime now) {
  if (token.revokedAt != null) return 'Revoked ${formatDate(token.revokedAt)}';
  final expiry = token.expiresAt;
  if (expiry != null && !expiry.isAfter(now)) return 'Expired';
  return 'Active';
}

Html accountPage(PageContext context, AccountView view) {
  final user = view.user;
  final created = view.created;
  return layout(context, title: 'Account', body: [
    el('h1', const {}, 'Account'),
    messages(notice: view.notice, error: view.error),
    if (created != null)
      el('div', {
        'class': 'secret',
        'role': 'status'
      }, [
        el('p', const {}, [
          'Token ',
          el('strong', const {}, created.token.name),
          ' created. Copy it now, it is not shown again.',
        ]),
        el('div', {
          'class': 'snippet'
        }, [
          el('pre', const {}, el('code', {'id': 'new-token'}, created.secret)),
          el(
              'button',
              {'type': 'button', 'class': 'copy', 'data-copy': 'new-token'},
              'Copy'),
        ]),
        el('p', const {}, [
          'Add it to the pub client with ',
          el('code', const {}, 'dart pub token add ${view.hostedUrl}'),
          ' and paste it when asked.',
        ]),
      ]),
    el('section', {
      'aria-labelledby': 'profile'
    }, [
      el('h2', {'id': 'profile'}, 'Profile'),
      el('div', {
        'class': 'table-scroll'
      }, [
        el('table', const {}, [
          el('tbody', const {}, [
            for (final (label, value) in [
              ('Email', Html.text(user.email)),
              ('Name', Html.text(user.displayName)),
              ('Role', Html.text(roleLabel(user.role))),
              ('Member since', timeElement(user.createdAt)),
              ('Last login', timeElement(user.lastLoginAt, withTime: true)),
            ])
              el('tr', const {}, [
                el('th', {'scope': 'row'}, label),
                el('td', const {}, value),
              ]),
          ]),
        ]),
      ]),
    ]),
    el('section', {
      'aria-labelledby': 'tokens'
    }, [
      el('h2', {'id': 'tokens'}, 'API tokens'),
      el('p', {'class': 'muted'},
          'Personal tokens let the pub client read and publish as you.'),
      if (view.tokens.isEmpty)
        el('p', const {}, 'You have no tokens yet.')
      else
        el('div', {
          'class': 'table-scroll'
        }, [
          el('table', const {}, [
            el('thead', const {}, [
              el('tr', const {}, [
                for (final heading in [
                  'Name',
                  'Prefix',
                  'Scopes',
                  'Created',
                  'Last used',
                  'Expires',
                  'State',
                  'Actions',
                ])
                  el('th', {'scope': 'col'}, heading),
              ]),
            ]),
            el('tbody', const {}, [
              for (final token in view.tokens)
                el('tr', const {}, [
                  el('td', const {}, token.name),
                  el('td', const {}, el('code', const {}, token.prefix)),
                  el(
                      'td',
                      const {},
                      [for (final scope in token.scopes) scope.name]
                          .join(', ')),
                  el('td', const {}, timeElement(token.createdAt)),
                  el('td', const {}, timeElement(token.lastUsedAt)),
                  el(
                      'td',
                      const {},
                      token.expiresAt == null
                          ? Html.text('Never')
                          : timeElement(token.expiresAt)),
                  el('td', const {}, _tokenState(token, view.now)),
                  el('td', {
                    'class': 'actions'
                  }, [
                    if (token.revokedAt == null)
                      postForm(
                        context,
                        '/account/tokens/${Uri.encodeComponent(token.id)}/revoke',
                        el('button', {
                          'type': 'submit',
                          'class': 'danger'
                        }, [
                          'Revoke',
                          el('span', {'class': 'visually-hidden'},
                              ' ${token.name}')
                        ]),
                        className: 'inline-form',
                        confirm: 'Revoke the token ${token.name}?',
                      ),
                  ]),
                ]),
            ]),
          ]),
        ]),
      el('h3', const {}, 'Create a token'),
      postForm(
        context,
        '/account/tokens',
        [
          el('label', const {}, [
            'Name',
            el('input', {
              'type': 'text',
              'name': 'name',
              'required': true,
              'maxlength': '100',
              'placeholder': 'laptop, CI, …',
            }),
          ]),
          el('fieldset', const {}, [
            el('legend', const {}, 'Scopes'),
            for (final scope in Scope.values)
              if (view.grantableScopes.contains(scope))
                el('label', {
                  'class': 'check'
                }, [
                  el('input', {
                    'type': 'checkbox',
                    'name': 'scope',
                    'value': scope.name,
                    'checked': true,
                  }),
                  scope == Scope.read
                      ? 'read: download packages'
                      : 'publish: publish and manage packages',
                ]),
          ]),
          el('label', const {}, [
            'Expires after',
            el('select', {
              'name': 'expiresIn'
            }, [
              for (final (value, label) in tokenExpiryChoices)
                el('option', {'value': value, 'selected': value == '90d'},
                    label),
            ]),
          ]),
          el(
              'div',
              const {},
              el('button', {'type': 'submit', 'class': 'primary'},
                  'Create token')),
        ],
        className: 'form',
      ),
    ]),
    el('section', {
      'aria-labelledby': 'password'
    }, [
      el('h2', {'id': 'password'}, 'Change password'),
      postForm(
        context,
        '/account/password',
        [
          el('label', const {}, [
            'Current password',
            el('input', {
              'type': 'password',
              'name': 'currentPassword',
              'autocomplete': 'current-password',
              'required': true,
            }),
          ]),
          el('label', const {}, [
            'New password',
            el('input', {
              'type': 'password',
              'name': 'newPassword',
              'autocomplete': 'new-password',
              'minlength': '$minPasswordLength',
              'required': true,
            }),
          ]),
          el(
              'div',
              const {},
              el('button', {'type': 'submit', 'class': 'primary'},
                  'Change password')),
        ],
        className: 'form',
      ),
    ]),
  ]);
}
