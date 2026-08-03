import 'package:flutter_test/flutter_test.dart';
import 'package:radio_brong/update_checker.dart';

void main() {
  group('UpdateChecker', () {
    test('detects newer semantic versions', () {
      expect(UpdateChecker.isNewerVersion('1.0.0+1', '1.0.1'), isTrue);
      expect(UpdateChecker.isNewerVersion('1.0.1+1', '1.0.1'), isFalse);
      expect(UpdateChecker.isNewerVersion('1.0.0+1', 'v1.0.0'), isFalse);
    });

    test('normalizes version tags with v prefix', () {
      final parsed = UpdateChecker.parseVersion('v1.2.3');
      expect(parsed.major, 1);
      expect(parsed.minor, 2);
      expect(parsed.patch, 3);
      expect(parsed.build, isNull);
    });
  });
}
