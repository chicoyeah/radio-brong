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
}
