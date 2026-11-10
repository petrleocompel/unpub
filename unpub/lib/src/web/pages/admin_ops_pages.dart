import 'dart:convert';

import '../../store/audit_store.dart';
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
    if (query.limit != 50) 'size': '${query.limit}',
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
  final lastDay = query.to?.subtract(const Duration(days: 1));
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
