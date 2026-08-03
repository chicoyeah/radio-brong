import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_brong/checkpoint_storage.dart';

void main() {
  test('save and load checkpoint from the current video onward', () async {
    final tempDir = await Directory.systemTemp.createTemp('checkpoint_test');
    final storage = CheckpointStorage(directoryProvider: () async => tempDir);

    final tracks = [
      CheckpointTrack(participant: 'A', videoId: '1', title: 'One'),
      CheckpointTrack(participant: 'B', videoId: '2', title: 'Two'),
      CheckpointTrack(participant: 'C', videoId: '3', title: 'Three'),
    ];

    await storage.saveCheckpoint(tracks, 1);
    final loaded = await storage.loadCheckpoint();

    expect(loaded, isNotNull);
    expect(loaded!.tracks.map((track) => track.videoId).toList(), ['2', '3']);
    expect(loaded.currentIndex, 0);

    await tempDir.delete(recursive: true);
  });

  test('clear removes the stored checkpoint', () async {
    final tempDir = await Directory.systemTemp.createTemp('checkpoint_test_clear');
    final storage = CheckpointStorage(directoryProvider: () async => tempDir);

    await storage.saveCheckpoint([
      CheckpointTrack(participant: 'A', videoId: '1', title: 'One'),
    ], 0);
    await storage.clearCheckpoint();

    final loaded = await storage.loadCheckpoint();

    expect(loaded, isNull);

    await tempDir.delete(recursive: true);
  });
}
