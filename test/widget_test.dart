/// App shell smoke test: with no registrations the app boots into
/// the v1 shell, shows the registration prompt on the home tab, and
/// carries the display title "torne HB FireTV".
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tmhb/main.dart';

void main() {
  testWidgets('shell boots with title and registration prompt', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ProviderScope(child: TmhbApp()));
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, 'torne HB FireTV');
    expect(find.text('torne HB FireTV'), findsWidgets);
    expect(find.text('nasne が登録されていません'), findsOneWidget);
    expect(find.text('設定で登録する'), findsOneWidget);

    // The four v1 destinations exist.
    expect(find.text('ホーム'), findsOneWidget);
    expect(find.text('予約'), findsOneWidget);
    expect(find.text('録画済み'), findsOneWidget);
    expect(find.text('設定'), findsOneWidget);
  });
}
