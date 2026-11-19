import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_brong/main.dart';

void main() {
  test('participant labels distinguish video order from round', () {
    final firstRoundTrack = TrackItem(
      participant: 'Anna',
      videoId: 'video-1',
      title: 'Video 1',
      participantPosition: 1,
      totalParticipants: 2,
    );
    final multiRoundTrack = TrackItem(
      participant: 'Anna · 1/2 (Giro 1/2)',
      videoId: 'video-2',
      title: 'Video 2',
    );

    expect(firstRoundTrack.participantLabel, 'Anna · 1/2');
    expect(multiRoundTrack.participantLabel, 'Anna · 1/2 (Giro 1/2)');
  });

  testWidgets('participant randomization is enabled by default', (
    tester,
  ) async {
    ParticipantSelectionResult? selection;
    await tester.pumpWidget(
      _ParticipantSelectorHarness(onSelected: (result) => selection = result),
    );

    await tester.tap(find.text('Apri selezione'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Randomizzazione attiva'), findsOneWidget);
    await tester.tap(find.text('Inizia Radio'));
    await tester.pumpAndSettle();

    expect(selection?.participants, ['Anna', 'Bruno', 'Carla']);
    expect(selection?.randomize, isTrue);
    expect(selection?.rounds, 1);
  });

  testWidgets('selected round count is returned', (tester) async {
    ParticipantSelectionResult? selection;
    await tester.pumpWidget(
      _ParticipantSelectorHarness(onSelected: (result) => selection = result),
    );

    await tester.tap(find.text('Apri selezione'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Aumenta giri'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Aumenta giri'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inizia Radio'));
    await tester.pumpAndSettle();

    expect(selection?.rounds, 3);
  });

  testWidgets('round count is capped at ten', (tester) async {
    await tester.pumpWidget(_ParticipantSelectorHarness(onSelected: (_) {}));

    await tester.tap(find.text('Apri selezione'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 12; i++) {
      await tester.tap(find.byTooltip('Aumenta giri'));
      await tester.pumpAndSettle();
    }

    expect(find.text('10/10'), findsOneWidget);
  });

  testWidgets('manual mode returns participants in the reordered sequence', (
    tester,
  ) async {
    ParticipantSelectionResult? selection;
    await tester.pumpWidget(
      _ParticipantSelectorHarness(onSelected: (result) => selection = result),
    );

    await tester.tap(find.text('Apri selezione'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Randomizzazione attiva'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Randomizzazione disattivata'), findsOneWidget);
    await tester.drag(
      find.byIcon(Icons.drag_handle).first,
      const Offset(0, 180),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inizia Radio'));
    await tester.pumpAndSettle();

    expect(selection?.randomize, isFalse);
    expect(selection?.participants.first, 'Bruno');
  });
}

class _ParticipantSelectorHarness extends StatelessWidget {
  final ValueChanged<ParticipantSelectionResult> onSelected;

  const _ParticipantSelectorHarness({required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                final result = await Navigator.of(context)
                    .push<ParticipantSelectionResult>(
                      MaterialPageRoute(
                        builder: (context) => ParticipantSelectorPage(
                          initialList: const ['Anna', 'Bruno', 'Carla'],
                          themeData: ThemeData.dark(),
                        ),
                      ),
                    );
                if (result != null) onSelected(result);
              },
              child: const Text('Apri selezione'),
            ),
          ),
        ),
      ),
    );
  }
}
