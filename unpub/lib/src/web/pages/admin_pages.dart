import '../../auth/accounts.dart';
import '../../models.dart';
import '../html.dart';
import '../layout.dart';
import 'package_list_page.dart';

Html _adminNav(PageContext context) => el('nav', {
      'aria-label': 'Administration'
    }, [
      el('ul', {
        'class': 'tabs'
      }, [
        for (final (href, label) in const [
          ('/admin/users', 'Users'),
          ('/admin/packages', 'Packages'),
          ('/admin/settings', 'Settings'),
        ])
          el('li', const {}, [
            el(
                'a',
                {
                  'href': href,
                  'aria-current': context.path == href ||
                          (href == '/admin/packages' &&
                              context.path.startsWith('/admin/packages/'))
                      ? 'page'
                      : null,
                },
                label),
          ]),
      ]),
    ]);

Html _adminLayout(PageContext context, String title, List<Object?> body,
        {String? notice, String? error}) =>
    layout(context, title: '$title · Admin', body: [
      el('h1', const {}, 'Administration'),
      _adminNav(context),
      messages(notice: notice, error: error),
      ...body,
    ]);

Html _roleSelect(String name, Role? selected, {String? id}) => el('select', {
      'name': name,
      'id': id,
    }, [
      for (final role in Role.values)
        el('option', {'value': role.name, 'selected': role == selected},
            roleLabel(role)),
    ]);

Html adminUsersPage(PageContext context, List<User> users,
        {String? notice, String? error}) =>
    _adminLayout(context, 'Users', notice: notice, error: error, [
      el('h2', const {}, 'Users'),
      el('div', {
        'class': 'table-scroll'
      }, [
        el('table', const {}, [
          el('thead', const {}, [
            el('tr', const {}, [
              for (final heading in [
                'Email',
                'Name',
                'Role',
                'State',
                'Last login',
                'Password',
              ])
                el('th', {'scope': 'col'}, heading),
            ]),
          ]),
          el('tbody', const {}, [
            for (final user in users) _userRow(context, user),
          ]),
        ]),
      ]),
      el('h2', const {}, 'Create a user'),
      postForm(
        context,
        '/admin/users',
        [
          el('label', const {}, [
            'Email',
            el('input', {'type': 'email', 'name': 'email', 'required': true}),
          ]),
          el('label', const {}, [
            'Name (optional)',
            el('input', {'type': 'text', 'name': 'displayName'}),
          ]),
          el('label', const {}, ['Role', _roleSelect('role', Role.publisher)]),
          el('label', const {}, [
            'Initial password (optional, without one the user cannot log in)',
            el('input', {
              'type': 'password',
              'name': 'password',
              'autocomplete': 'new-password',
              'minlength': '$minPasswordLength',
            }),
          ]),
          el(
              'div',
              const {},
              el('button', {'type': 'submit', 'class': 'primary'},
                  'Create user')),
        ],
        className: 'form',
      ),
    ]);

Html _userRow(PageContext context, User user) {
  final action = '/admin/users/${Uri.encodeComponent(user.id)}';
  final roleId = 'role-${user.id}';
  final passwordId = 'password-${user.id}';
  return el('tr', const {}, [
    el('td', const {}, user.email),
    el('td', const {}, user.displayName),
    el('td', {
      'class': 'actions'
    }, [
      postForm(
        context,
        action,
        [
          el('label', {'for': roleId, 'class': 'visually-hidden'},
              'Role of ${user.email}'),
          _roleSelect('role', user.role, id: roleId),
          el('button', {'type': 'submit'}, 'Set role'),
        ],
        className: 'inline-form',
      ),
    ]),
    el('td', {
      'class': 'actions'
    }, [
      user.disabled ? 'Disabled ' : 'Enabled ',
      postForm(
        context,
        action,
        [
          el('input', {
            'type': 'hidden',
            'name': 'disabled',
            'value': user.disabled ? 'false' : 'true',
          }),
          el(
              'button',
              {
                'type': 'submit',
                'class': user.disabled ? null : 'danger',
              },
              user.disabled ? 'Enable' : 'Disable'),
        ],
        className: 'inline-form',
        confirm: user.disabled ? null : 'Disable ${user.email}?',
      ),
    ]),
    el('td', const {}, timeElement(user.lastLoginAt)),
    el('td', {
      'class': 'actions'
    }, [
      if (user.passwordHash == null) el('span', {'class': 'muted'}, 'Not set '),
      postForm(
        context,
        '$action/password',
        [
          el('label', {'for': passwordId, 'class': 'visually-hidden'},
              'New password for ${user.email}'),
          el('input', {
            'type': 'password',
            'id': passwordId,
            'name': 'password',
            'autocomplete': 'new-password',
            'minlength': '$minPasswordLength',
            'required': true,
          }),
          el('button', {'type': 'submit'}, 'Set password'),
        ],
        className: 'inline-form',
      ),
    ]),
  ]);
}

