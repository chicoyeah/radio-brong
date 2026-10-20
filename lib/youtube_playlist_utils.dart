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

String? extractYoutubeVideoIdFromUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      !uri.hasScheme ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }

  final host = uri.host.toLowerCase();
  String? videoId;
  if (host == 'youtu.be' || host == 'www.youtu.be') {
    if (uri.pathSegments.isNotEmpty) {
      videoId = uri.pathSegments.first;
    }
  } else if (host == 'youtube.com' ||
      host == 'www.youtube.com' ||
      host == 'm.youtube.com' ||
      host == 'www.youtube-nocookie.com') {
    if (uri.path == '/watch') {
      videoId = uri.queryParameters['v'];
    } else if (uri.pathSegments.length >= 2 &&
        const {'shorts', 'live', 'embed'}.contains(uri.pathSegments.first)) {
      videoId = uri.pathSegments[1];
    }
  }

  return videoId != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)
      ? videoId
      : null;
}
