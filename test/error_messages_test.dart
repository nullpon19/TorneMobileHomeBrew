/// User-facing error wording tests (plan 86, plan 85 item 9):
/// the plain messages carry no transport codes, the next-step
/// guidance is offered per failure kind, the diagnostic
/// classification is formatted for the detail section, and
/// the playback error dialog leads with the plain wording
/// with the classification collapsed away.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tmhb/core/core.dart';
import 'package:tmhb/ui/error_messages.dart';
import 'package:tmhb/ui/playback_launcher.dart';
import 'package:tmhb/ui/player_cache_policy.dart';
import 'package:tmhb/ui/player_screen.dart';

void main() {
  group('userMessageForError carries no transport codes', () {
    test('http / webapi / soapFault messages are plain', () {
      expect(
        userMessageForError(NasneError.http(514, 'webapi:/x')),
        'nasne からエラーが返りました。',
      );
      expect(
        userMessageForError(NasneError.webapi(1234, 'webapi:/x')),
        'nasne がエラーを返しました。',
      );
      expect(
        userMessageForError(
          NasneError.soapFault(errorCode: '500', source: 'soap:X'),
        ),
        '操作に失敗しました。',
      );
    });

    test('a protected-title refusal (877) names the protection', () {
      expect(
        userMessageForError(
          NasneError.soapFault(errorCode: '877', source: 'soap:X_DeleteTitle'),
        ),
        'このタイトルは保護されているため削除できません。',
      );
    });
  });

  group('errorNextStepForError', () {
    test('unreachable points at power and the same network', () {
      final step = errorNextStepForError(NasneError.unreachable('webapi:/x'));
      expect(step, isNotNull);
      expect(step, contains('同じ Wi-Fi'));
      expect(step, contains('もう一度お試しください'));
    });

    test('device-side failures suggest waiting and retrying', () {
      for (final error in [
        NasneError.http(500, 'webapi:/x'),
        NasneError.webapi(1, 'webapi:/x'),
        NasneError.soapFault(errorCode: '500', source: 'soap:X'),
      ]) {
        expect(errorNextStepForError(error), contains('しばらく待ってから'));
      }
    });

    test('parse failure suggests an app restart when stuck', () {
      expect(
        errorNextStepForError(NasneError.parse('webapi:/x')),
        contains('アプリを再起動'),
      );
    });

    test('nothing is added where no action helps', () {
      expect(errorNextStepForError(NasneError.validation('ui', '詳細')), isNull);
      expect(errorNextStepForError(NasneError.unsupported('ui')), isNull);
      expect(errorNextStepForError(Exception('x')), isNull);
    });
  });

  group('errorDetailText', () {
    test('formats category, source, code and detail', () {
      expect(
        errorDetailText(NasneError.http(514, 'webapi:/x')),
        '分類: http / 発生元: webapi:/x / コード: 514\n詳細: HTTP 514',
      );
    });

    test('omits the parts an error does not have', () {
      expect(
        errorDetailText(NasneError.unsupported('dtcp:start')),
        '分類: unsupported / 発生元: dtcp:start',
      );
    });
  });

  group('showPlaybackErrorDialog', () {
    testWidgets('leads with the plain wording; detail is collapsed', (
      tester,
    ) async {
      final error = NasneError.http(514, 'webapi:/x');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPlaybackErrorDialog(context, error),
                child: const Text('開く'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();

      // The plain explanation and the next step lead.
      expect(find.text('再生を開始できませんでした'), findsOneWidget);
      expect(find.text('nasne からエラーが返りました。'), findsOneWidget);
      expect(find.textContaining('しばらく待ってから'), findsOneWidget);
      // The classification is not in the viewer's face.
      expect(find.textContaining('分類: http'), findsNothing);

      // It is one tap away, under 詳細.
      await tester.tap(find.text('詳細'));
      await tester.pumpAndSettle();
      expect(find.textContaining('分類: http'), findsOneWidget);
      expect(find.textContaining('コード: 514'), findsOneWidget);
    });

    testWidgets('shows 再試行 button and resolves true when canRetry is true', (
      tester,
    ) async {
      final error = NasneError.unreachable('dtcp:http');
      bool? lastResult;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  lastResult = await showPlaybackErrorDialog(
                    context,
                    error,
                    canRetry: true,
                  );
                },
                child: const Text('開く'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();

      expect(find.text('再試行'), findsOneWidget);
      await tester.tap(find.text('再試行'));
      await tester.pumpAndSettle();
      expect(lastResult, isTrue);
    });
  });

  group('Field-test buffer & throughput helpers', () {
    test('computeResumeWatchdogTimeout scales safely above rebuffer wait', () {
      expect(
        computeResumeWatchdogTimeout(live: true, rebufferWaitSeconds: 0),
        const Duration(seconds: 45),
      );
      expect(
        computeResumeWatchdogTimeout(live: true, rebufferWaitSeconds: 15),
        const Duration(seconds: 45),
      );
      expect(
        computeResumeWatchdogTimeout(live: true, rebufferWaitSeconds: 30),
        const Duration(seconds: 60),
      );
    });

    test('computeSlidingThroughputMbps and formatThroughputMbps measure Mbps accurately', () {
      final t0 = DateTime.utc(2026, 11, 27, 6, 0, 0);
      expect(computeSlidingThroughputMbps([(at: t0, bytes: 1000)]), isNull);
      expect(
        computeSlidingThroughputMbps([
          (at: t0, bytes: 0),
          (at: t0.add(const Duration(milliseconds: 500)), bytes: 500000),
        ]),
        isNull,
      );
      // 1,500,000 bytes over 4.0 seconds = 3.0 Mbps
      final mbps = computeSlidingThroughputMbps([
        (at: t0, bytes: 100000),
        (at: t0.add(const Duration(seconds: 4)), bytes: 1600000),
      ]);
      expect(mbps, closeTo(3.0, 0.001));
      expect(formatThroughputMbps(mbps), '受信 3.0 Mbps');
      expect(formatThroughputMbps(null), isNull);
      expect(formatThroughputMbps(double.nan), isNull);
      expect(formatThroughputMbps(-1.0), isNull);
    });
  });
}
