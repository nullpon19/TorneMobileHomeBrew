/// torne mobile HomeBrew edition — app entry point.
///
/// Before the first frame, the local stores are backed by JSON files
/// in the app store directory so registrations and caches
/// survive restarts (app/store_directory.dart, app/bootstrap.dart).
/// The UI is the v1 screen set
/// of plan 5.6, built on the phase 1 core through the composition
/// root (app/providers.dart) and app state (app/state.dart).
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
// Flutter 3.50 deprecates package:flutter/material.dart in favour of
// package:material_ui/material_ui.dart (the scaffold's own import).
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'app/bootstrap.dart';
import 'app/firetv_preset.dart';
import 'ui/widgets.dart';
import 'app/lifecycle_log.dart';
import 'app/providers.dart';
import 'app/store_directory.dart';
import 'ui/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final storeDirectory = await resolveStoreDirectory();
  // Split the legacy shared key-value file into per-purpose
  // files before anything reads the stores (plan 96).
  await migrateLegacyKeyValueFiles(storeDirectory);
  final tempDir = await getTemporaryDirectory();
  final mpvCacheDir = Directory('${tempDir.path}/mpv_cache');
  try {
    if (await mpvCacheDir.exists()) {
      await mpvCacheDir.delete(recursive: true);
    }
    await mpvCacheDir.create(recursive: true);
  } catch (_) {
    // Non-fatal: mpv falls back to RAM cache if cache directory creation fails.
  }
  final container = fileStoreContainer(
    storeDirectory,
    mpvCacheDirectory: mpvCacheDir,
  );
  await applyFireTvPresetsIfNeeded(
    keyValues: container.read(keyValueStoreProvider),
    credentialStore: container.read(credentialStoreProvider),
    registrationStore: container.read(registrationStoreProvider),
    preset: container.read(fireTvPresetProvider),
    diag: container.read(diagLogProvider),
  );
  // App lifecycle transitions go to the debug log (plan 36), so a
  // field log shows when the process was suspended and resumed
  // around a playback session (the wakelock sleep investigation).
  // The binding holds the observer for the app's lifetime.
  LifecycleLogger(container.read(diagLogProvider)).attach();
  runApp(
    UncontrolledProviderScope(container: container, child: const TmhbApp()),
  );
}

class TmhbApp extends StatelessWidget {
  const TmhbApp({super.key});

  static ThemeData _buildTheme() {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.indigo);
    const focusBorder = BorderSide(color: Colors.amber, width: 3);
    return ThemeData(
      colorScheme: scheme,
      focusColor: Colors.amber.withValues(alpha: 0.28),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? focusBorder
                : BorderSide.none,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? focusBorder
                : BorderSide(color: scheme.outline),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? focusBorder
                : BorderSide.none,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? focusBorder
                : BorderSide.none,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'torne HB FireTV',
      // Force Japanese locale so Fire OS fonts.xml picks NotoSansCJK JP
      // (index 0) instead of zh-Hans (index 2).
      locale: const Locale('ja', 'JP'),
      supportedLocales: const [Locale('ja', 'JP')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      // A tap outside a text field dismisses the keyboard
      // anywhere in the app (plan 54).
      builder: (context, child) => DefaultTextStyle.merge(
        style: const TextStyle(locale: Locale('ja', 'JP')),
        child: KeyboardDismissOnTap(child: child ?? const SizedBox.shrink()),
      ),
      theme: _buildTheme(),
      home: const AppShell(),
    );
  }
}
