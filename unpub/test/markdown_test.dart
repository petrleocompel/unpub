import 'package:test/test.dart';
import 'package:unpub/src/web/markdown.dart';
import 'package:unpub/src/web/pages/package_page.dart' show markdownLinks;

import 'markdown_attacks.dart';

String _render(String source, {MarkdownLinks? links}) =>
    renderMarkdown(source, links: links).markup;

void main() {
  group('sanitizer', () {
    for (final MapEntry(key: name, value: source) in markdownAttacks.entries) {
      test('neutralizes $name', () {
        expectInert(_render(source), reason: name);
        expectInert(
            _render(source,
                links: MarkdownLinks.forRepository(
                    Uri.parse('https://github.com/o/r'))),
            reason: '$name with links');
        // Without the markdown renderer, which escapes some of it.
        expectInert(sanitizeHtml(source).markup, reason: '$name as HTML');
      });
    }

    test('keeps the safe parts of what it neutralizes', () {
      final breakout =
          elementsOf(_render(markdownAttacks['attribute breakout']!));
      final image = breakout.singleWhere((item) => item.localName == 'img');
      expect(image.attributes.keys, unorderedEquals(['src', 'alt']));

      final title = elementsOf(_render(markdownAttacks['title breakout']!))
          .singleWhere((item) => item.localName == 'a');
      expect(title.attributes['title'], '" onmouseover="alert(1)');

      final target = elementsOf(_render(markdownAttacks['attacker target']!))
          .singleWhere((item) => item.localName == 'a');
      expect(target.attributes, {
        'href': 'https://ok.example',
        'rel': 'nofollow noopener',
        'target': '_blank',
      });

      final fragment =
          elementsOf(_render(markdownAttacks['target on a fragment']!))
              .singleWhere((item) => item.localName == 'a');
      expect(fragment.attributes, {'href': '#md-usage'});

      for (final name in ['entity in the scheme', 'tab in the scheme']) {
        final markup = _render(markdownAttacks[name]!);
        expect(
            elementsOf(markup).where((item) => item.localName == 'a'), isEmpty);
        expect(markup, contains('x'));
      }
      expect(_render(markdownAttacks['svg']!), contains('after'));
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
          for (final link
              in elementsOf(markup).where((e) => e.localName == 'a'))
            link.text: link.attributes['href']!,
        };

    test('without a repository keep only their text', () {
      final markup = _render(source);
      expectInert(markup);
      expect(hrefs(markup), {
        'here': '#md-usage',
        'mail': 'mailto:a@example.com',
        'site': 'https://example.com/x',
      });
      expect(markup, contains('See the guide, the license,'));
      final images = [
        for (final image
            in elementsOf(markup).where((e) => e.localName == 'img'))
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
      expectInert(markup);
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
          elementsOf(markup).where((e) => e.localName == 'img'), hasLength(1));
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

## 2.0.0
<h3 id='a"b'>Quote</h3>
<h3 id="${'x' * 200}">Long</h3>
<p id="usage">Not a heading</p>

[go](#usage) [start](#getting-started) [bad](#a"b)
''');
      expectInert(markup);
      final ids = {
        for (final element in elementsOf(markup))
          if (element.id.isNotEmpty) element.text: element.id,
      };
      expect(ids, {
        'Getting started': 'md-getting-started',
        'Usage': 'md-usage',
        'Setext heading': 'md-setext-heading',
        'Raw': 'md-content',
        'Digit': 'md-1digit',
        '2.0.0': 'md-200',
      });
      final hrefs = [
        for (final link in elementsOf(markup).where((e) => e.localName == 'a'))
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
