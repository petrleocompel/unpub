import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:test/test.dart';
import 'package:unpub/src/web/markdown.dart';
import 'package:unpub/src/web/pages/package_page.dart' show markdownLinks;

/// The elements of [markup], parsed as a browser would.
List<dom.Element> _elements(String markup) =>
    html_parser.parseFragment(markup).querySelectorAll('*');

final _allowedUrl = RegExp(r'^(https?:|mailto:|#md-)', caseSensitive: false);

/// Fails unless no element of [markup] can run script or leave the allowed
/// URLs, whatever it looks like as text.
void _expectInert(String markup, {String? reason}) {
  for (final element in _elements(markup)) {
    final tag = element.localName!;
    expect(tag, isNot(anyOf('script', 'style', 'svg', 'math', 'iframe')),
        reason: reason);
    for (final MapEntry(:key, :value) in element.attributes.entries) {
      final name = '$key'.toLowerCase();
      expect(name, isNot(startsWith('on')), reason: '$reason: $markup');
      expect(name, isNot(anyOf('style', 'srcset', 'formaction', 'xlink:href')),
          reason: reason);
      if (name == 'href' || name == 'src') {
        expect(value, matches(_allowedUrl), reason: '$reason: $markup');
      }
      if (name == 'id') expect(value, startsWith('md-'), reason: reason);
      if (name == 'target') {
        expect(value, '_blank', reason: reason);
        expect(element.attributes['rel'], 'nofollow noopener', reason: reason);
      }
    }
  }
}

String _render(String source, {MarkdownLinks? links}) =>
    renderMarkdown(source, links: links).markup;

