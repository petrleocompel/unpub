import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import '../static/index.html.dart' as index_html;
import '../static/main.dart.js.dart' as main_dart_js;

/// The compiled AngularDart UI.
class LegacyUiRoutes {
  void addRoutes(Router router) {
    router
      ..get('/', indexHtml)
      ..get('/packages', indexHtml)
      ..get('/packages/<name>', (shelf.Request req, String _) => indexHtml(req))
      ..get('/packages/<name>/versions/<version>',
          (shelf.Request req, String _, String __) => indexHtml(req))
      ..get('/main.dart.js', mainDartJs);
  }

  Future<shelf.Response> indexHtml(shelf.Request req) async {
    return shelf.Response.ok(index_html.content,
        headers: {HttpHeaders.contentTypeHeader: ContentType.html.mimeType});
  }

  Future<shelf.Response> mainDartJs(shelf.Request req) async {
    return shelf.Response.ok(main_dart_js.content,
        headers: {HttpHeaders.contentTypeHeader: 'text/javascript'});
  }
}