/// The address of the page [page] of the packages matching [query].
String _adminPackagesHref(String? query, int page, int size) {
  final parameters = {
    if (query != null) 'q': query,
    if (size != maxPageSize) 'size': '$size',
    if (page != 1) 'page': '$page',
  };
  return parameters.isEmpty
      ? '/admin/packages'
      : '/admin/packages?${Uri(queryParameters: parameters).query}';
}

Html adminPackagesPage(
    PageContext context, String? query, UnpubQueryResult result,
    {int page = 1, int size = maxPageSize}) {
  final first = (page - 1) * size + 1;
  return _adminLayout(context, 'Packages', [
    el('h2', const {}, 'Packages'),
    el('form', {
      'class': 'filters',
      'method': 'get',
      'action': '/admin/packages',
    }, [
      el('label', const {}, [
        'Name or description',
        el('input', {'type': 'search', 'name': 'q', 'value': query ?? ''}),
      ]),
      if (size != maxPageSize)
        el('input', {'type': 'hidden', 'name': 'size', 'value': '$size'}),
      el('button', {'type': 'submit'}, 'Search'),
    ]),
    el(
        'p',
        {'class': 'muted', 'role': 'status'},
        result.packages.isEmpty
            ? '${result.count} ${result.count == 1 ? 'package' : 'packages'}'
                '${result.count > 0 ? ', none on page $page' : ''}.'
            : 'Showing $first–${first + result.packages.length - 1} of '
                '${result.count} '
                '${result.count == 1 ? 'package' : 'packages'}.'),
    el('div', {
      'class': 'table-scroll'
    }, [
      el('table', const {}, [
        el('thead', const {}, [
          el('tr', const {}, [
            for (final heading in [
              'Name',
              'Latest',
              'Versions',
              'Uploaders',
              'State'
            ])
              el('th', {'scope': 'col'}, heading),
          ]),
        ]),
        el('tbody', const {}, [
          for (final package in result.packages)
            el('tr', const {}, [
              el(
                  'td',
                  const {},
                  el('a', {'href': '/admin/packages/${segment(package.name)}'},
                      package.name)),
              el('td', const {}, package.latest.version),
              el('td', const {}, '${package.versions.length}'),
              el('td', const {}, (package.uploaders ?? const []).join(', ')),
              el('td', const {},
                  package.isDiscontinued ? 'Discontinued' : 'Active'),
            ]),
        ]),
      ]),
    ]),
    pagination(
        current: page,
        count: result.count,
        size: size,
        href: (target) => _adminPackagesHref(query, target, size)),
  ]);
}

