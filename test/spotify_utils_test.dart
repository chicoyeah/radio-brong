import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:radio_brong/spotify_utils.dart';

void main() {
  test('extracts Spotify track URLs including localized paths', () {
    expect(
      extractSpotifyTrackUrl('https://open.spotify.com/track/abc123?si=share'),
      'https://open.spotify.com/track/abc123?si=share',
    );
    expect(
      extractSpotifyTrackUrl(
        'https://open.spotify.com/intl-it/track/abc123?si=share#test',
      ),
      'https://open.spotify.com/intl-it/track/abc123?si=share',
    );
    expect(
      extractSpotifyTrackUrl('https://spotify.link/shortCode'),
      'https://spotify.link/shortCode',
    );
  });

  test('rejects Spotify pages that are not tracks and unrelated hosts', () {
    expect(
      extractSpotifyTrackUrl('https://open.spotify.com/album/abc123'),
      isNull,
    );
    expect(extractSpotifyTrackUrl('https://open.spotify.com/track/'), isNull);
    expect(
      extractSpotifyTrackUrl('https://open.spotify.com.example/track/abc123'),
      isNull,
    );
    expect(extractSpotifyTrackUrl('https://example.com/track/abc123'), isNull);
  });

  test(
    'loads the title from oEmbed and artist from track page metadata',
    () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'open.spotify.com');
        if (request.url.path == '/oembed') {
          expect(
            request.url.queryParameters['url'],
            'https://open.spotify.com/track/08dz3ygXyFur6bL7Au8u8J',
          );
          return http.Response(jsonEncode({'title': 'Over'}), 200);
        }
        expect(request.url.path, '/track/08dz3ygXyFur6bL7Au8u8J');
        return http.Response(
          '<meta property="og:description" '
          'content="Playboi Carti · Whole Lotta Red · Song · 2020">',
          200,
        );
      });

      final track = await loadSpotifyTrack(
        'https://open.spotify.com/track/08dz3ygXyFur6bL7Au8u8J',
        client: client,
      );

      expect(track.title, 'Over');
      expect(track.artist, 'Playboi Carti');
      expect(track.searchQuery, 'Over Playboi Carti');
      client.close();
    },
  );

  test(
    'falls back to the Spotify title when page metadata has no artist',
    () async {
      final client = MockClient((request) async {
        if (request.url.path == '/oembed') {
          return http.Response(jsonEncode({'title': 'Over'}), 200);
        }
        return http.Response('<html><head></head></html>', 200);
      });

      final track = await loadSpotifyTrack(
        'https://open.spotify.com/track/abc123',
        client: client,
      );

      expect(track.artist, isEmpty);
      expect(track.searchQuery, 'Over');
      client.close();
    },
  );

  test('resolves spotify.link before requesting track metadata', () async {
    var oEmbedRequested = false;
    final client = MockClient((request) async {
      if (request.url.host == 'spotify.link') {
        expect(request.followRedirects, isFalse);
        return http.Response(
          '',
          302,
          headers: {
            'location': 'https://open.spotify.com/track/abc123?si=share',
          },
        );
      }

      oEmbedRequested = true;
      expect(
        request.url.queryParameters['url'],
        'https://open.spotify.com/track/abc123?si=share',
      );
      return http.Response(
        jsonEncode({'title': 'Song Name', 'author_name': 'Artist Name'}),
        200,
      );
    });

    final track = await loadSpotifyTrack(
      'https://spotify.link/shortCode',
      client: client,
    );

    expect(track.url, 'https://open.spotify.com/track/abc123?si=share');
    expect(oEmbedRequested, isTrue);
    client.close();
  });
}
