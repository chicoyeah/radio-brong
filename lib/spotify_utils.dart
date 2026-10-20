import 'dart:convert';

import 'package:http/http.dart' as http;

class SpotifyTrack {
  const SpotifyTrack({
    required this.url,
    required this.title,
    required this.artist,
  });

  final String url;
  final String title;
  final String artist;

  String get searchQuery => '$title $artist'.trim();
}

String? extractSpotifyTrackUrl(String input) {
  final trimmedInput = input.trim();
  if (trimmedInput.isEmpty) return null;

  final normalizedInput = trimmedInput.contains('://')
      ? trimmedInput
      : 'https://$trimmedInput';
  final uri = Uri.tryParse(normalizedInput);
  if (uri == null ||
      uri.userInfo.isNotEmpty ||
      !const {'http', 'https'}.contains(uri.scheme.toLowerCase())) {
    return null;
  }

  final host = uri.host.toLowerCase();
  final isShortLink = host == 'spotify.link';
  if (host != 'open.spotify.com' &&
      host != 'www.open.spotify.com' &&
      !isShortLink) {
    return null;
  }

  final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
  final pathSegments = segments.toList();
  if (pathSegments.isEmpty) return null;

  if (isShortLink) {
    return uri.removeFragment().replace(scheme: 'https').toString();
  }

  final trackIndex = pathSegments.indexOf('track');
  if (trackIndex == -1 ||
      trackIndex + 1 >= pathSegments.length ||
      pathSegments[trackIndex + 1].isEmpty) {
    return null;
  }

  return uri
      .removeFragment()
      .replace(scheme: 'https', host: 'open.spotify.com')
      .toString();
}

Future<SpotifyTrack> loadSpotifyTrack(
  String input, {
  http.Client? client,
}) async {
  final extractedUrl = extractSpotifyTrackUrl(input);
  if (extractedUrl == null) {
    throw const FormatException('URL Spotify non valido.');
  }

  final ownsClient = client == null;
  final requestClient = client ?? http.Client();
  try {
    final trackUrl = await _resolveSpotifyTrackUrl(extractedUrl, requestClient);
    final response = await requestClient
        .get(
          Uri.https('open.spotify.com', '/oembed', {'url': trackUrl}),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw FormatException(
        'Spotify non ha restituito i dettagli della traccia '
        '(HTTP ${response.statusCode}).',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Risposta Spotify non valida.');
    }
    final title = decoded['title'];
    if (title is! String || title.trim().isEmpty) {
      throw const FormatException(
        'Spotify non ha fornito il titolo della traccia.',
      );
    }
    final oEmbedArtist = decoded['author_name'];
    var artist = oEmbedArtist is String ? oEmbedArtist.trim() : '';

    if (artist.isEmpty) {
      final trackPageResponse = await requestClient
          .get(
            Uri.parse(trackUrl),
            headers: const {
              'Accept': 'text/html',
              'User-Agent': 'Mozilla/5.0 (compatible; RadioBrong/1.0)',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (trackPageResponse.statusCode == 200) {
        artist = _spotifyArtistFromPage(trackPageResponse.body);
      }
    }

    return SpotifyTrack(url: trackUrl, title: title.trim(), artist: artist);
  } finally {
    if (ownsClient) requestClient.close();
  }
}

String _spotifyArtistFromPage(String html) {
  for (final tag in RegExp(
    r'<meta\b[^>]*>',
    caseSensitive: false,
  ).allMatches(html)) {
    final tagContent = tag.group(0)!;
    final property = _htmlAttribute(tagContent, 'property');
    if (property?.toLowerCase() != 'og:description') continue;

    final description = _decodeHtmlEntities(
      _htmlAttribute(tagContent, 'content') ?? '',
    );
    final separatorIndex = description.indexOf(' · ');
    if (separatorIndex > 0) {
      return description.substring(0, separatorIndex).trim();
    }
  }
  return '';
}

String? _htmlAttribute(String tag, String name) {
  final match = RegExp(
    r'''\b''' +
        RegExp.escape(name) +
        r'''\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
    caseSensitive: false,
  ).firstMatch(tag);
  return match?.group(1) ?? match?.group(2) ?? match?.group(3);
}

String _decodeHtmlEntities(String value) {
  return value
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}

Future<String> _resolveSpotifyTrackUrl(
  String initialUrl,
  http.Client client,
) async {
  var uri = Uri.parse(initialUrl);
  if (uri.host != 'spotify.link') return initialUrl;

  for (var redirectCount = 0; redirectCount <= 5; redirectCount++) {
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers['User-Agent'] = 'Mozilla/5.0 (compatible; RadioBrong/1.0)'
      ..headers['Accept'] = 'text/html';
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 15));

    if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
      await response.stream.drain<void>();
      throw FormatException(
        'Impossibile risolvere il link Spotify (HTTP ${response.statusCode}).',
      );
    }

    final location = response.headers['location'];
    await response.stream.drain<void>();
    if (location == null) {
      throw const FormatException(
        'Il link breve Spotify non contiene un reindirizzamento valido.',
      );
    }

    final nextUrl = extractSpotifyTrackUrl(uri.resolve(location).toString());
    if (nextUrl == null) {
      throw const FormatException(
        'Il link Spotify non porta a una traccia valida.',
      );
    }
    uri = Uri.parse(nextUrl);
    if (uri.host != 'spotify.link') return nextUrl;
    if (redirectCount == 5) {
      throw const FormatException(
        'Il link Spotify ha troppi reindirizzamenti.',
      );
    }
  }

  throw const FormatException('Impossibile risolvere il link Spotify.');
}
