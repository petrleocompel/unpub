import 'dart:convert';

import '../../store/audit_store.dart';
import '../../webhooks/webhook_store.dart';
import '../html.dart';
import '../layout.dart';
import 'admin_pages.dart';
import 'package_list_page.dart';

/// The value of a date input for [time], the day in UTC.
String _dateValue(DateTime? time) => time == null ? '' : formatDate(time);

/// The audit page for [page] of the events matching [query].
String auditHref(AuditQuery query, int page) {
  final parameters = {
    ...query.parameters,
    if (query.limit != defaultAuditPageSize) 'size': '${query.limit}',
    if (page != 1) 'page': '$page',
  };
  return parameters.isEmpty
      ? '/admin/audit'
      : '/admin/audit?${Uri(queryParameters: parameters).query}';
}

Html _actor(AuditEvent event) => Html.join([
      event.actor,
      el('br'),
      el('span', {
        'class': 'muted'
      }, [
        event.actorKind,
        if (event.token != null) ' ${event.token}',
      ]),
    ]);

Html _details(AuditEvent event) {
  final details = event.toJson()['details'] as Map;
  if (details.isEmpty) return Html.empty;
  return el('code', {'class': 'details'}, jsonEncode(details));
}

Html auditPage(PageContext context, AuditQuery query, AuditPage page,
    {String? error}) {
  // The day inputs show what was asked, `to` as the last included day.
  final to = query.to;
  final lastDay = to != null && AuditQuery.isDayStart(to)
      ? to.subtract(const Duration(days: 1))
      : to;
  return adminLayout(context, 'Audit log', error: error, [
    el('h2', const {}, 'Audit log'),
    el('form', {
      'class': 'filters',
      'method': 'get',
      'action': '/admin/audit',
    }, [
      el('label', const {}, [
        'Action',
        el('input', {
          'type': 'text',
          'name': 'action',
          'list': 'audit-actions',
          'value': query.action ?? '',
        }),
      ]),
      el('datalist', {
        'id': 'audit-actions'
      }, [
        for (final action in auditActions) el('option', {'value': action}),
      ]),
      el('label', const {}, [
        'Actor (email or token:prefix)',
        el('input', {
          'type': 'text',
          'name': 'actor',
          'value': query.actor ?? '',
        }),
      ]),
      el('label', const {}, [
        'Package',
        el('input', {
          'type': 'text',
          'name': 'package',
          'value': query.package ?? '',
        }),
      ]),
      el('label', const {}, [
        'From (UTC)',
        el('input', {
          'type': 'date',
          'name': 'from',
          'value': _dateValue(query.from),
        }),
      ]),
      el('label', const {}, [
        'To (UTC, included)',
        el('input', {
          'type': 'date',
          'name': 'to',
          'value': _dateValue(lastDay),
        }),
      ]),
      // Filtering again keeps the page size the links carry.
      if (query.limit != defaultAuditPageSize)
        el('input',
            {'type': 'hidden', 'name': 'size', 'value': '${query.limit}'}),
      el('button', {'type': 'submit'}, 'Filter'),
      ' ',
      el('a', {'href': '/admin/audit'}, 'Clear'),
    ]),
    el(
        'p',
        {'class': 'muted', 'role': 'status'},
        page.count == 0
            ? 'No events.'
            : '${page.count} ${page.count == 1 ? 'event' : 'events'}, '
                'newest first.'),
    if (page.events.isNotEmpty)
      el('div', {
        'class': 'table-scroll'
      }, [
        el('table', const {}, [
          el('thead', const {}, [
            el('tr', const {}, [
              for (final heading in [
                'Time',
                'Action',
                'Actor',
                'Package',
                'Target',
                'Address',
                'Details',
              ])
                el('th', {'scope': 'col'}, heading),
            ]),
          ]),
          el('tbody', const {}, [
            for (final event in page.events)
              el('tr', const {}, [
                el('td', const {}, timeElement(event.at, withTime: true)),
                el('td', const {}, el('code', const {}, event.action)),
                el('td', const {}, _actor(event)),
                el('td', const {}, [
                  if (event.package case final package?)
                    el('a', {'href': '/admin/packages/${segment(package)}'},
                        package),
                  if (event.version != null) ' ${event.version}',
                ]),
                el('td', const {}, event.target ?? ''),
                el('td', const {}, event.ip ?? ''),
                el('td', const {}, _details(event)),
              ]),
          ]),
        ]),
      ]),
    pagination(
        current: query.page,
        count: page.count,
        size: query.limit,
        href: (target) => auditHref(query, target)),
  ]);
}

