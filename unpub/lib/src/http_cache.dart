/// Whether the value of an `If-None-Match` header selects [etag].
///
/// Uses the weak comparison the header calls for, so a validator that a
/// compressing proxy turned weak still matches.
bool etagMatches(String? ifNoneMatch, String etag) {
  if (ifNoneMatch == null) return false;
  final wanted = _opaqueTag(etag);
  for (final candidate in ifNoneMatch.split(',')) {
    final trimmed = candidate.trim();
    if (trimmed == '*' || _opaqueTag(trimmed) == wanted) return true;
  }
  return false;
}

String _opaqueTag(String tag) => tag.startsWith('W/') ? tag.substring(2) : tag;
