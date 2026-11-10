import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

/// A file served from `/static/`, kept in the binary.
class StaticAsset {
  final String name;
  final String contentType;
  final List<int> bytes;

  /// Strong validator of [bytes].
  final String etag;

  StaticAsset._(this.name, this.contentType, this.bytes)
      : etag = '"${sha256.convert(bytes).toString().substring(0, 32)}"';

  StaticAsset(String name, String contentType, String content)
      : this._(name, contentType, utf8.encode(content));

  /// The path to link to, which changes with the content so that the asset can
  /// be cached for good.
  String get href => '/static/$name?v=${etag.substring(1, 13)}';
}

final staticAssets = {
  for (final asset in [
    StaticAsset('app.css', 'text/css; charset=utf-8', _css),
    StaticAsset('app.js', 'text/javascript; charset=utf-8', _js),
  ])
    asset.name: asset,
};

final StaticAsset stylesheet = staticAssets['app.css']!;
final StaticAsset script = staticAssets['app.js']!;

const _css = r'''
:root {
  color-scheme: light dark;
  --bg: #ffffff;
  --fg: #1f2328;
  --muted: #59636e;
  --border: #d1d9e0;
  --subtle: #f6f8fa;
  --accent: #0b63ce;
  --accent-fg: #ffffff;
  --danger: #c4314b;
  --ok: #1a7f37;
  --warn: #9a6700;
  --radius: 6px;
  --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0d1117;
    --fg: #e6edf3;
    --muted: #9198a1;
    --border: #3d444d;
    --subtle: #161b22;
    --accent: #4493f8;
    --accent-fg: #0d1117;
    --danger: #f47067;
    --ok: #57ab5a;
    --warn: #c69026;
  }
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--fg);
  font: 15px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
}
a { color: var(--accent); text-decoration: none; }
a:hover, a:focus-visible { text-decoration: underline; }
h1, h2, h3 { line-height: 1.25; }
h1 { font-size: 1.6rem; margin: 0 0 .25rem; }
h2 { font-size: 1.25rem; }
code, pre, kbd { font-family: var(--mono); font-size: .9em; }
.wrap { max-width: 1100px; margin: 0 auto; padding: 0 1rem; }
.visually-hidden {
  position: absolute; width: 1px; height: 1px; overflow: hidden;
  clip: rect(0 0 0 0); white-space: nowrap;
}

/* Header and footer */
.site-header { border-bottom: 1px solid var(--border); background: var(--subtle); }
.site-header .wrap { display: flex; flex-wrap: wrap; align-items: center; gap: .5rem 1rem; padding: .6rem 1rem; }
.brand { font-weight: 700; font-size: 1.15rem; color: var(--fg); }
.site-search { flex: 1 1 220px; display: flex; gap: .4rem; }
.site-search input { flex: 1; min-width: 0; }
.site-nav { display: flex; flex-wrap: wrap; align-items: center; gap: .25rem .9rem; }
.site-nav a[aria-current="page"] { font-weight: 600; color: var(--fg); }
.site-nav form { margin: 0; }
main { padding: 1.25rem 0 2rem; min-height: 60vh; }
.site-footer { border-top: 1px solid var(--border); color: var(--muted); font-size: .85rem; }
.site-footer .wrap { padding: 1rem; }

/* Forms */
input[type="text"], input[type="search"], input[type="email"], input[type="password"], select {
  font: inherit; color: inherit; background: var(--bg);
  border: 1px solid var(--border); border-radius: var(--radius); padding: .35rem .55rem;
}
input:focus-visible, select:focus-visible, button:focus-visible, a:focus-visible {
  outline: 2px solid var(--accent); outline-offset: 1px;
}
button, .button {
  font: inherit; cursor: pointer; display: inline-block;
  border: 1px solid var(--border); border-radius: var(--radius);
  background: var(--subtle); color: var(--fg); padding: .35rem .8rem;
}
button.primary, .button.primary { background: var(--accent); border-color: var(--accent); color: var(--accent-fg); }
button.danger { color: var(--danger); }
button.link { border: 0; background: none; color: var(--accent); padding: 0; }
.form { display: grid; gap: .75rem; max-width: 26rem; }
.form label { display: grid; gap: .25rem; font-weight: 500; }
.form .check { display: flex; gap: .4rem; align-items: center; font-weight: 400; }
fieldset { border: 1px solid var(--border); border-radius: var(--radius); padding: .5rem .75rem; margin: 0; }
legend { padding: 0 .3rem; }
.inline-form { display: inline-flex; flex-wrap: wrap; gap: .35rem; align-items: center; margin: 0; }
.filters { display: flex; flex-wrap: wrap; gap: .5rem 1rem; align-items: end; margin-bottom: 1rem; }
.filters label { display: grid; gap: .2rem; font-size: .85rem; color: var(--muted); }
.filters .check { display: flex; align-items: center; gap: .35rem; }

/* Messages */
.notice, .error, .secret {
  border: 1px solid var(--border); border-left-width: 4px; border-radius: var(--radius);
  padding: .6rem .8rem; margin: 0 0 1rem; background: var(--subtle);
}
.notice { border-left-color: var(--ok); }
.error { border-left-color: var(--danger); }
.warning { border-left-color: var(--warn); }
.secret code { word-break: break-all; }
.muted { color: var(--muted); }

/* Badges */
.badge {
  display: inline-block; font-size: .72rem; font-weight: 600; line-height: 1.6;
  padding: 0 .45rem; border-radius: 999px; border: 1px solid var(--border);
  color: var(--muted); vertical-align: middle; text-transform: uppercase; letter-spacing: .02em;
}
.badge.flutter { color: #027dfd; border-color: #027dfd; }
.badge.dart { color: #0175c2; border-color: #0175c2; }
.badge.discontinued, .badge.retracted { color: var(--danger); border-color: var(--danger); }
.badge.proxied { color: var(--warn); border-color: var(--warn); }

/* Package list */
.package-list { list-style: none; margin: 0; padding: 0; }
.package-list li { padding: .9rem 0; border-bottom: 1px solid var(--border); }
.package-list h2 { font-size: 1.1rem; margin: 0 0 .2rem; display: flex; flex-wrap: wrap; gap: .4rem; align-items: center; }
.package-list p { margin: .2rem 0; }
.meta { color: var(--muted); font-size: .85rem; display: flex; flex-wrap: wrap; gap: .2rem 1rem; }
.pagination { display: flex; flex-wrap: wrap; gap: .35rem; margin-top: 1rem; align-items: center; }
.pagination a, .pagination span { padding: .2rem .55rem; border: 1px solid var(--border); border-radius: var(--radius); }
.pagination [aria-current="page"] { background: var(--accent); color: var(--accent-fg); border-color: var(--accent); }

/* Package detail */
.package-header { margin-bottom: 1rem; }
.package-header .meta { margin-top: .3rem; }
.tabs { display: flex; flex-wrap: wrap; gap: .25rem; border-bottom: 1px solid var(--border); margin: 0 0 1rem; padding: 0; list-style: none; }
.tabs a { display: block; padding: .45rem .8rem; border: 1px solid transparent; border-bottom: 0; border-radius: var(--radius) var(--radius) 0 0; color: var(--muted); }
.tabs a[aria-current="page"] { border-color: var(--border); background: var(--bg); color: var(--fg); font-weight: 600; margin-bottom: -1px; }
.detail { display: grid; grid-template-columns: minmax(0, 1fr) 280px; gap: 2rem; }
.sidebar h3 { font-size: .8rem; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); margin: 1.1rem 0 .35rem; }
.sidebar h3:first-child { margin-top: 0; }
.sidebar ul { list-style: none; margin: 0; padding: 0; }
.sidebar li { overflow-wrap: anywhere; }
.snippet { position: relative; margin: .5rem 0 1.25rem; }
.snippet pre { margin: 0; padding-right: 4.5rem; }
.snippet .copy { position: absolute; top: .4rem; right: .4rem; font-size: .8rem; padding: .1rem .5rem; }
.copy { display: none; }
.js .copy { display: inline-block; }

/* Rendered markdown */
.markdown { overflow-wrap: break-word; }
.markdown img { max-width: 100%; }
.markdown pre, pre {
  background: var(--subtle); border: 1px solid var(--border); border-radius: var(--radius);
  padding: .75rem; overflow-x: auto;
}
.markdown code { background: var(--subtle); padding: .1em .3em; border-radius: 4px; }
.markdown pre code { background: none; padding: 0; }
.markdown blockquote { margin: 0; padding: 0 1rem; color: var(--muted); border-left: 4px solid var(--border); }
.markdown h1, .markdown h2 { border-bottom: 1px solid var(--border); padding-bottom: .3rem; }

/* Tables */
.table-scroll { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid var(--border); padding: .4rem .6rem; text-align: left; vertical-align: top; }
th { background: var(--subtle); font-weight: 600; }
td.actions { white-space: nowrap; }
td code, th code { overflow-wrap: anywhere; }

@media (max-width: 760px) {
  .detail { grid-template-columns: minmax(0, 1fr); }
  .site-header .wrap { gap: .5rem; }
  .site-search { order: 3; flex-basis: 100%; }
  h1 { font-size: 1.35rem; }
}
''';

