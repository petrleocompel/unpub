import '../html.dart';
import '../layout.dart';

/// A short page explaining a failed request.
Html errorPage(PageContext context, int status, String title, String message,
        {Object? extra}) =>
    layout(context, title: title, body: [
      el('h1', const {}, title),
      el('p', const {}, message),
      if (extra != null) extra,
      el('p', const {}, [
        el('a', {'href': '/'}, 'Back to the package list'),
      ]),
    ]);