Html adminPackagePage(
    PageContext context, UnpubPackage package, List<UnpubVersion> versions,
    {String? notice, String? error}) {
  final base = '/admin/packages/${segment(package.name)}';
  return _adminLayout(context, package.name, notice: notice, error: error, [
    el('h2', const {}, [
      'Package ',
      el('a', {'href': packageHref(package.name)}, package.name),
    ]),
    el('h3', const {}, 'Discontinued'),
    postForm(
      context,
      '$base/discontinue',
      [
        el('label', {
          'class': 'check'
        }, [
          el('input', {
            'type': 'checkbox',
            'name': 'discontinued',
            'value': '1',
            'checked': package.isDiscontinued,
          }),
          'Discontinued',
        ]),
        el('label', const {}, [
          'Replaced by (optional)',
          el('input', {
            'type': 'text',
            'name': 'replacedBy',
            'value': package.replacedBy ?? '',
            'pattern': '[a-z_][a-z0-9_]*',
          }),
        ]),
        el('div', const {},
            el('button', {'type': 'submit', 'class': 'primary'}, 'Save')),
      ],
      className: 'form',
    ),
    el('h3', const {}, 'Uploaders'),
    el('ul', const {}, [
      for (final email in package.uploaders ?? const <String>[])
        el('li', const {}, [
          email,
          ' ',
          postForm(
            context,
            '$base/uploaders/remove',
            [
              el('input', {'type': 'hidden', 'name': 'email', 'value': email}),
              el('button', {
                'type': 'submit',
                'class': 'danger'
              }, [
                'Remove',
                el('span', {'class': 'visually-hidden'}, ' $email')
              ]),
            ],
            className: 'inline-form',
            confirm: 'Remove $email from the uploaders?',
          ),
        ]),
    ]),
    postForm(
      context,
      '$base/uploaders',
      [
        el('label', {'for': 'uploader-email', 'class': 'visually-hidden'},
            'Email of the uploader to add'),
        el('input', {
          'type': 'email',
          'id': 'uploader-email',
          'name': 'email',
          'required': true,
          'placeholder': 'email@example.com',
        }),
        el('button', {'type': 'submit'}, 'Add uploader'),
      ],
      className: 'inline-form',
    ),
    el('h3', const {}, 'Versions'),
    el('div', {
      'class': 'table-scroll'
    }, [
      el('table', const {}, [
        el('thead', const {}, [
          el('tr', const {}, [
            for (final heading in [
              'Version',
              'Published',
              'Uploader',
              'State',
              'Actions'
            ])
              el('th', {'scope': 'col'}, heading),
          ]),
        ]),
        el('tbody', const {}, [
          for (final version in versions)
            el('tr', const {}, [
              el(
                  'td',
                  const {},
                  el('a', {'href': versionHref(package.name, version.version)},
                      version.version)),
              el('td', const {}, timeElement(version.createdAt)),
              el('td', const {}, version.uploader ?? '–'),
              el('td', const {},
                  version.isRetracted ? 'Retracted' : 'Available'),
              el('td', {
                'class': 'actions'
              }, [
                postForm(
                  context,
                  '$base/versions/${segment(version.version)}/${version.isRetracted ? 'unretract' : 'retract'}',
                  el('button', {
                    'type': 'submit',
                    'class': version.isRetracted ? null : 'danger',
                  }, [
                    version.isRetracted ? 'Restore' : 'Retract',
                    el('span', {'class': 'visually-hidden'},
                        ' ${version.version}'),
                  ]),
                  className: 'inline-form',
                  confirm: version.isRetracted
                      ? null
                      : 'Retract ${package.name} ${version.version}?',
                ),
              ]),
            ]),
        ]),
      ]),
    ]),
  ]);
}

/// The settings overview, as section → key → displayed value.
Html adminSettingsPage(
        PageContext context, Map<String, Map<String, String>>? settings) =>
    _adminLayout(context, 'Settings', [
      el('h2', const {}, 'Effective configuration'),
      if (settings == null)
        el('p', {'class': 'muted'},
            'This server was started without a configuration to show.')
      else ...[
        el('p', {'class': 'muted'},
            'Read only. Secrets are not shown. Change the configuration file or the UNPUB_* environment and restart to apply changes.'),
        for (final MapEntry(key: section, value: values)
            in settings.entries) ...[
          el('h3', const {}, section),
          el('div', {
            'class': 'table-scroll'
          }, [
            el('table', const {}, [
              el('tbody', const {}, [
                for (final MapEntry(:key, :value) in values.entries)
                  el('tr', const {}, [
                    el('th', {'scope': 'row'},
                        el('code', const {}, '$section.$key')),
                    el('td', const {}, value),
                  ]),
              ]),
            ]),
          ]),
        ],
      ],
    ]);
