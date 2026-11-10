import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:mime/mime.dart' as mime;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

import '../http_cache.dart';
import 'html.dart' show escapeHtml;
import 'web_ui.dart' show contentSecurityPolicy, securityHeaders;

/// The policy of the shell of the single-page client: the one of the pages,
/// and fonts from this server, which the client bundles.
const spaContentSecurityPolicy = "$contentSecurityPolicy; font-src 'self'";

/// The first path segments that belong to the server, never to the client
/// served at `/`.
const _serverPrefixes = {
  'api',
  'webapi',
  'badge',
  'static',
  'healthz',
  'readyz',
  'metrics',
  'classic',
};

/// The content types of the files a Vite build produces, where `mime`
/// answers something else or nothing.
const _contentTypes = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
  '.map': 'application/json',
  '.webmanifest': 'application/manifest+json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.ttf': 'font/ttf',
  '.txt': 'text/plain; charset=utf-8',
  '.wasm': 'application/wasm',
};

/// What a request for the client asks for.
sealed class SpaTarget {
  const SpaTarget();
}

/// A file of the build, at [path].
final class SpaFile extends SpaTarget {
  final String path;

  /// Whether it is under `assets/`, where Vite puts files named by a hash of
  /// their content.
  final bool hashed;

  const SpaFile(this.path, {required this.hashed});
}

/// `index.html`, for any route of the client.
final class SpaShell extends SpaTarget {
  const SpaShell();
}

/// Serves the built single-page client from [directory] under [basePath].
///
/// Requests for files of the build get them, `assets/` cached for good and
/// the rest for an hour. Every other GET or HEAD that accepts HTML and is
/// not for the server gets `index.html`, the shell, so that the client can
/// route it. The shell gets the meta tags `unpub-base`, with [basePath], and
/// `unpub-classic`, with [classicPath], and its relative references to the
/// build are made absolute under [basePath], so one build serves under any
/// base path.
class SpaClient {
  /// The directory of the build, absolute and with links resolved.
  final String directory;

  /// Where the client is served, `''` for `/`, otherwise such as `/app`.
  final String basePath;

  /// Where the server-rendered pages are, `''` for `/`.
  final String classicPath;

  final _etags = <String, (DateTime, int, String)>{};
  (DateTime, String)? _shell;

  SpaClient(String directory, {this.basePath = '', this.classicPath = ''})
      : directory = Directory(directory).resolveSymbolicLinksSync() {
    if (!File(p.join(this.directory, 'index.html')).existsSync()) {
      throw ArgumentError.value(directory, 'directory', 'has no index.html');
    }
  }

  /// The path of [request] under [basePath], or null if it is outside.
  String? _relativePath(shelf.Request request) {
    final path = request.url.path;
    if (basePath.isEmpty) return path;
    final prefix = basePath.substring(1);
    if (path == prefix) return '';
    if (path.startsWith('$prefix/')) return path.substring(prefix.length + 1);
    return null;
  }

  /// Whether [path], relative to `/`, is one the server answers itself.
  bool _isServerPath(String path) {
    final first = path.split('/').first;
    if (_serverPrefixes.contains(first)) return true;
    // Archives, and the version lists of the old web UI.
    return path.endsWith('.tar.gz') ||
        (first == 'packages' && path.endsWith('.json'));
  }

