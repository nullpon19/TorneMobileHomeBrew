/// Credential import flow wording (plan 86.2, plan 85 item 2):
/// the surface carries no internal values (byte counts, SHA-1,
/// device ID hex, env variable names), failures read as plain
/// sentences, and the playback guidance dialog leads straight
/// to the import screen.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tmhb/app/providers.dart';
import 'package:tmhb/core/core.dart';
import 'package:tmhb/ui/dtcp_credential_screen.dart';
import 'package:tmhb/ui/playback_launcher.dart';
import 'package:tmhb/ui/widgets.dart';

import 'dtcp_kat.dart';

InMemoryCredentialStore _store() =>
    InMemoryCredentialStore(authorityKeys: [hexToBytes(katAuthPub)]);

Future<InMemoryCredentialStore> _importedStore() async {
  final store = _store();
  await store.save(
    certificate: hexToBytes(katSinkCert),
    privateKey: hexToBytes(katSinkPriv),
  );
  return store;
}

Widget _app(CredentialStore store, Widget home) {
  return ProviderScope(
    overrides: [credentialStoreProvider.overrideWithValue(store)],
    child: MaterialApp(home: home),
  );
}

void main() {
  group('DtcpCredentialScreen wording', () {
    testWidgets('not imported: guidance without internal values',
        (tester) async {
      await tester.pumpWidget(_app(_store(), const DtcpCredentialScreen()));
      await tester.pumpAndSettle();

      expect(find.text('未インポート'), findsOneWidget);
      expect(find.text('用意のしかた'), findsOneWidget);
      // None of the internal facts the plan 85 audit listed.
      expect(find.textContaining('88 バイト'), findsNothing);
      expect(find.textContaining('20 バイト'), findsNothing);
      expect(find.textContaining('SHA-1'), findsNothing);
      expect(find.textContaining('PYDTCPIP_'), findsNothing);
      expect(find.textContaining('デバイス ID'), findsNothing);
    });

    testWidgets('imported: presence only, no identifiers', (tester) async {
      final store = await _importedStore();
      await tester.pumpWidget(_app(store, const DtcpCredentialScreen()));
      await tester.pumpAndSettle();

      expect(find.text('インポート済み'), findsOneWidget);
      // The KAT device ID (4328719365 = 0x0102030405) never shows.
      expect(find.textContaining('0102030405'), findsNothing);
      expect(find.textContaining('デバイス ID'), findsNothing);
    });

    Future<void> enterPair(WidgetTester tester, String cert, String key) async {
      final fields = find.byType(FireTvTextInputField);
      await tester.tap(fields.first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), cert);
      await tester.tap(find.text('決定'));
      await tester.pumpAndSettle();

      await tester.tap(fields.last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), key);
      await tester.tap(find.text('決定'));
      await tester.pumpAndSettle();
    }

    testWidgets('unreadable paste reports plainly', (tester) async {
      // A tall viewport so the whole form is built without
      // scrolling (the lazy list otherwise leaves the save
      // button unbuilt).
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(_store(), const DtcpCredentialScreen()));
      await tester.pumpAndSettle();

      await enterPair(tester, 'zzz', 'zzz');
      await tester.tap(find.text('検証して保存'));
      await tester.pumpAndSettle();

      expect(find.textContaining('読み取れませんでした'), findsOneWidget);
      expect(find.textContaining('NasneError'), findsNothing);
    });

    testWidgets('a non-pair reports as a pair problem', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(_store(), const DtcpCredentialScreen()));
      await tester.pumpAndSettle();

      await enterPair(tester, '00', '00');
      await tester.tap(find.text('検証して保存'));
      await tester.pumpAndSettle();

      expect(find.textContaining('ペアとして確認できませんでした'), findsOneWidget);
      expect(find.textContaining('NasneError'), findsNothing);
    });
  });

  group('showCredentialGuidanceDialog', () {
    testWidgets('the import action opens the credential screen',
        (tester) async {
      await tester.pumpWidget(
        _app(
          _store(),
          Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showCredentialGuidanceDialog(context, '案内文'),
              child: const Text('開く'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();

      expect(find.text('資格情報が必要です'), findsOneWidget);
      await tester.tap(find.text('インポートする'));
      await tester.pumpAndSettle();

      // The credential screen itself is now on top.
      expect(find.byType(DtcpCredentialScreen), findsOneWidget);
      expect(find.text('用意のしかた'), findsOneWidget);
    });
  });
}
