import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

typedef DirectoryProvider = Future<Directory> Function();

class CheckpointStorage {
  CheckpointStorage({DirectoryProvider? directoryProvider})
    : _directoryProvider = directoryProvider ?? _defaultDirectoryProvider;

  final DirectoryProvider _directoryProvider;

  static Future<Directory> _defaultDirectoryProvider() async {
    return getApplicationDocumentsDirectory();
  }

  Future<File> get _checkpointFile async {
    final directory = await _directoryProvider();
    return File('${directory.path}/radio_brong_checkpoint.json');
  }

  Future<void> saveCheckpoint(
    List<CheckpointTrack> tracks,
    int currentIndex,
  ) async {
    if (tracks.isEmpty) {
      await clearCheckpoint();
      return;
    }

    final safeIndex = currentIndex.clamp(0, tracks.length - 1);
    final checkpointTracks = tracks.sublist(safeIndex);
    final file = await _checkpointFile;
    final payload = jsonEncode({
      'currentIndex': 0,
      'tracks': checkpointTracks.map((track) => track.toJson()).toList(),
    });
    await file.writeAsString(payload);
  }

  Future<CheckpointData?> loadCheckpoint() async {
    final file = await _checkpointFile;
    if (!await file.exists()) {
      return null;
    }

    final content = await file.readAsString();
    if (content.trim().isEmpty) {
      return null;
    }

    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    final tracks =
        (decoded['tracks'] as List<dynamic>?)
            ?.map(
              (item) => CheckpointTrack.fromJson(item as Map<String, dynamic>),
            )
            .toList() ??
        <CheckpointTrack>[];

    if (tracks.isEmpty) {
      return null;
    }

    return CheckpointData(
      currentIndex:
          int.tryParse(decoded['currentIndex']?.toString() ?? '0') ?? 0,
      tracks: tracks,
    );
  }

  Future<void> clearCheckpoint() async {
    final file = await _checkpointFile;
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class CheckpointData {
  const CheckpointData({required this.currentIndex, required this.tracks});

  final int currentIndex;
  final List<CheckpointTrack> tracks;
}

class CheckpointTrack {
  const CheckpointTrack({
    required this.participant,
    required this.videoId,
    required this.title,
    this.thumbnailUrl,
    this.durationSeconds,
    this.participantPosition,
    this.totalParticipants,
    this.localPath,
    this.isLocalVideo = false,
  });

  final String participant;
  final String videoId;
  final String title;
  final String? thumbnailUrl;
  final int? durationSeconds;
  final int? participantPosition;
  final int? totalParticipants;
  final String? localPath;
  final bool isLocalVideo;

  factory CheckpointTrack.fromJson(Map<String, dynamic> json) {
    return CheckpointTrack(
      participant: json['participant']?.toString() ?? '',
      videoId: json['videoId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      thumbnailUrl: json['thumbnailUrl']?.toString(),
      durationSeconds: int.tryParse(json['durationSeconds']?.toString() ?? ''),
      participantPosition: int.tryParse(
        json['participantPosition']?.toString() ?? '',
      ),
      totalParticipants: int.tryParse(
        json['totalParticipants']?.toString() ?? '',
      ),
      localPath: json['localPath']?.toString(),
      isLocalVideo: json['isLocalVideo'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'participant': participant,
      'videoId': videoId,
      'title': title,
      'thumbnailUrl': thumbnailUrl,
      'durationSeconds': durationSeconds,
      'participantPosition': participantPosition,
      'totalParticipants': totalParticipants,
      'localPath': localPath,
      'isLocalVideo': isLocalVideo,
    };
  }
}
