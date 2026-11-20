import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import '../app.dart';
import '../validation.dart';
import 'responses.dart';

/// Redirects to shields.io badges for the latest version and downloads.
class BadgeRoutes {
  final App app;

  BadgeRoutes(this.app);

  void addRoutes(Router router) {
    router.get('/badge/<type>/<name>', badge);
  }

  static String _getBadgeUrl(String label, String message, String color,
      Map<String, String> queryParameters) {
    var badgeUri = Uri.parse('https://img.shields.io/static/v1');
    return Uri(
        scheme: badgeUri.scheme,
        host: badgeUri.host,
        path: badgeUri.path,
        queryParameters: {
          'label': label,
          'message': message,
          'color': color,
          ...queryParameters,
        }).toString();
  }

  Future<shelf.Response> badge(
      shelf.Request req, String type, String name) async {
    if (!isValidPackageName(name)) return notFound();

    var queryParameters = req.requestedUri.queryParameters;
    var package = await app.metaStore.queryPackage(name);
    if (package == null) {
      return shelf.Response.notFound('Not found');
    }

    switch (type) {
      case 'v':
        var latest = semver.Version.parse(package.latest.version);

        var color = latest.major == 0 ? 'orange' : 'blue';

        return shelf.Response.found(
            _getBadgeUrl('unpub', latest.toString(), color, queryParameters));
      case 'd':
        return shelf.Response.found(_getBadgeUrl(
            'downloads', package.download.toString(), 'blue', queryParameters));
      default:
        return shelf.Response.notFound('Not found');
    }
  }
}