String webhookHref(String id) => '/admin/webhooks/${Uri.encodeComponent(id)}';

/// A secret shown once, with the advice to keep it.
Html _secretBox(String secret) => el('div', {
      'class': 'notice',
      'role': 'status'
    }, [
      el('p', const {},
          'The signing secret, shown only now. Keep it with the receiver:'),
      el('pre', const {}, el('code', {'id': 'webhook-secret'}, secret)),
      el('button', {'type': 'button', 'data-copy': 'webhook-secret'}, 'Copy'),
    ]);

Html _eventChecks(List<String> checked) => el('fieldset', const {}, [
      el('legend', const {}, 'Events'),
      for (final event in webhookEvents)
        el('label', {
          'class': 'check'
        }, [
          el('input', {
            'type': 'checkbox',
            'name': 'events',
            'value': event,
            'checked': checked.contains(event),
          }),
          el('code', const {}, event),
        ]),
    ]);

Html adminWebhooksPage(
  PageContext context,
  List<Webhook> hooks, {
  required bool deliveryEnabled,
  required bool allowHttp,
  String? notice,
  String? error,
  Map<String, Object> form = const {},
}) =>
    adminLayout(context, 'Webhooks', notice: notice, error: error, [
      el('h2', const {}, 'Webhooks'),
      if (!deliveryEnabled)
        el(
            'p',
            {'class': 'error', 'role': 'status'},
            'Delivery is switched off by webhooks.enabled: false. Events are '
                'not queued until it is switched on.'),
      if (hooks.isEmpty)
        el('p', {'class': 'muted'}, 'No webhooks yet.')
      else
        el('div', {
          'class': 'table-scroll'
        }, [
          el('table', const {}, [
            el('thead', const {}, [
              el('tr', const {}, [
                for (final heading in ['URL', 'Events', 'Description', 'State'])
                  el('th', {'scope': 'col'}, heading),
              ]),
            ]),
            el('tbody', const {}, [
              for (final hook in hooks)
                el('tr', const {}, [
                  el('td', const {},
                      el('a', {'href': webhookHref(hook.id)}, '${hook.url}')),
                  el('td', const {}, [
                    for (final (index, event) in hook.events.indexed) ...[
                      if (index > 0) ' ',
                      el('code', const {}, event),
                    ],
                  ]),
                  el('td', const {}, hook.description),
                  el('td', const {}, hook.enabled ? 'Enabled' : 'Disabled'),
                ]),
            ]),
          ]),
        ]),
      el('h2', const {}, 'Add a webhook'),
      postForm(
        context,
        '/admin/webhooks',
        [
          el('label', const {}, [
            allowHttp ? 'URL' : 'URL (https)',
            el('input', {
              'type': 'url',
              'name': 'url',
              'required': true,
              'placeholder': 'https://ci.example.com/hooks/unpub',
              'value': form['url'],
            }),
          ]),
          _eventChecks(form['events'] as List<String>? ?? webhookEvents),
          el('label', const {}, [
            'Description (optional)',
            el('input', {
              'type': 'text',
              'name': 'description',
              'maxlength': '200',
              'value': form['description'],
            }),
          ]),
          el(
              'div',
              const {},
              el('button', {'type': 'submit', 'class': 'primary'},
                  'Add webhook')),
        ],
        className: 'form',
      ),
    ]);

/// Asks before deleting [hook].
Html adminDeleteWebhookPage(PageContext context, Webhook hook) {
  final base = webhookHref(hook.id);
  return adminLayout(context, 'Delete webhook', [
    el('h2', const {}, [
      'Delete the webhook ',
      el('code', const {}, '${hook.url}'),
      '?',
    ]),
    el('p', const {}, [
      'Its delivery log goes with it, and the deliveries still queued are '
          'not sent. Disabling it keeps both instead. This cannot be undone.',
    ]),
    postForm(
      context,
      '$base/delete',
      [
        el('input', {'type': 'hidden', 'name': 'confirm', 'value': 'yes'}),
        el('button', {'type': 'submit', 'class': 'danger'}, 'Delete webhook'),
        ' ',
        el('a', {'href': base}, 'Cancel'),
      ],
      className: 'inline-form',
    ),
  ]);
}