  /// What [request] asks of the client, or null if it is not for it.
  ///
  /// Only reads the file system, so the auth middleware can ask too.
  SpaTarget? resolve(shelf.Request request) {
    if (request.method != 'GET' && request.method != 'HEAD') return null;
    final relative = _relativePath(request);
    if (relative == null) return null;
    if (basePath.isEmpty && _isServerPath(relative)) return null;

    final segments = <String>[];
    for (final raw in relative.split('/')) {
      final String segment;
      try {
        segment = Uri.decodeComponent(raw);
      } on ArgumentError {
        return null;
      }
      // Nothing that could leave the directory or name a hidden file.
      if (segment.startsWith('.') ||
          segment.contains('/') ||
          segment.contains(r'\') ||
          segment.contains('\x00')) {
        return null;
      }
      segments.add(segment);
    }
    while (segments.isNotEmpty && segments.last.isEmpty) {
      segments.removeLast();
    }
    if (segments.any((segment) => segment.isEmpty)) return null;

    if (segments.isNotEmpty &&
        !(segments.length == 1 && segments.single == 'index.html')) {
      final file = _file(segments);
      if (file != null) {
        return SpaFile(file, hashed: segments.first == 'assets');
      }
      // A missing file of the build is a 404, not the shell.
      if (segments.first == 'assets') return null;
    }
    final accept = request.headers[HttpHeaders.acceptHeader] ?? '';
    return accept.contains('text/html') ? const SpaShell() : null;
  }

  /// The file at [segments] if it is a file inside [directory].
  String? _file(List<String> segments) {
    final candidate = p.joinAll([directory, ...segments]);
    if (!p.isWithin(directory, candidate)) return null;
    if (FileSystemEntity.typeSync(candidate) != FileSystemEntityType.file) {
      return null;
    }
    final resolved = File(candidate).resolveSymbolicLinksSync();
    return p.isWithin(directory, resolved) ? resolved : null;
  }

  /// The answer to [request], or null if it is not for the client.
  Future<shelf.Response?> handle(shelf.Request request) async {
    final target = resolve(request);
    final response = switch (target) {
      null => null,
      SpaShell() => await _shellResponse(),
      SpaFile() => await _fileResponse(request, target),
    };
    if (response == null || request.method != 'HEAD') return response;
    return response.change(body: const <int>[]);
  }

  Future<shelf.Response> _shellResponse() async {
    return shelf.Response.ok(await shellMarkup(), headers: {
      HttpHeaders.contentTypeHeader: 'text/html; charset=utf-8',
      HttpHeaders.cacheControlHeader: 'no-store',
      HttpHeaders.varyHeader: 'Accept',
      ...securityHeaders,
      'content-security-policy': spaContentSecurityPolicy,
    });
  }

  /// `index.html` as it is served, read again when it changes.
  Future<String> shellMarkup() async {
    final file = File(p.join(directory, 'index.html'));
    final modified = await file.lastModified();
    final cached = _shell;
    if (cached != null && cached.$1 == modified) return cached.$2;
    final entries = {
      await for (final entity in Directory(directory).list())
        p.basename(entity.path),
    }..remove('index.html');
    final markup = shellFor(await file.readAsString(),
        basePath: basePath, classicPath: classicPath, buildEntries: entries);
    _shell = (modified, markup);
    return markup;
  }

  Future<shelf.Response> _fileResponse(
      shelf.Request request, SpaFile target) async {
    final file = File(target.path);
    final stat = await file.stat();
    final etag = await _etag(file, stat);
    final headers = {
      HttpHeaders.contentTypeHeader: contentTypeOf(target.path),
      HttpHeaders.cacheControlHeader: target.hashed
          ? 'public, max-age=31536000, immutable'
          : 'public, max-age=3600',
      HttpHeaders.etagHeader: etag,
      'x-content-type-options': 'nosniff',
      'content-security-policy': spaContentSecurityPolicy,
    };
    if (etagMatches(request.headers[HttpHeaders.ifNoneMatchHeader], etag)) {
      return shelf.Response.notModified(headers: headers);
    }
    return shelf.Response.ok(file.openRead(), headers: {
      ...headers,
      HttpHeaders.contentLengthHeader: '${stat.size}',
    });
  }

  Future<String> _etag(File file, FileStat stat) async {
    final cached = _etags[file.path];
    if (cached != null &&
        cached.$1 == stat.modified &&
        cached.$2 == stat.size) {
      return cached.$3;
    }
    final digest = sha256.convert(await file.readAsBytes()).toString();
    final etag = '"${digest.substring(0, 32)}"';
    _etags[file.path] = (stat.modified, stat.size, etag);
    return etag;
  }
}

/// The content type of the file at [path].
String contentTypeOf(String path) =>
    _contentTypes[p.extension(path).toLowerCase()] ??
    mime.lookupMimeType(path) ??
    'application/octet-stream';

final _head = RegExp(r'<head(\s[^>]*)?>', caseSensitive: false);
final _reference = RegExp(r'''(\s(?:src|href)=["'])(\./|/(?!/))([^/"'?#]*)''',
    caseSensitive: false);

/// [index], the `index.html` of a build, as served under [basePath]: with the
/// meta tags telling the client where it and the server-rendered pages are,
/// and with the references to the build, `./x`, or `/x` for an `x` in
/// [buildEntries], made `<basePath>/x`.
String shellFor(String index,
    {required String basePath,
    required String classicPath,
    Set<String> buildEntries = const {'assets'}}) {
  final rebased = index.replaceAllMapped(_reference, (match) {
    final relative = match[2] == './';
    if (!relative && !buildEntries.contains(match[3])) return match[0]!;
    return '${match[1]}$basePath/${match[3]}';
  });
  final meta = '\n<meta name="unpub-base" content="${escapeHtml(basePath)}">'
      '\n<meta name="unpub-classic" content="${escapeHtml(classicPath)}">';
  final head = _head.firstMatch(rebased);
  if (head == null) return '$meta\n$rebased';
  return rebased.replaceRange(head.end, head.end, meta);
}
