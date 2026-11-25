/// App bootstrap (phase 2): builds the provider container whose
/// local stores are backed by JSON files, so registrations and
/// caches survive app restarts. [main] resolves the store
/// directory (app/store_directory.dart: documents on mobile,
/// application support on desktop) and hands it here; tests pass
/// a temporary directory instead.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core.dart';
import 'providers.dart';

/// File and directory names used inside the store directory.
const registrationFileName = 'registrations.json';
const keyValueFileName = 'key_values.json';
const channelCacheFileName = 'channel_cache.json';
const channelLogoCacheFileName = 'channel_logo_cache.json';
const epgCacheFileName = 'epg_cache.json';
const srmFileName = 'dtcp_srm.json';
const debugLogsDirectoryName = 'debug_logs';

/// A [ProviderContainer] with the local stores wired to JSON
/// files inside [storeDirectory], instead of the in-memory
/// defaults.
///
/// Near-fixed data (the settings and the device selection in
/// [keyValueFileName]) and always-rewritten data (the channel
/// cache and the programme-guide cache) live in separate files,
/// and the DTCP SRM has a file of its own, so writers of
/// different volatility never share a file (plan 96). Existing
/// installs are migrated by [migrateLegacyKeyValueFiles], which
/// [main] runs before building this container.
ProviderContainer fileStoreContainer(
  Directory storeDirectory, {
  Directory? mpvCacheDirectory,
  int? androidSdkInt,
}) {
  File file(String name) => File('${storeDirectory.path}/$name');
  return ProviderContainer(
    overrides: [
      registrationStoreProvider.overrideWithValue(
        JsonFileRegistrationStore(file(registrationFileName)),
      ),
      keyValueStoreProvider.overrideWithValue(
        JsonFileKeyValueStore(file(keyValueFileName)),
      ),
      channelCacheStoreProvider.overrideWithValue(
        JsonFileKeyValueStore(file(channelCacheFileName)),
      ),
      channelLogoCacheStoreProvider.overrideWithValue(
        JsonFileKeyValueStore(file(channelLogoCacheFileName)),
      ),
      epgGuideCacheStoreProvider.overrideWithValue(
        JsonFileKeyValueStore(file(epgCacheFileName)),
      ),
      srmKeyValueStoreProvider.overrideWithValue(
        JsonFileKeyValueStore(file(srmFileName)),
      ),
      storeDirectoryProvider.overrideWithValue(storeDirectory),
      if (mpvCacheDirectory != null)
        mpvCacheDirectoryProvider.overrideWithValue(mpvCacheDirectory),
      if (androidSdkInt != null)
        androidSdkIntProvider.overrideWithValue(androidSdkInt),
    ],
  );
}

/// One-time split of the legacy shared key-value file (plan 96).
///
/// Before the split, every key lived in [keyValueFileName]: the
/// settings and the device selection next to the channel cache,
/// the (very large) programme-guide cache and the DTCP SRM, all
/// rewritten through one unguarded read-modify-write — the race
/// that made the device selection intermittently revert to the
/// first registration.
///
/// Each cache / SRM key is copied to its new file, read back and
/// verified there, and only then removed from the legacy file.
/// A key whose copy or verification fails stays in the legacy
/// file — the legacy data remains authoritative, nothing is
/// lost, and the next launch retries it. Settings keys never
/// move. Safe to run on every launch: once migrated, no legacy
/// cache keys remain and this is a no-op.
Future<void> migrateLegacyKeyValueFiles(Directory storeDirectory) async {
  File file(String name) => File('${storeDirectory.path}/$name');
  final legacy = JsonFileKeyValueStore(file(keyValueFileName));
  final entries = await legacy.readAll();
  if (entries.isEmpty) return;
  await _moveKeys(
    legacy,
    entries,
    JsonFileKeyValueStore(file(channelCacheFileName)),
    (key) => key.startsWith(ChannelCache.keyPrefix),
  );
  await _moveKeys(
    legacy,
    entries,
    JsonFileKeyValueStore(file(epgCacheFileName)),
    (key) => key.startsWith(EpgGuideCache.keyPrefix),
  );
  await _moveKeys(
    legacy,
    entries,
    JsonFileKeyValueStore(file(srmFileName)),
    (key) => key == KeyValueSrmStore.storageKey,
  );
}

/// Moves every [entries] key matching [match] from [legacy] to
/// [target]: copy, read back from [target], and delete from
/// [legacy] only when the read-back matches. A failure leaves
/// the key in [legacy] and never propagates — a failed migration
/// must not stop the app from starting with its existing data.
Future<void> _moveKeys(
  JsonFileKeyValueStore legacy,
  Map<String, String> entries,
  JsonFileKeyValueStore target,
  bool Function(String key) match,
) async {
  for (final entry in entries.entries) {
    if (!match(entry.key)) continue;
    try {
      await target.write(entry.key, entry.value);
      if (await target.read(entry.key) == entry.value) {
        await legacy.delete(entry.key);
      }
    } catch (_) {
      // The legacy file keeps the key; retried on the next launch.
    }
  }
}
