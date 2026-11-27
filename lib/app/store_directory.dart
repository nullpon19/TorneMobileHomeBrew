/// Where the app's local files live (plan 47).
///
/// Mobile (iOS / Android) keeps using the application documents
/// directory, as it always has — existing installs must not lose
/// their registrations or settings, so the mobile location does
/// not move.
///
/// Desktop (macOS / Linux / Windows) uses the application support
/// directory instead (macOS: `~/Library/Application Support/…`,
/// Linux: the XDG data directory). Desktop systems give each app a
/// dedicated per-app data area, while the documents directory on
/// macOS is the user's own visible Documents folder — app-internal
/// JSON and log files do not belong there. On the first desktop
/// launch after this change, files left in the documents directory
/// by earlier desktop builds are moved over once; see
/// [migrateLegacyStoreFiles].
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'bootstrap.dart';

/// True on desktop platforms, where the store lives under the
/// application support directory rather than Documents.
bool get isDesktopStorePlatform =>
    Platform.isMacOS || Platform.isLinux || Platform.isWindows;

const String _legacyMigratedMarkerName = '.legacy_migrated';

/// Resolves the directory that backs the file stores and the
/// debug logs, migrating legacy desktop files on first run.
Future<Directory> resolveStoreDirectory() async {
  if (!isDesktopStorePlatform) {
    return getApplicationDocumentsDirectory();
  }
  final support = await getApplicationSupportDirectory();
  await support.create(recursive: true);
  final marker = File('${support.path}/$_legacyMigratedMarkerName');
  final hasExistingData =
      await marker.exists() ||
      await File('${support.path}/$registrationFileName').exists() ||
      await File('${support.path}/$keyValueFileName').exists();
  if (!hasExistingData) {
    try {
      final documents = await getApplicationDocumentsDirectory();
      if (documents.path != support.path) {
        await migrateLegacyStoreFiles(from: documents, to: support);
      }
      await marker.writeAsString('1', flush: true);
    } catch (_) {
      // Legacy migration is best-effort; never block app startup.
    }
  }
  return support;
}

/// One-time move of the store files from the legacy desktop
/// location ([from], the documents directory) to [to] (the
/// application support directory).
///
/// A file is moved only when it exists in [from] and does not yet
/// exist in [to] — a file already at the destination is never
/// overwritten, and its legacy counterpart is left in place, so
/// re-running this (or running it when the new location already
/// has data) cannot destroy anything. The debug-logs directory is
/// merged the same way, file by file, and removed from [from]
/// once empty. Moved files are deleted from [from], so the user's
/// Documents folder is left clean.
Future<void> migrateLegacyStoreFiles({
  required Directory from,
  required Directory to,
}) async {
  await to.create(recursive: true);
  for (final name in const [
    registrationFileName,
    keyValueFileName,
    channelCacheFileName,
    epgCacheFileName,
    srmFileName,
  ]) {
    await _moveIfAbsent(File('${from.path}/$name'), File('${to.path}/$name'));
  }
  final legacyLogs = Directory('${from.path}/$debugLogsDirectoryName');
  if (await legacyLogs.exists()) {
    final newLogs = Directory('${to.path}/$debugLogsDirectoryName');
    await newLogs.create(recursive: true);
    await for (final entity in legacyLogs.list()) {
      if (entity is File) {
        final name = entity.uri.pathSegments.last;
        await _moveIfAbsent(entity, File('${newLogs.path}/$name'));
      }
    }
    if (await legacyLogs.list().isEmpty) {
      await legacyLogs.delete();
    }
  }
}

/// Moves [source] to [target] unless [target] already exists.
Future<void> _moveIfAbsent(File source, File target) async {
  if (!await source.exists() || await target.exists()) return;
  try {
    await source.rename(target.path);
  } on FileSystemException {
    // Cross-device move: copy, then remove the original.
    await source.copy(target.path);
    await source.delete();
  }
}
