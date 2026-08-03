import 'dart:convert';

List<String> extractVideoIdsFromPlaylistHtml(String html) {
  final ids = <String>{};

  final videoIdPattern = RegExp(r'"videoId":"([A-Za-z0-9_-]{11})"');
  for (final match in videoIdPattern.allMatches(html)) {
    ids.add(match.group(1)!);
  }

  final watchPattern = RegExp(r'/watch\?v=([A-Za-z0-9_-]{11})');
  for (final match in watchPattern.allMatches(html)) {
    ids.add(match.group(1)!);
  }

  return ids.toList();
}

String? extractPlaylistIdFromUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;

  final listId = uri.queryParameters['list'];
  if (listId != null && listId.isNotEmpty) {
    return listId;
  }

  if (uri.pathSegments.length >= 2 && uri.pathSegments[0] == 'playlist') {
    return uri.pathSegments[1];
  }

  return null;
}
