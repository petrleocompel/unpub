import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:markdown/markdown.dart' as md;

import 'html.dart';

/// The longest README or CHANGELOG rendered, in characters. Only the start
/// of a longer one is shown.
const maxMarkdownLength = 512 * 1024;

/// Where links relative to a README or CHANGELOG lead: into the repository
/// of the package, browsed on its forge.
class MarkdownLinks {
  /// The directory of the package, for `docs/usage.md` or `../other`.
  final Uri directory;

  /// The root of the repository, for `/docs/usage.md`.
  final Uri root;

  const MarkdownLinks._(this.directory, this.root);

  /// The links into [repository], an https URL, GitHub style: relative
  /// paths are files under `<repository>/blob/HEAD/`. A repository URL
  /// naming a directory, as `https://github.com/o/r/tree/main/pkgs/a`, is
  /// browsed from that directory and branch.
  static MarkdownLinks? forRepository(Uri? repository) {
    if (repository == null ||
        !repository.isScheme('https') ||
        repository.host.isEmpty ||
        repository.hasQuery ||
        repository.hasFragment ||
        repository.userInfo.isNotEmpty) {
      return null;
    }
    var segments = [
      for (final segment in repository.pathSegments)
        if (segment.isNotEmpty) segment,
    ];
    if (segments.length < 2) return null;
    // `/-/tree/<ref>/...` on GitLab, `/tree/<ref>/...` on GitHub.
    final tree = segments.indexOf('tree');
    final List<String> rootSegments;
    if (tree >= 2 && tree + 1 < segments.length) {
      rootSegments = [
        ...segments.sublist(0, tree),
        'blob',
        segments[tree + 1],
      ];
      segments = [...rootSegments, ...segments.sublist(tree + 2)];
    } else {
      if (segments.last.endsWith('.git')) {
        segments = [
          ...segments.sublist(0, segments.length - 1),
          segments.last.substring(0, segments.last.length - 4),
        ];
      }
      rootSegments = [...segments, 'blob', 'HEAD'];
      segments = rootSegments;
    }
    Uri directory(List<String> path) => Uri(
        scheme: 'https',
        host: repository.host,
        port: repository.hasPort ? repository.port : null,
        pathSegments: [...path, '']);
    return MarkdownLinks._(directory(segments), directory(rootSegments));
  }

  /// [reference], a path relative to the document, as a URL on the forge,
  /// or null if it leaves it.
  Uri? resolve(String reference) {
    final uri = Uri.tryParse(reference);
    if (uri == null || uri.hasScheme || uri.hasAuthority) return null;
    final Uri resolved;
    if (uri.path.startsWith('/')) {
      resolved = root.resolveUri(uri.replace(path: uri.path.substring(1)));
    } else {
      resolved = directory.resolveUri(uri);
    }
    if (resolved.host != root.host || resolved.scheme != 'https') return null;
    return resolved;
  }
}

/// [source], a README or CHANGELOG, as sanitized HTML.
///
/// Links relative to the document lead into [links], or are removed with
/// only their text left. Relative images are replaced by their alt text.
Html renderMarkdown(String source, {MarkdownLinks? links}) {
  var text = source;
  final truncated = text.length > maxMarkdownLength;
  if (truncated) {
    final cut = text.lastIndexOf('\n', maxMarkdownLength);
    text = text.substring(0, cut > 0 ? cut : maxMarkdownLength);
  }
  final String rendered;
  try {
    rendered = md.markdownToHtml(text, extensionSet: md.ExtensionSet.gitHubWeb);
  } catch (_) {
    // A document the renderer chokes on is still worth showing as text.
    return el('pre', const {}, text);
  }
  final html = sanitizeHtml(rendered, links: links);
  if (!truncated) return html;
  return Html.join([
    html,
    el('p', {'class': 'muted'},
        'This file is longer than 512 KiB, only its beginning is shown.'),
  ]);
}

/// The prefix of the id of a heading in a document, so that it cannot be
/// the id of an element of the page.
const markdownIdPrefix = 'md-';

final _idPattern = RegExp(r'^[a-zA-Z0-9][\w.-]{0,127}$');

