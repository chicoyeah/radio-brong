import 'dart:convert';

import 'package:http/http.dart' as http;

class UpdateInfo {
  const UpdateInfo({required this.version, required this.url, required this.body});

  final String version;
  final String url;
  final String body;
}

class UpdateChecker {
  static const String releasesUrl =
      'https://api.github.com/repos/chicoyeah/radio-brong/releases/latest';

  static bool isNewerVersion(String currentVersion, String? latestVersion) {
    if (latestVersion == null || latestVersion.trim().isEmpty) {
      return false;
    }

    final current = parseVersion(currentVersion);
    final latest = parseVersion(latestVersion);

    if (latest.major != current.major) {
      return latest.major > current.major;
    }
    if (latest.minor != current.minor) {
      return latest.minor > current.minor;
    }
    if (latest.patch != current.patch) {
      return latest.patch > current.patch;
    }
    if (latest.build != null && current.build != null) {
      return latest.build! > current.build!;
    }
    return false;
  }

  static Version parseVersion(String rawVersion) {
    final normalized = rawVersion.trim().replaceFirst(RegExp(r'^v'), '');
    final parts = normalized.split('+').first.split('.');
    final versionNumbers = <int>[];

    for (final part in parts) {
      final parsed = int.tryParse(part);
      if (parsed == null) {
        break;
      }
      versionNumbers.add(parsed);
    }

    while (versionNumbers.length < 3) {
      versionNumbers.add(0);
    }

    final build = normalized.contains('+')
        ? int.tryParse(normalized.split('+').last)
        : null;

    return Version(
      major: versionNumbers[0],
      minor: versionNumbers[1],
      patch: versionNumbers[2],
      build: build,
    );
  }

  static Future<UpdateInfo?> checkForUpdate({required String currentVersion}) async {
    try {
      final response = await http.get(
        Uri.parse(releasesUrl),
        headers: {'Accept': 'application/vnd.github+json'},
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        return null;
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final tagName = body['tag_name'] as String?;
      final htmlUrl = body['html_url'] as String?;
      final releaseBody = body['body'] as String? ?? '';

      if (tagName == null || htmlUrl == null) {
        return null;
      }

      if (!isNewerVersion(currentVersion, tagName)) {
        return null;
      }

      return UpdateInfo(
        version: tagName,
        url: htmlUrl,
        body: releaseBody,
      );
    } catch (_) {
      return null;
    }
  }
}

class Version {
  const Version({
    required this.major,
    required this.minor,
    required this.patch,
    this.build,
  });

  final int major;
  final int minor;
  final int patch;
  final int? build;
}
