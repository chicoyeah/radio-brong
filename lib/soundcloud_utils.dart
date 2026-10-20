import 'package:http/http.dart' as http;

String? extractSoundCloudTrackUrl(String input) {
  final trimmedInput = input.trim();
  if (trimmedInput.isEmpty) return null;

  final normalizedInput = trimmedInput.contains('://')
      ? trimmedInput
      : 'https://$trimmedInput';
  final uri = Uri.tryParse(normalizedInput);
  if (uri == null || uri.userInfo.isNotEmpty) {
    return null;
  }

  final host = uri.host.toLowerCase();
  const soundCloudHosts = {
    'soundcloud.com',
    'www.soundcloud.com',
    'm.soundcloud.com',
  };
  final isShortLink = host == 'on.soundcloud.com';
  if (!const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
      (!soundCloudHosts.contains(host) && !isShortLink)) {
    return null;
  }

  final pathSegments = uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (pathSegments.isEmpty ||
      (!isShortLink &&
          (pathSegments.length < 2 || pathSegments[1].toLowerCase() == 'sets'))) {
    return null;
  }

  final normalizedUri = uri.removeFragment().replace(
    scheme: 'https',
    host: isShortLink ? 'on.soundcloud.com' : 'soundcloud.com',
  );
  return normalizedUri.toString();
}

Future<String> resolveSoundCloudTrackUrl(
  String input, {
  http.Client? client,
}) async {
  final extractedUrl = extractSoundCloudTrackUrl(input);
  if (extractedUrl == null) {
    throw const FormatException('URL SoundCloud non valido.');
  }

  var uri = Uri.parse(extractedUrl);
  if (uri.host != 'on.soundcloud.com') return extractedUrl;

  final ownsClient = client == null;
  final requestClient = client ?? http.Client();
  try {
    for (var redirectCount = 0; redirectCount <= 5; redirectCount++) {
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['User-Agent'] =
            'Mozilla/5.0 (compatible; RadioBrong/1.0)'
        ..headers['Accept'] = 'text/html';
      final response = await requestClient
          .send(request)
          .timeout(const Duration(seconds: 15));

      if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers['location'];
        await response.stream.drain<void>();
        if (location == null) {
          throw const FormatException(
            'Il link breve SoundCloud non contiene un reindirizzamento valido.',
          );
        }

        final nextUrl = extractSoundCloudTrackUrl(
          uri.resolve(location).toString(),
        );
        if (nextUrl == null) {
          throw const FormatException(
            'Il link breve non porta a una traccia SoundCloud valida.',
          );
        }
        uri = Uri.parse(nextUrl);
        if (uri.host != 'on.soundcloud.com') return nextUrl;
        if (redirectCount == 5) {
          throw const FormatException(
            'Il link breve SoundCloud ha troppi reindirizzamenti.',
          );
        }
        continue;
      }

      await response.stream.drain<void>();
      throw FormatException(
        'Impossibile risolvere il link SoundCloud (HTTP ${response.statusCode}).',
      );
    }

    throw const FormatException(
      'Impossibile risolvere il link breve SoundCloud.',
    );
  } finally {
    if (ownsClient) requestClient.close();
  }
}

Uri soundCloudEmbedUri(String trackUrl) {
  return Uri.https('w.soundcloud.com', '/player/', {
    'url': trackUrl,
    'auto_play': 'true',
    'visual': 'true',
    'hide_related': 'true',
    'show_comments': 'false',
  });
}
