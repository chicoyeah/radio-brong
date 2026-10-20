import 'package:flutter_test/flutter_test.dart';
import 'package:radio_brong/youtube_playlist_utils.dart';

void main() {
  test('extracts video ids from playlist HTML', () {
    const html = """
    <script>var ytInitialData = {"contents":{"twoColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[{"playlistVideoRenderer":{"videoId":"abc12345678"}},{"playlistVideoRenderer":{"videoId":"xyz98765432"}}]}}]}}}]}}};</script>
    <a href="/watch?v=abc12345678">First</a>
    <a href="/watch?v=xyz98765432">Second</a>
    """;

    final ids = extractVideoIdsFromPlaylistHtml(html);

    expect(ids, containsAll(<String>['abc12345678', 'xyz98765432']));
  });

  test('extracts video ids from YouTube video URLs', () {
    expect(
      extractYoutubeVideoIdFromUrl(
        'https://www.youtube.com/watch?v=abc12345678&list=PL123',
      ),
      'abc12345678',
    );
    expect(
      extractYoutubeVideoIdFromUrl('https://youtu.be/xyz98765432?t=30'),
      'xyz98765432',
    );
    expect(
      extractYoutubeVideoIdFromUrl('https://m.youtube.com/shorts/abc12345678'),
      'abc12345678',
    );
  });

  test('does not treat non-video or invalid URLs as video links', () {
    expect(
      extractYoutubeVideoIdFromUrl(
        'https://www.youtube.com/playlist?list=PL123',
      ),
      isNull,
    );
    expect(
      extractYoutubeVideoIdFromUrl('https://example.com/watch?v=abc12345678'),
      isNull,
    );
    expect(extractYoutubeVideoIdFromUrl('https://youtu.be/invalid'), isNull);
  });
}
