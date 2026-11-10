import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:markdown/markdown.dart' as md;

import 'html.dart';

/// [source], a README or CHANGELOG, as sanitized HTML.
Html renderMarkdown(String source) {
  final String rendered;
  try {
    rendered =
        md.markdownToHtml(source, extensionSet: md.ExtensionSet.gitHubFlavored);
  } catch (_) {
    // A document the renderer chokes on is still worth showing as text.
    return el('pre', const {}, source);
  }
  return sanitizeHtml(rendered);
}

/// Elements kept, each with the attributes it may keep.
const _allowed = <String, Set<String>>{
  'h1': {'align'},
  'h2': {'align'},
  'h3': {'align'},
  'h4': {'align'},
  'h5': {'align'},
  'h6': {'align'},
  'p': {'align'},
  'a': {'href', 'title'},
  'img': {'src', 'alt', 'title', 'align', 'width', 'height'},
  'code': {'class'},
  'pre': {},
  'ul': {},
  'ol': {'start'},
  'li': {},
  'blockquote': {},
  'table': {},
  'caption': {},
  'thead': {},
  'tbody': {},
  'tfoot': {},
  'tr': {},
  'th': {'align'},
  'td': {'align'},
  'strong': {},
  'b': {},
  'em': {},
  'i': {},
  'del': {},
  's': {},
  'sup': {},
  'sub': {},
  'kbd': {},
  'hr': {},
  'br': {},
  'details': {'open'},
  'summary': {},
};

/// Elements removed along with everything inside them.
const _dropped = {
  'script',
  'style',
  'iframe',
  'frame',
  'frameset',
  'object',
  'embed',
  'applet',
  'template',
  'noscript',
  'textarea',
  'select',
  'option',
  'button',
  'input',
  'form',
  'svg',
  'math',
  'head',
  'title',
  'meta',
  'link',
  'base',
};

const _void = {'img', 'hr', 'br'};

final _alignment = RegExp(r'^(left|right|center|justify)$');
final _textAlignStyle =
    RegExp(r'^\s*text-align\s*:\s*(left|right|center)\s*;?\s*$');
final _codeClass = RegExp(r'^language-[a-zA-Z0-9_+#.-]{1,40}$');
final _dimension = RegExp(r'^\d{1,4}%?$');
final _scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*):');
final _ignoredInUrl = RegExp(r'[\x00-\x20\x7f]');

/// [markup] with only the elements and attributes of an allowlist kept.
///
/// URLs must be http, https or relative, and links may also be mailto. Links
/// to absolute URLs open in a new tab, marked `nofollow noopener`.
Html sanitizeHtml(String markup) {
  final fragment = html_parser.parseFragment(markup);
  final out = StringBuffer();
  for (final node in fragment.nodes) {
    _write(out, node);
  }
  return Html.trusted(out.toString());
}

void _write(StringBuffer out, dom.Node node) {
  if (node is dom.Text) {
    out.write(escapeHtml(node.text));
    return;
  }
  if (node is! dom.Element) return;
  final tag = node.localName?.toLowerCase() ?? '';
  if (_dropped.contains(tag)) return;
  final allowed = _allowed[tag];
  if (allowed == null) {
    // Unknown elements give way to their content.
    for (final child in node.nodes) {
      _write(out, child);
    }
    return;
  }

  final attributes = <String, String>{};
  for (final MapEntry(:key, :value) in node.attributes.entries) {
    final name = '$key'.toLowerCase();
    if (!allowed.contains(name)) continue;
    final kept = _attribute(tag, name, value);
    if (kept != null) attributes[name] = kept;
  }
  if (tag == 'th' || tag == 'td') {
    final style = _textAlignStyle.firstMatch(node.attributes['style'] ?? '');
    if (style != null) attributes['align'] = style[1]!;
  }
  if (tag == 'a') {
    final href = attributes['href'];
    if (href != null && _scheme.hasMatch(href) && !href.startsWith('mailto:')) {
      attributes['rel'] = 'nofollow noopener';
      attributes['target'] = '_blank';
    }
  }
  if (tag == 'img' && attributes['src'] == null) return;

  out.write('<$tag');
  for (final MapEntry(:key, :value) in attributes.entries) {
    out.write(' $key="${escapeHtml(value)}"');
  }
  out.write('>');
  if (_void.contains(tag)) return;
  for (final child in node.nodes) {
    _write(out, child);
  }
  out.write('</$tag>');
}

String? _attribute(String tag, String name, String value) {
  switch (name) {
    case 'href':
      return _safeUrl(value, schemes: const {'http', 'https', 'mailto'});
    case 'src':
      return _safeUrl(value, schemes: const {'http', 'https'});
    case 'align':
      final lower = value.trim().toLowerCase();
      return _alignment.hasMatch(lower) ? lower : null;
    case 'class':
      if (tag != 'code') return null;
      final kept = value.split(RegExp(r'\s+')).where(_codeClass.hasMatch);
      return kept.isEmpty ? null : kept.join(' ');
    case 'width' || 'height':
      return _dimension.hasMatch(value.trim()) ? value.trim() : null;
    case 'start':
      return int.tryParse(value.trim())?.toString();
    case 'open':
      return '';
    default:
      return value;
  }
}

/// [url] if it is relative or uses one of [schemes], or null.
///
/// Browsers skip whitespace and control characters inside a scheme, as in
/// `java\tscript:`, so the check runs on the URL without them.
String? _safeUrl(String url, {required Set<String> schemes}) {
  final compact = url.replaceAll(_ignoredInUrl, '');
  if (compact.isEmpty) return null;
  final scheme = _scheme.firstMatch(compact);
  if (scheme != null) {
    return schemes.contains(scheme[1]!.toLowerCase()) ? url.trim() : null;
  }
  // `//host/path` is relative to the scheme only, so it is an absolute URL.
  if (compact.startsWith('//')) return null;
  // A colon before any slash would be read as a scheme by some parsers.
  final firstSlash = compact.indexOf('/');
  final colon = compact.indexOf(':');
  if (colon >= 0 && (firstSlash < 0 || colon < firstSlash)) return null;
  return url.trim();
}
