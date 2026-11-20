final _connectionString =
    RegExp(r'mongodb(\+srv)?://\S+', caseSensitive: false);

/// [uri] without its credentials and query, which can hold secrets as well.
///
/// Everything before the last `@` is removed, so a password containing `/`,
/// `?` or an unencoded `@` cannot survive.
String redactUri(String uri) {
  final schemeEnd = uri.indexOf('://');
  final scheme = schemeEnd < 0 ? '' : uri.substring(0, schemeEnd + 3);
  var rest = schemeEnd < 0 ? uri : uri.substring(schemeEnd + 3);
  final at = rest.lastIndexOf('@');
  if (at >= 0) rest = '***@${rest.substring(at + 1)}';
  final query = rest.indexOf('?');
  if (query >= 0) rest = '${rest.substring(0, query)}?***';
  return '$scheme$rest';
}

/// Applies [redactUri] to every connection string inside [text].
///
/// Drivers quote the connection string in their errors, and `FormatException`
/// repeats its whole source, so any such text must pass through this before
/// it reaches a log, a response or another exception.
String redactConnectionStrings(String text) => text.replaceAllMapped(
    _connectionString, (match) => redactUri(match.group(0)!));

/// An error whose original message held a connection string.
class RedactedException implements Exception {
  final String message;

  const RedactedException(this.message);

  @override
  String toString() => message;
}
