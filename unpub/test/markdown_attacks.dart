/// Markdown and HTML that try to run script or leave the allowed URLs,
/// shared by the sanitizer tests and those of the JSON detail.
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:test/test.dart';

/// The elements of [markup], parsed as a browser would.
List<dom.Element> elementsOf(String markup) =>
    html_parser.parseFragment(markup).querySelectorAll('*');

final _allowedUrl =
    RegExp(r'^(https?://[^/?#@\\]+|mailto:|#md-)', caseSensitive: false);

/// Fails unless no element of [markup] can run script or leave the allowed
/// URLs, whatever it looks like as text.
void expectInert(String markup, {String? reason}) {
  for (final element in elementsOf(markup)) {
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

/// By name, what each attack is.
const markdownAttacks = {
  'svg': '<svg onload="alert(1)"><circle r="1"/></svg>after',
  'svg in a link': '<a href="https://ok.example"><svg onload=alert(1)>',
  'math': '<math><mi xlink:href="javascript:alert(1)">x</mi></math>',
  'malformed nesting': '<a href="x"<img src=y onerror=alert(1)>text</a>',
  'unclosed attribute': '<img src="https://ok.example/a.png onerror=alert(1)',
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
  'scheme without host': '<a href="https:evil">x</a>',
  'scheme with one slash': '<img src="https:/evil/a.png" alt="x">',
  'markdown scheme without host': '[x](https:evil) ![y](HTTPS:evil.png)',
  'backslash host': '<a href="https:\\\\evil.example/">x</a>',
  'backslash after the host': '<a href="https://ok.example\\@evil">x</a>',
  'empty host': '<a href="https:///evil.example/">x</a>',
  'userinfo': '<a href="https://ok.example@evil.example/">x</a>',
  'base': '<base href="https://evil.example/">x',
  'form': '<form action="https://evil.example"><button formaction="x">',
  'style': '<p style="background:url(javascript:alert(1))">x</p>',
  'meta refresh': '<meta http-equiv="refresh" content="0;url=https://e">',
};