/// Elements kept, each with the attributes it may keep.
const _allowed = <String, Set<String>>{
  'h1': {'align', 'id'},
  'h2': {'align', 'id'},
  'h3': {'align', 'id'},
  'h4': {'align', 'id'},
  'h5': {'align', 'id'},
  'h6': {'align', 'id'},
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

/// An `http` or `https` URL with a host, so `https:evil` and `https:/evil`,
/// which browsers resolve against the page, do not pass as absolute.
final _absoluteHttp =
    RegExp(r'^https?://[^/?#@\\]+(?:[/?#]|$)', caseSensitive: false);

/// [markup] with only the elements and attributes of an allowlist kept.
///
/// Links must be http, https or mailto URLs, fragments, or relative paths,
/// which lead into [links] or are removed, keeping their text. Images must be
/// http or https URLs, and others are replaced by their alt text. Links to
/// absolute URLs open in a new tab, marked `nofollow noopener`. Headings keep
/// an id, prefixed with [markdownIdPrefix], and fragments are prefixed alike.
Html sanitizeHtml(String markup, {MarkdownLinks? links}) {
  final fragment = html_parser.parseFragment(markup);
  final out = StringBuffer();
  final sanitizer = _Sanitizer(out, links);
  for (final node in fragment.nodes) {
    sanitizer.write(node);
  }
  return Html.trusted(out.toString());
}

class _Sanitizer {
  final StringBuffer out;
  final MarkdownLinks? links;

  _Sanitizer(this.out, this.links);

  void writeChildren(dom.Node node) {
    for (final child in node.nodes) {
      write(child);
    }
  }

  void write(dom.Node node) {
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
      writeChildren(node);
      return;
    }

    final attributes = <String, String>{};
    for (final MapEntry(:key, :value) in node.attributes.entries) {
      final name = '$key'.toLowerCase();
      if (!allowed.contains(name)) continue;
      final kept = switch (name) {
        'href' => _href(value),
        _ => _attribute(tag, name, value),
      };
      if (kept != null) attributes[name] = kept;
    }
    if (tag == 'th' || tag == 'td') {
      final style = _textAlignStyle.firstMatch(node.attributes['style'] ?? '');
      if (style != null) attributes['align'] = style[1]!;
    }
    if (tag == 'a') {
      final href = attributes['href'];
      if (href == null) {
        // A link that leads nowhere safe is its text.
        writeChildren(node);
        return;
      }
      if (_scheme.hasMatch(href) && !href.startsWith('mailto:')) {
        attributes['rel'] = 'nofollow noopener';
        attributes['target'] = '_blank';
      }
    }
    if (tag == 'img' && attributes['src'] == null) {
      out.write(escapeHtml(node.attributes['alt']?.trim() ?? ''));
      return;
    }

    out.write('<$tag');
    for (final MapEntry(:key, :value) in attributes.entries) {
      out.write(' $key="${escapeHtml(value)}"');
    }
    out.write('>');
    if (_void.contains(tag)) return;
    writeChildren(node);
    out.write('</$tag>');
  }

  /// [url] as a link target, or null to drop the link.
  String? _href(String url) {
    final compact = url.replaceAll(_ignoredInUrl, '');
    if (compact.startsWith('#')) {
      final id = compact.substring(1);
      return _idPattern.hasMatch(id) ? '#$markdownIdPrefix$id' : null;
    }
    final safe = _safeUrl(url, schemes: const {'http', 'https', 'mailto'});
    if (safe == null || _scheme.hasMatch(compact)) return safe;
    // A path relative to the document, which is only on the forge.
    return links?.resolve(compact)?.toString();
  }
}

String? _attribute(String tag, String name, String value) {
  switch (name) {
    case 'src':
      // A relative image is a file of the package, not served here.
      final url = _safeUrl(value, schemes: const {'http', 'https'});
      return url != null && _scheme.hasMatch(url) ? url : null;
    case 'id':
      final id = value.trim();
      return _idPattern.hasMatch(id) ? '$markdownIdPrefix$id' : null;
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
/// A relative URL is never kept as is by the callers, as it would resolve
/// against the page of the package.
///
/// Browsers skip whitespace and control characters inside a scheme, as in
/// `java\tscript:`, so the check runs on the URL without them.
String? _safeUrl(String url, {required Set<String> schemes}) {
  final compact = url.replaceAll(_ignoredInUrl, '');
  if (compact.isEmpty) return null;
  final scheme = _scheme.firstMatch(compact);
  if (scheme != null) {
    final name = scheme[1]!.toLowerCase();
    if (!schemes.contains(name)) return null;
    // A backslash is a slash to browsers, so `https:\\evil` is absolute to
    // them, and `https:evil` is relative to the page. Both are refused.
    if ((name == 'http' || name == 'https') &&
        (compact.contains('\\') || !_absoluteHttp.hasMatch(compact))) {
      return null;
    }
    return url.trim();
  }
  // `//host/path` is relative to the scheme only, so it is an absolute URL.
  if (compact.startsWith('//')) return null;
  // A colon before any slash would be read as a scheme by some parsers.
  final firstSlash = compact.indexOf('/');
  final colon = compact.indexOf(':');
  if (colon >= 0 && (firstSlash < 0 || colon < firstSlash)) return null;
  return url.trim();
}
