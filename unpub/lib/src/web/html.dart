/// A tiny HTML builder that escapes everything it is given.
///
/// Text and attribute values always pass through [escapeHtml]. The only way to
/// insert markup as is goes through [Html.trusted], which is meant for the
/// output of the sanitizer and for constants, so that unescaped insertion is
/// explicit and easy to find.
///
/// Pages are written as if they were served at `/`. [underBasePath] serves
/// them under a prefix instead: every root-relative URL the builder writes
/// into a link, a form, a script or a stylesheet gets the prefix, so that no
/// template has to know where it is mounted. Markup inserted with
/// [Html.trusted], such as a sanitized README, is left as it is.
library;

import 'dart:async';

const _basePathKey = #unpub.web.basePath;

/// The attributes holding a URL that the base path applies to.
const _urlAttributes = {'href', 'action', 'src', 'formaction'};

/// Runs [render] with [basePath], such as `/classic`, put in front of the
/// root-relative URLs it builds. An empty [basePath] changes nothing.
T underBasePath<T>(String basePath, T Function() render) => basePath.isEmpty
    ? render()
    : runZoned(render, zoneValues: {_basePathKey: basePath});

/// The base path of the page being rendered, `''` at the root.
String get currentBasePath => Zone.current[_basePathKey] as String? ?? '';

/// [url] under [currentBasePath] if it is a path on this server, as `/x`
/// and unlike `//host/x` or `https://host/x`.
String rebase(String url) {
  final base = currentBasePath;
  if (base.isEmpty || !url.startsWith('/') || url.startsWith('//')) return url;
  return '$base$url';
}

/// Markup that is safe to insert into a page as is.
final class Html {
  final String markup;

  const Html._(this.markup);

  /// [markup] inserted without escaping. Only for markup produced by this
  /// builder, by the sanitizer or written in code.
  const Html.trusted(this.markup);

  static const empty = Html._('');

  /// [text] escaped.
  factory Html.text(Object? text) => Html._(escapeHtml('${text ?? ''}'));

  /// The concatenation of [children], see [el] for what a child can be.
  factory Html.join(Iterable<Object?> children) {
    final out = StringBuffer();
    _writeChild(out, children);
    return Html._(out.toString());
  }

  @override
  String toString() => markup;
}

const _voidElements = {
  'area',
  'base',
  'br',
  'col',
  'hr',
  'img',
  'input',
  'link',
  'meta',
  'source',
  'wbr',
};

final _namePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9-]*$');

/// The element [tag] with [attributes] and [children].
///
/// An attribute whose value is null or false is left out, and one whose value
/// is true is written without a value. A child is [Html], inserted as is,
/// null, skipped, an [Iterable] of children, or anything else, escaped as
/// text.
Html el(String tag,
    [Map<String, Object?> attributes = const {}, Object? children]) {
  assert(_namePattern.hasMatch(tag), 'invalid tag $tag');
  final out = StringBuffer('<$tag');
  _writeAttributes(out, attributes);
  out.write('>');
  if (_voidElements.contains(tag)) {
    assert(children == null, '$tag cannot have children');
    return Html._(out.toString());
  }
  _writeChild(out, children);
  out.write('</$tag>');
  return Html._(out.toString());
}

void _writeAttributes(StringBuffer out, Map<String, Object?> attributes) {
  for (final MapEntry(:key, :value) in attributes.entries) {
    assert(_namePattern.hasMatch(key), 'invalid attribute $key');
    if (value == null || value == false) continue;
    if (value == true) {
      out.write(' $key');
    } else if (_urlAttributes.contains(key)) {
      out.write(' $key="${escapeHtml(rebase('$value'))}"');
    } else {
      out.write(' $key="${escapeHtml('$value')}"');
    }
  }
}

void _writeChild(StringBuffer out, Object? child) {
  switch (child) {
    case null:
      return;
    case Html():
      out.write(child.markup);
    case Iterable<Object?>():
      for (final item in child) {
        _writeChild(out, item);
      }
    default:
      out.write(escapeHtml('$child'));
  }
}

/// [text] with the characters that are special in HTML text and in quoted
/// attribute values replaced by references.
String escapeHtml(String text) {
  if (!text.contains(_special)) return text;
  return text.replaceAllMapped(_special, (match) {
    switch (match[0]) {
      case '&':
        return '&amp;';
      case '<':
        return '&lt;';
      case '>':
        return '&gt;';
      case '"':
        return '&quot;';
      default:
        return '&#39;';
    }
  });
}

final _special = RegExp('[&<>"\']');