void main() {
  group('sanitizer', () {
    const attacks = {
      'svg': '<svg onload="alert(1)"><circle r="1"/></svg>after',
      'svg in a link': '<a href="https://ok.example"><svg onload=alert(1)>',
      'math': '<math><mi xlink:href="javascript:alert(1)">x</mi></math>',
      'malformed nesting': '<a href="x"<img src=y onerror=alert(1)>text</a>',
      'unclosed attribute':
          '<img src="https://ok.example/a.png onerror=alert(1)',
      'entity in the scheme': '<a href="java&#115;cript:alert(1)">x</a>',
      'hex entity': '<a href="&#x6A;avascript:alert(1)">x</a>',
      'named entity colon': '<a href="javascript&colon;alert(1)">x</a>',
      'tab in the scheme': '<a href="java\tscript:alert(1)">x</a>',
      'newline in the scheme': '<a href="java\nscript:alert(1)">x</a>',
      'leading space': '<a href=" javascript:alert(1)">x</a>',
      'control character': '<a href="\u0001javascript:alert(1)">x</a>',
      'markdown entity': '[x](java&#115;cript:alert(1))',
      'markdown mixed case': '[x](JaVaScRiPt:alert(1))',
      'vbscript': '<a href="vbscript:msgbox(1)">x</a>',
      'data link': '<a href="data:text/html,<script>alert(1)</script>">x</a>',
      'data image': '<img src="data:image/svg+xml;base64,PHN2Zz4=" alt="d">',
      'markdown data image': '![d](data:image/png;base64,AAAA)',
      'attribute breakout':
          '<img src="https://ok.example/a.png&quot; onmouseover=&quot;alert(1)" '
              'alt="x">',
      'title breakout': '<a href="https://ok.example" '
          'title=\'" onmouseover="alert(1)\'>x</a>',
      'markdown breakout': '![x](https://ok.example/a.png" onmouseover="a(1))',
      'srcset': '<img src="https://ok.example/a.png" '
          'srcset="javascript:alert(1) 1x, https://evil.example/b.png 2x">',
      'attacker target': '<a href="https://ok.example" target="_self" '
          'rel="opener">x</a>',
      'target on a fragment': '<a href="#usage" target="_blank">x</a>',
      'protocol relative': '<a href="//evil.example/">x</a>',
      'base': '<base href="https://evil.example/">x',
      'form': '<form action="https://evil.example"><button formaction="x">',
      'style': '<p style="background:url(javascript:alert(1))">x</p>',
      'meta refresh': '<meta http-equiv="refresh" content="0;url=https://e">',
    };

    for (final MapEntry(key: name, value: source) in attacks.entries) {
      test('neutralizes $name', () {
        _expectInert(_render(source), reason: name);
        _expectInert(
            _render(source,
                links: MarkdownLinks.forRepository(
                    Uri.parse('https://github.com/o/r'))),
            reason: '$name with links');
        // Without the markdown renderer, which escapes some of it.
        _expectInert(sanitizeHtml(source).markup, reason: '$name as HTML');
      });
    }

    test('keeps the safe parts of what it neutralizes', () {
      final breakout = _elements(_render(attacks['attribute breakout']!));
      final image = breakout.singleWhere((item) => item.localName == 'img');
      expect(image.attributes.keys, unorderedEquals(['src', 'alt']));

      final title = _elements(_render(attacks['title breakout']!))
          .singleWhere((item) => item.localName == 'a');
      expect(title.attributes['title'], '" onmouseover="alert(1)');

      final target = _elements(_render(attacks['attacker target']!))
          .singleWhere((item) => item.localName == 'a');
      expect(target.attributes, {
        'href': 'https://ok.example',
        'rel': 'nofollow noopener',
        'target': '_blank',
      });

      final fragment = _elements(_render(attacks['target on a fragment']!))
          .singleWhere((item) => item.localName == 'a');
      expect(fragment.attributes, {'href': '#md-usage'});

      for (final name in ['entity in the scheme', 'tab in the scheme']) {
        final markup = _render(attacks[name]!);
        expect(
            _elements(markup).where((item) => item.localName == 'a'), isEmpty);
        expect(markup, contains('x'));
      }
      expect(_render(attacks['svg']!), contains('after'));
    });
  });

  group('relative links', () {
    const source = '''
# Usage

See [the guide](doc/guide.md), [the license](/LICENSE),
[a section](doc/guide.md#setup), [up](../other/README.md),
[here](#usage), [mail](mailto:a@example.com), [site](https://example.com/x).

![logo](assets/logo.png) ![badge](https://img.example/badge.svg)
<img src="./shot.png" alt="Screenshot"> <img src="shot.png">
''';

    Map<String, String> hrefs(String markup) => {
          for (final link in _elements(markup).where((e) => e.localName == 'a'))
            link.text: link.attributes['href']!,
        };

    test('without a repository keep only their text', () {
      final markup = _render(source);
      _expectInert(markup);
      expect(hrefs(markup), {
        'here': '#md-usage',
        'mail': 'mailto:a@example.com',
        'site': 'https://example.com/x',
      });
      expect(markup, contains('See the guide, the license,'));
      final images = [
        for (final image
            in _elements(markup).where((e) => e.localName == 'img'))
          image.attributes['src'],
      ];
      expect(images, ['https://img.example/badge.svg']);
      expect(markup, contains('logo'));
      expect(markup, contains('Screenshot'));
    });

    test('lead into the repository', () {
      final markup = _render(source,
          links:
              MarkdownLinks.forRepository(Uri.parse('https://github.com/o/r')));
      _expectInert(markup);
      expect(hrefs(markup), {
        'the guide': 'https://github.com/o/r/blob/HEAD/doc/guide.md',
        'the license': 'https://github.com/o/r/blob/HEAD/LICENSE',
        'a section': 'https://github.com/o/r/blob/HEAD/doc/guide.md#setup',
        'up': 'https://github.com/o/r/blob/other/README.md',
        'here': '#md-usage',
        'mail': 'mailto:a@example.com',
        'site': 'https://example.com/x',
      });
      // Relative images are not served, also with a repository.
      expect(
          _elements(markup).where((e) => e.localName == 'img'), hasLength(1));
    });

    test('lead into the directory of a package in a monorepo', () {
      final links = MarkdownLinks.forRepository(
          Uri.parse('https://github.com/o/r/tree/main/pkgs/a'))!;
      expect(links.resolve('doc.md').toString(),
          'https://github.com/o/r/blob/main/pkgs/a/doc.md');
      expect(links.resolve('../b/README.md').toString(),
          'https://github.com/o/r/blob/main/pkgs/b/README.md');
      expect(links.resolve('/LICENSE').toString(),
          'https://github.com/o/r/blob/main/LICENSE');
      final gitlab = MarkdownLinks.forRepository(
          Uri.parse('https://gitlab.com/g/p/-/tree/dev/x'))!;
      expect(gitlab.resolve('y.md').toString(),
          'https://gitlab.com/g/p/-/blob/dev/x/y.md');
      expect(
          MarkdownLinks.forRepository(Uri.parse('https://github.com/o/r.git'))!
              .resolve('a.md')
              .toString(),
          'https://github.com/o/r/blob/HEAD/a.md');
    });

    test('come from the repository, or a homepage on a forge, over https', () {
      String? base(Map<String, dynamic> pubspec) =>
          markdownLinks(pubspec)?.resolve('a.md')?.toString();
      expect(base({'repository': 'https://git.example.com/o/r'}),
          'https://git.example.com/o/r/blob/HEAD/a.md');
      expect(
          base({
            'repository': 'https://git.example.com/o/r',
            'homepage': 'https://github.com/o/h'
          }),
          'https://git.example.com/o/r/blob/HEAD/a.md');
      expect(base({'homepage': 'https://github.com/o/h'}),
          'https://github.com/o/h/blob/HEAD/a.md');
      expect(base({'homepage': 'https://example.com/o/h'}), isNull);
      expect(base({'repository': 'http://github.com/o/r'}), isNull);
      expect(base({'repository': 'javascript:alert(1)//o/r'}), isNull);
      expect(base({'repository': 'https://github.com/'}), isNull);
      expect(base({'repository': 42}), isNull);
      expect(base({}), isNull);
    });
  });

  group('headings', () {
    test('have prefixed ids that fragments lead to', () {
      final markup = _render('''
# Getting started

## Usage

Setext heading
--------------

<h3 id="content">Raw</h3>
<h3 id="1digit">Digit</h3>
<h3 id='a"b'>Quote</h3>
<h3 id="${'x' * 200}">Long</h3>
<p id="usage">Not a heading</p>

[go](#usage) [start](#getting-started) [bad](#a"b)
''');
      _expectInert(markup);
      final ids = {
        for (final element in _elements(markup))
          if (element.id.isNotEmpty) element.text: element.id,
      };
      expect(ids, {
        'Getting started': 'md-getting-started',
        'Usage': 'md-usage',
        'Setext heading': 'md-setext-heading',
        'Raw': 'md-content',
      });
      final hrefs = [
        for (final link in _elements(markup).where((e) => e.localName == 'a'))
          link.attributes['href'],
      ];
      expect(hrefs, ['#md-usage', '#md-getting-started']);
    });
  });

  test('renders only the beginning of a long document', () {
    final line = '${'word ' * 19}word\n';
    final source = line * (maxMarkdownLength ~/ line.length + 100);
    final markup = _render(source);
    expect(markup, contains('only its beginning is shown'));
    expect(markup.length, lessThan(maxMarkdownLength + 4096));
    expect(_render(line), isNot(contains('only its beginning')));
  });
}