String _deliveryState(Delivery delivery) => switch (delivery.status) {
      DeliveryStatus.pending when delivery.attempt == 0 => 'Queued',
      DeliveryStatus.pending => 'Retrying',
      DeliveryStatus.succeeded => 'Delivered',
      _ => 'Failed',
    };

Html adminWebhookPage(
  PageContext context,
  Webhook hook,
  List<Delivery> deliveries, {
  String? secret,
  String? notice,
  String? error,
}) {
  final base = webhookHref(hook.id);
  return adminLayout(context, 'Webhook', notice: notice, error: error, [
    el('h2', const {}, ['Webhook ', el('code', const {}, '${hook.url}')]),
    if (secret != null) _secretBox(secret),
    el('dl', {
      'class': 'facts'
    }, [
      el('dt', const {}, 'Events'),
      el('dd', const {}, [
        for (final (index, event) in hook.events.indexed) ...[
          if (index > 0) ' ',
          el('code', const {}, event),
        ],
      ]),
      if (hook.description.isNotEmpty) ...[
        el('dt', const {}, 'Description'),
        el('dd', const {}, hook.description),
      ],
      el('dt', const {}, 'State'),
      el('dd', const {}, hook.enabled ? 'Enabled' : 'Disabled'),
      el('dt', const {}, 'Created'),
      el('dd', const {}, [
        timeElement(hook.createdAt, withTime: true),
        if (hook.createdBy != null) ' by ${hook.createdBy}',
      ]),
    ]),
    el('div', {
      'class': 'actions'
    }, [
      postForm(
        context,
        '$base/enabled',
        [
          el('input', {
            'type': 'hidden',
            'name': 'enabled',
            'value': hook.enabled ? 'false' : 'true',
          }),
          el('button', {'type': 'submit'}, hook.enabled ? 'Disable' : 'Enable'),
        ],
        className: 'inline-form',
      ),
      postForm(
        context,
        '$base/secret',
        [
          el('label', {
            'class': 'check'
          }, [
            el('input', {
              'type': 'checkbox',
              'name': 'confirm',
              'value': 'yes',
              'required': true,
            }),
            'The receiver needs the new secret',
          ]),
          ' ',
          el('button', {'type': 'submit'}, 'Rotate secret'),
        ],
        className: 'inline-form',
      ),
      el('a', {'class': 'button danger', 'href': '$base/delete'}, 'Delete…'),
    ]),
    el('h3', const {}, 'Recent deliveries'),
    if (deliveries.isEmpty)
      el('p', {'class': 'muted'}, 'Nothing was delivered yet.')
    else
      el('div', {
        'class': 'table-scroll'
      }, [
        el('table', const {}, [
          el('thead', const {}, [
            el('tr', const {}, [
              for (final heading in [
                'Queued',
                'Event',
                'Package',
                'State',
                'Attempts',
                'Answer',
                '',
              ])
                el('th', {'scope': 'col'}, heading),
            ]),
          ]),
          el('tbody', const {}, [
            for (final delivery in deliveries)
              el('tr', const {}, [
                el('td', const {},
                    timeElement(delivery.createdAt, withTime: true)),
                el('td', const {}, el('code', const {}, delivery.event)),
                el('td', const {}, [
                  delivery.package ?? '',
                  if (delivery.version != null) ' ${delivery.version}',
                ]),
                el('td', const {}, [
                  _deliveryState(delivery),
                  if (delivery.status == DeliveryStatus.pending &&
                      delivery.attempt > 0) ...[
                    el('br'),
                    el('span', {
                      'class': 'muted'
                    }, [
                      'next ',
                      timeElement(delivery.nextAt, withTime: true),
                    ]),
                  ],
                ]),
                el('td', const {}, '${delivery.attempt}'),
                el('td', const {}, [
                  if (delivery.responseStatus != null)
                    el('code', const {}, '${delivery.responseStatus}'),
                  if (delivery.error != null) ...[
                    ' ',
                    el('span', {'class': 'muted'}, delivery.error),
                  ],
                  if (delivery.responseBody case final body?
                      when body.isNotEmpty)
                    el('code', {'class': 'details'}, body),
                ]),
                el('td', {
                  'class': 'actions'
                }, [
                  if (delivery.status != DeliveryStatus.pending)
                    postForm(
                      context,
                      '$base/deliveries/${Uri.encodeComponent(delivery.id)}'
                      '/redeliver',
                      el('button', {'type': 'submit'}, 'Redeliver'),
                      className: 'inline-form',
                    ),
                ]),
              ]),
          ]),
        ]),
      ]),
  ]);
}
