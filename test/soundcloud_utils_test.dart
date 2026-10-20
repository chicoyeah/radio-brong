import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_brong/soundcloud_utils.dart';

void main() {
  test('extracts and normalizes SoundCloud track links', () {
    expect(
      extractSoundCloudTrackUrl(
        'http://www.soundcloud.com/artist/track?si=share#comments',
      ),
      'https://soundcloud.com/artist/track?si=share',
    );
    expect(
      extractSoundCloudTrackUrl('soundcloud.com/artist/track'),
      'https://soundcloud.com/artist/track',
    );
    expect(
      extractSoundCloudTrackUrl('https://soundcloud.com/artist/track/'),
      'https://soundcloud.com/artist/track/',
    );
    expect(
      extractSoundCloudTrackUrl('https://on.soundcloud.com/8GsuW3IPZV3CIWprON'),
      'https://on.soundcloud.com/8GsuW3IPZV3CIWprON',
    );
  });

  test('rejects non-track SoundCloud URLs and unrelated hosts', () {
    expect(
      extractSoundCloudTrackUrl('https://soundcloud.com/artist/sets/mix'),
      isNull,
    );
    expect(extractSoundCloudTrackUrl('https://soundcloud.com/artist'), isNull);
    expect(extractSoundCloudTrackUrl('https://on.soundcloud.com/'), isNull);
    expect(
      extractSoundCloudTrackUrl('https://soundcloud.com.example/artist/track'),
      isNull,
    );
    expect(
      extractSoundCloudTrackUrl('https://example.com/artist/track'),
      isNull,
    );
  });

  test('creates a SoundCloud embed URL with the track URL encoded', () {
    final embedUri = soundCloudEmbedUri(
      'https://soundcloud.com/artist/track?si=share',
    );

    expect(embedUri.host, 'w.soundcloud.com');
    expect(embedUri.path, '/player/');
    expect(
      embedUri.queryParameters['url'],
      contains('soundcloud.com/artist/track'),
    );
    expect(embedUri.queryParameters['auto_play'], 'true');
  });

  test('resolves SoundCloud short links to the canonical track URL', () async {
    final client = MockClient((request) async {
      expect(request.followRedirects, isFalse);
      expect(request.url.host, 'on.soundcloud.com');
      return http.Response(
        '',
        302,
        headers: {
          'location':
              'https://soundcloud.com/p3sto/giorno-1-di-bonesmashing?si=share',
        },
      );
    });

    final resolvedUrl = await resolveSoundCloudTrackUrl(
      'https://on.soundcloud.com/8GsuW3IPZV3CIWprON',
      client: client,
    );

    expect(
      resolvedUrl,
      'https://soundcloud.com/p3sto/giorno-1-di-bonesmashing?si=share',
    );
    client.close();
  });

  test('rejects short links that do not resolve to a track', () async {
    final client = MockClient((request) async => http.Response('', 404));

    await expectLater(
      resolveSoundCloudTrackUrl(
        'https://on.soundcloud.com/8GsuW3IPZV3CIWprON',
        client: client,
      ),
      throwsFormatException,
    );
    client.close();
  });
}