const _js = r'''
(function () {
  'use strict';
  document.documentElement.classList.add('js');

  document.addEventListener('click', function (event) {
    var button = event.target.closest('button[data-copy]');
    if (!button) return;
    var source = document.getElementById(button.getAttribute('data-copy'));
    if (!source || !navigator.clipboard) return;
    navigator.clipboard.writeText(source.textContent.trim()).then(function () {
      var label = button.textContent;
      button.textContent = 'Copied';
      setTimeout(function () { button.textContent = label; }, 1500);
    });
  });

  document.addEventListener('submit', function (event) {
    var message = event.target.getAttribute('data-confirm');
    if (message && !window.confirm(message)) event.preventDefault();
  });

  var form = document.getElementById('search-form');
  var results = document.getElementById('results');
  if (!form || !results || !window.fetch) return;
  var timer = null;
  var latest = 0;
  function refresh() {
    var params = new URLSearchParams(new FormData(form));
    params.delete('page');
    var url = form.getAttribute('action') + '?' + params.toString();
    params.set('partial', '1');
    var request = ++latest;
    fetch(form.getAttribute('action') + '?' + params.toString(), {
      headers: { 'Accept': 'text/html' },
      credentials: 'same-origin'
    }).then(function (response) {
      if (!response.ok) throw new Error(response.status);
      return response.text();
    }).then(function (html) {
      if (request !== latest) return;
      results.innerHTML = html;
      history.replaceState(null, '', url);
    }).catch(function () {});
  }
  form.addEventListener('input', function () {
    clearTimeout(timer);
    timer = setTimeout(refresh, 250);
  });
})();
''';
