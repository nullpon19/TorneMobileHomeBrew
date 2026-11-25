/// Composition root (plan 12.2 / 12.7): Riverpod providers that wire
/// the domain interfaces to their transport implementations. UI and
/// tests depend on the interfaces only; swapping an implementation
/// (e.g. a mock in tests, or a future transport for a newly
/// discovered path) is an override here, never a UI change.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/core.dart';
import '../ui/player_cache_policy.dart';
import '../ui/subtitle_style_policy.dart';
import 'ake_socket.dart';
import 'debug_log.dart';
import 'file_pick.dart';
import 'firetv_helper.dart';
import 'log_folder.dart';
import 'log_share.dart';
import 'multicast_lock.dart';
import 'wakelock.dart';

final httpClientProvider = Provider<http.Client>((ref) => http.Client());

/// Sleep suppression for the player screen (plan 32, reworked in
/// plan 35): a hand-rolled platform channel flips the OS switch
/// and reads it back, so the debug log shows whether the setting
/// actually stuck.
final wakelockGuardProvider = Provider<WakelockGuard>(
  (ref) => NativeWakelockGuard(),
);

/// The single app-wide wakelock coordinator (plan 35): player
/// screens open sessions on it, and the OS lock is held while
/// any session is playing — one screen ending can no longer drop
/// the lock from under another that is still playing (the
/// build-13 field log showed exactly that).
final playbackWakelockProvider = Provider<PlaybackWakelock>(
  (ref) => PlaybackWakelock(
    guard: ref.watch(wakelockGuardProvider),
    diag: ref.watch(diagLogProvider),
  ),
);

/// Discovery chain (plan 16.3): SSDP first; when it finds nothing
/// (multicast-restricted environments such as iOS sideloading), the
/// unicast subnet scan runs. Manual registration stays available in
/// the settings screen regardless. On Android the SSDP step holds a
/// WifiManager.MulticastLock while searching (plan 17).
final discoveryServiceProvider = Provider<DiscoveryService>(
  (ref) => CompositeDiscoveryService([
    SsdpDiscoveryService(
      client: ref.watch(httpClientProvider),
      lockGuard: MethodChannelMulticastLockGuard(),
    ),
    SubnetScanDiscoveryService(client: ref.watch(httpClientProvider)),
  ]),
);

final registrationServiceProvider = Provider<RegistrationService>(
  (ref) => WebApiRegistrationService(client: ref.watch(httpClientProvider)),
);

/// Defaults to in-memory; the app entry point overrides this with a
/// file-backed store in the documents directory (app/bootstrap.dart).
final registrationStoreProvider = Provider<RegistrationStore>(
  (ref) => InMemoryRegistrationStore(),
);

final keyValueStoreProvider = Provider<KeyValueStore>(
  (ref) => InMemoryKeyValueStore(),
);

/// The key-value store behind the channel cache. Caches live in
/// their own files, away from the settings file: they are
/// rewritten on every fetch while settings are near-fixed, and
/// the standing rule is that writers of different volatility
/// never share a file (plan 96). Defaults to in-memory; the app
/// entry point overrides it (app/bootstrap.dart).
final channelCacheStoreProvider = Provider<KeyValueStore>(
  (ref) => InMemoryKeyValueStore(),
);

final channelCacheProvider = Provider<ChannelCache>(
  (ref) => ChannelCache(ref.watch(channelCacheStoreProvider)),
);

/// Key-value store backing [channelLogoCacheProvider] in its own JSON file.
final channelLogoCacheStoreProvider = Provider<KeyValueStore>(
  (ref) => InMemoryKeyValueStore(),
);

final channelLogoCacheProvider = Provider<ChannelLogoCache>(
  (ref) => ChannelLogoCache(ref.watch(channelLogoCacheStoreProvider)),
);

/// The key-value store behind the programme-guide accumulation
/// cache — its own file again (plan 96). The guide is by far the
/// largest value in the app and is rewritten on every guide
/// fetch, so it shares a file with nothing else.
final epgGuideCacheStoreProvider = Provider<KeyValueStore>(
  (ref) => InMemoryKeyValueStore(),
);

/// The DTCP-IP credential vault (Phase 5, plan 26.4). The pair
/// itself is read only by the playback engine; the UI uses the
/// summary provider below.
final credentialStoreProvider = Provider<CredentialStore>(
  (ref) => SecureCredentialStore(),
);

/// The key-value store behind [srmStoreProvider]. The SRM is
/// DTCP protocol state (a revocation list) rewritten during AKE,
/// so it lives in its own file, away from both the settings file
/// and the caches (plan 96). Defaults to in-memory; the app
/// entry point overrides it (app/bootstrap.dart).
final srmKeyValueStoreProvider = Provider<KeyValueStore>(
  (ref) => InMemoryKeyValueStore(),
);

/// SRM persistence: signed public data in its own key-value
/// store (plan 26.4; split out in plan 96).
final srmStoreProvider = Provider<KeyValueSrmStore>(
  (ref) => KeyValueSrmStore(ref.watch(srmKeyValueStoreProvider)),
);

/// Non-sensitive facts about the imported pair for the settings UI
/// (presence, device ID, certificate fingerprint). Invalidated
/// after import / delete.
final credentialSummaryProvider = FutureProvider<CredentialSummary?>((
  ref,
) async {
  final credentials = await ref.watch(credentialStoreProvider).load();
  return credentials == null ? null : CredentialSummary.of(credentials);
});

/// Whether the programme guide shows subchannels (plan 25;
/// default off), persisted in the key-value store.
class ShowSubchannelsNotifier extends Notifier<bool> {
  static const _key = 'epg_show_subchannels';

  @override
  bool build() {
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final value = await store.read(_key);
      if (value != null && value == 'true' && !state) state = true;
    });
    return false;
  }

  Future<void> set(bool value) async {
    state = value;
    await ref.read(keyValueStoreProvider).write(_key, value ? 'true' : 'false');
  }
}

final showSubchannelsProvider = NotifierProvider<ShowSubchannelsNotifier, bool>(
  ShowSubchannelsNotifier.new,
);

/// Programme-guide genres the viewer does not watch
/// (Discord request, 2026-11-21): events of these genres
/// paint blank in the guide grid, so the guide only draws
/// the eye to programmes of genres the viewer cares about.
/// Persisted in the key-value store as the comma-separated
/// ARIB level-1 values.
class HiddenEpgGenresNotifier extends Notifier<Set<int>> {
  static const _key = 'epg_hidden_genres';

  @override
  Set<int> build() {
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final restored = decode(await store.read(_key));
      if (restored.isNotEmpty && state.isEmpty) state = restored;
    });
    return const {};
  }

  /// The stored form: comma-separated level-1 values.
  /// Anything unparsable is dropped, never fatal.
  static Set<int> decode(String? raw) {
    final values = <int>{};
    for (final part in (raw ?? '').split(',')) {
      final value = int.tryParse(part.trim());
      if (value != null) values.add(value);
    }
    return values;
  }

  Future<void> setHidden(int genreLevel1, bool hidden) async {
    final next = {...state};
    if (hidden) {
      next.add(genreLevel1);
    } else {
      next.remove(genreLevel1);
    }
    state = next;
    final sorted = next.toList()..sort();
    await ref.read(keyValueStoreProvider).write(_key, sorted.join(','));
  }
}

final hiddenEpgGenresProvider =
    NotifierProvider<HiddenEpgGenresNotifier, Set<int>>(
      HiddenEpgGenresNotifier.new,
    );

/// Default playback quality preference: `false` = original quality (`元画質`),
/// `true` = mobile transcode (`モバイル`). Per-title / per-channel choices on
/// the detail screens override only that playback session without mutating
/// this default.
class PlaybackQualityNotifier extends Notifier<bool> {
  static const _key = 'firetv_default_use_mobile';
  bool _dirty = false;

  @override
  bool build() {
    _dirty = false;
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final value = await store.read(_key);
      if (_dirty) return;
      if (value == 'true' && !state) {
        state = true;
      } else if (value == 'false' && state) {
        state = false;
      }
    });
    return false;
  }

  Future<void> set(bool useMobile) async {
    _dirty = true;
    state = useMobile;
    await ref.read(keyValueStoreProvider).write(_key, '$useMobile');
  }
}

final playbackQualityProvider = NotifierProvider<PlaybackQualityNotifier, bool>(
  PlaybackQualityNotifier.new,
);

/// The app store directory (file stores and the debug log
/// destination, plan 28; location rule in plan 47).
/// The bootstrap overrides this with the real directory; null in
/// tests / headless contexts (debug logging then stays off).
final storeDirectoryProvider = Provider<Directory?>((ref) => null);

/// Directory reserved for mpv `cache-on-disk` temporary files on Fire TV.
final mpvCacheDirectoryProvider = Provider<Directory?>((ref) => null);

/// Persisted recorded playback buffer target in seconds (default 5 min).
class RecordedBufferSecondsNotifier extends Notifier<int> {
  static const _key = 'firetv_recorded_buffer_seconds';

  @override
  int build() {
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final raw = await store.read(_key);
      final parsed = raw == null ? null : int.tryParse(raw);
      if (parsed != null &&
          recordedBufferOptionsSeconds.contains(parsed) &&
          parsed != state) {
        state = parsed;
      }
    });
    return defaultRecordedBufferSeconds;
  }

  Future<void> set(int seconds) async {
    if (!recordedBufferOptionsSeconds.contains(seconds)) return;
    state = seconds;
    await ref.read(keyValueStoreProvider).write(_key, '$seconds');
  }
}

final recordedBufferSecondsProvider =
    NotifierProvider<RecordedBufferSecondsNotifier, int>(
      RecordedBufferSecondsNotifier.new,
    );

/// Persisted live playback initial buffer target in seconds (default 0 = off).
class LiveBufferSecondsNotifier extends Notifier<int> {
  static const _key = 'firetv_live_buffer_seconds';

  @override
  int build() {
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final raw = await store.read(_key);
      final parsed = raw == null ? null : int.tryParse(raw);
      if (parsed != null &&
          liveBufferOptionsSeconds.contains(parsed) &&
          parsed != state) {
        state = parsed;
      }
    });
    return defaultLiveBufferSeconds;
  }

  Future<void> set(int seconds) async {
    if (!liveBufferOptionsSeconds.contains(seconds)) return;
    state = seconds;
    await ref.read(keyValueStoreProvider).write(_key, '$seconds');
  }
}

final liveBufferSecondsProvider =
    NotifierProvider<LiveBufferSecondsNotifier, int>(
      LiveBufferSecondsNotifier.new,
    );

/// Persisted video hardware/software decoding mode (default auto).
class VideoHwdecModeNotifier extends Notifier<VideoHwdecMode> {
  static const _key = 'firetv_video_hwdec_mode';
  bool _dirty = false;

  @override
  VideoHwdecMode build() {
    _dirty = false;
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final raw = await store.read(_key);
      if (_dirty || raw == null) return;
      for (final mode in VideoHwdecMode.values) {
        if (mode.name == raw && state != mode) {
          state = mode;
          return;
        }
      }
    });
    return VideoHwdecMode.auto;
  }

  Future<void> set(VideoHwdecMode mode) async {
    _dirty = true;
    state = mode;
    await ref.read(keyValueStoreProvider).write(_key, mode.name);
  }
}

final videoHwdecModeProvider =
    NotifierProvider<VideoHwdecModeNotifier, VideoHwdecMode>(
      VideoHwdecModeNotifier.new,
    );

/// Persisted night mode preference (dark theme toggle, default off = light).
class NightModeNotifier extends Notifier<bool> {
  static const _key = 'firetv_night_mode';
  bool _dirty = false;

  @override
  bool build() {
    _dirty = false;
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final raw = await store.read(_key);
      if (_dirty) return;
      if (raw == 'true' && !state) {
        state = true;
      } else if (raw == 'false' && state) {
        state = false;
      }
    });
    return false;
  }

  Future<void> set(bool enabled) async {
    _dirty = true;
    state = enabled;
    await ref.read(keyValueStoreProvider).write(_key, '$enabled');
  }
}

final nightModeProvider = NotifierProvider<NightModeNotifier, bool>(
  NightModeNotifier.new,
);

/// Persisted preference for automatic series folder grouping in Recorded Titles
/// (default on).
class GroupTitlesNotifier extends Notifier<bool> {
  static const _key = 'firetv_group_titles';
  bool _dirty = false;

  @override
  bool build() {
    _dirty = false;
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final raw = await store.read(_key);
      if (_dirty) return;
      if (raw == 'true' && !state) {
        state = true;
      } else if (raw == 'false' && state) {
        state = false;
      }
    });
    return true;
  }

  Future<void> set(bool enabled) async {
    _dirty = true;
    state = enabled;
    await ref.read(keyValueStoreProvider).write(_key, '$enabled');
  }
}

final groupTitlesProvider = NotifierProvider<GroupTitlesNotifier, bool>(
  GroupTitlesNotifier.new,
);

/// Visual style for scheduled/reserved programme tiles in the EPG grid.
enum EpgReservedStyle { fill, border }

/// Persisted EPG reserved-programme highlight style (default solid red fill).
class EpgReservedStyleNotifier extends Notifier<EpgReservedStyle> {
  static const _key = 'firetv_epg_reserved_style';
  bool _dirty = false;

  @override
  EpgReservedStyle build() {
    _dirty = false;
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final raw = await store.read(_key);
      if (_dirty) return;
      if (raw == EpgReservedStyle.border.name &&
          state != EpgReservedStyle.border) {
        state = EpgReservedStyle.border;
      } else if (raw == EpgReservedStyle.fill.name &&
          state != EpgReservedStyle.fill) {
        state = EpgReservedStyle.fill;
      }
    });
    return EpgReservedStyle.fill;
  }

  Future<void> set(EpgReservedStyle style) async {
    _dirty = true;
    state = style;
    await ref.read(keyValueStoreProvider).write(_key, style.name);
  }
}

final epgReservedStyleProvider =
    NotifierProvider<EpgReservedStyleNotifier, EpgReservedStyle>(
      EpgReservedStyleNotifier.new,
    );

/// Supported default recording quality modes (`desiredQualityMode` in XSRS).
const int recordingQualityDr = 100;
const int recordingQualityX3 = 230;
const List<int> recordingQualityOptions = [
  recordingQualityDr,
  recordingQualityX3,
];

/// Persisted default recording quality mode for new schedules and immediate
/// live recordings (default `DR` = `100`).
class DefaultRecordingQualityNotifier extends Notifier<int> {
  static const _key = 'firetv_default_recording_quality';
  bool _dirty = false;

  @override
  int build() {
    _dirty = false;
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final raw = await store.read(_key);
      if (_dirty) return;
      final parsed = raw == null ? null : int.tryParse(raw);
      if (parsed != null &&
          recordingQualityOptions.contains(parsed) &&
          parsed != state) {
        state = parsed;
      }
    });
    return recordingQualityDr;
  }

  Future<void> set(int qualityMode) async {
    if (!recordingQualityOptions.contains(qualityMode)) return;
    _dirty = true;
    state = qualityMode;
    await ref.read(keyValueStoreProvider).write(_key, '$qualityMode');
  }
}

final defaultRecordingQualityProvider =
    NotifierProvider<DefaultRecordingQualityNotifier, int>(
      DefaultRecordingQualityNotifier.new,
    );

/// Persisted set of composite `recNgList` entry keys dismissed in the app UI
/// (individual delete / clear-all). Nasne `recNgListGet` is read-only.
class DismissedRecNgKeysNotifier extends Notifier<Set<String>> {
  static const _key = 'firetv_dismissed_rec_ng_keys';
  bool _dirty = false;

  @override
  Set<String> build() {
    _dirty = false;
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final raw = await store.read(_key);
      if (!ref.mounted || _dirty || raw == null || raw.isEmpty) return;
      final restored = _decode(raw);
      if (restored.isNotEmpty) {
        state = {...state, ...restored};
      }
    });
    return const {};
  }

  static Set<String> _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const {};
      return {
        for (final entry in decoded)
          if (entry is String && entry.isNotEmpty) entry,
      };
    } catch (_) {
      return const {};
    }
  }

  Future<void> _save(Set<String> next) async {
    final sorted = next.toList()..sort();
    await ref.read(keyValueStoreProvider).write(_key, jsonEncode(sorted));
  }

  Future<void> dismiss(String key) async {
    if (key.isEmpty || state.contains(key)) return;
    _dirty = true;
    final next = {...state, key};
    state = next;
    await _save(next);
  }

  Future<void> dismissAll(Iterable<String> keys) async {
    final next = {...state};
    var changed = false;
    for (final k in keys) {
      if (k.isNotEmpty && next.add(k)) changed = true;
    }
    if (!changed) return;
    _dirty = true;
    state = next;
    await _save(next);
  }
}

final dismissedRecNgKeysProvider =
    NotifierProvider<DismissedRecNgKeysNotifier, Set<String>>(
      DismissedRecNgKeysNotifier.new,
    );

/// Persisted subtitle visual customization settings (font, size, edge, and
/// background color/opacity).
class SubtitleSettingsNotifier extends Notifier<SubtitleSettings> {
  static const _key = 'firetv_subtitle_settings';
  bool _dirty = false;

  @override
  SubtitleSettings build() {
    _dirty = false;
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final raw = await store.read(_key);
      if (!ref.mounted || _dirty || raw == null || raw.isEmpty) return;
      final restored = SubtitleSettings.fromJsonString(raw);
      if (restored != state) {
        state = restored;
      }
    });
    return SubtitleSettings.defaults;
  }

  Future<void> _update(SubtitleSettings next) async {
    if (next == state) return;
    _dirty = true;
    state = next;
    await ref.read(keyValueStoreProvider).write(_key, next.toJsonString());
  }

  Future<void> setSize(SubtitleSizePreset size) =>
      _update(state.copyWith(size: size));

  Future<void> setFont(SubtitleFontFamily font) =>
      _update(state.copyWith(font: font));

  Future<void> setEdge(SubtitleEdgeStyle edge) =>
      _update(state.copyWith(edge: edge));

  Future<void> setBackgroundColor(SubtitleBackgroundColorPreset color) =>
      _update(state.copyWith(backgroundColor: color));

  Future<void> setBackgroundOpacity(int opacityPercent) {
    if (!subtitleBackgroundOpacityOptions.contains(opacityPercent)) {
      return Future.value();
    }
    return _update(state.copyWith(backgroundOpacityPercent: opacityPercent));
  }

  Future<void> resetDefaults() async {
    if (state == SubtitleSettings.defaults) return;
    _dirty = true;
    state = SubtitleSettings.defaults;
    await ref.read(keyValueStoreProvider).write(_key, state.toJsonString());
  }
}

final subtitleSettingsProvider =
    NotifierProvider<SubtitleSettingsNotifier, SubtitleSettings>(
      SubtitleSettingsNotifier.new,
    );

/// Persisted subtitle ON/OFF toggle retained across channels, recordings,
/// and app restarts (defaults to OFF).
class SubtitlesEnabledNotifier extends Notifier<bool> {
  static const _key = 'firetv_subtitles_enabled';
  bool _dirty = false;

  @override
  bool build() {
    _dirty = false;
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final raw = await store.read(_key);
      if (!ref.mounted || _dirty || raw == null) return;
      final restored = raw == 'true';
      if (restored != state) {
        state = restored;
      }
    });
    return false;
  }

  Future<void> set(bool enabled) async {
    _dirty = true;
    state = enabled;
    await ref.read(keyValueStoreProvider).write(_key, '$enabled');
  }
}

final subtitlesEnabledProvider =
    NotifierProvider<SubtitlesEnabledNotifier, bool>(
      SubtitlesEnabledNotifier.new,
    );

/// Persisted ARIB superimpose (`0x38`) display toggle (defaults to ON).
class SuperimposeEnabledNotifier extends Notifier<bool> {
  static const _key = 'firetv_superimpose_enabled';
  bool _dirty = false;

  @override
  bool build() {
    _dirty = false;
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final raw = await store.read(_key);
      if (!ref.mounted || _dirty || raw == null) return;
      final restored = raw == 'true';
      if (restored != state) {
        state = restored;
      }
    });
    return true;
  }

  Future<void> set(bool enabled) async {
    _dirty = true;
    state = enabled;
    await ref.read(keyValueStoreProvider).write(_key, '$enabled');
  }
}

final superimposeEnabledProvider =
    NotifierProvider<SuperimposeEnabledNotifier, bool>(
      SuperimposeEnabledNotifier.new,
    );

/// Persisted ARIB superimpose built-in chime sound toggle (defaults to ON).
class SuperimposeSoundEnabledNotifier extends Notifier<bool> {
  static const _key = 'firetv_superimpose_sound_enabled';
  bool _dirty = false;

  @override
  bool build() {
    _dirty = false;
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final raw = await store.read(_key);
      if (!ref.mounted || _dirty || raw == null) return;
      final restored = raw == 'true';
      if (restored != state) {
        state = restored;
      }
    });
    return true;
  }

  Future<void> set(bool enabled) async {
    _dirty = true;
    state = enabled;
    await ref.read(keyValueStoreProvider).write(_key, '$enabled');
  }
}

final superimposeSoundEnabledProvider =
    NotifierProvider<SuperimposeSoundEnabledNotifier, bool>(
      SuperimposeSoundEnabledNotifier.new,
    );

/// Persisted Niconico Jikkyo visual & mapping settings (Phase 40).
class JikkyoSettingsNotifier extends Notifier<JikkyoSettings> {
  static const _key = 'firetv_jikkyo_settings';
  bool _dirty = false;

  @override
  JikkyoSettings build() {
    _dirty = false;
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final raw = await store.read(_key);
      if (!ref.mounted || _dirty || raw == null || raw.isEmpty) return;
      final restored = JikkyoSettings.fromJsonString(raw);
      if (restored != state) {
        state = restored;
      }
    });
    return JikkyoSettings.defaults;
  }

  Future<void> _update(JikkyoSettings next) async {
    if (next == state) return;
    _dirty = true;
    state = next;
    await ref.read(keyValueStoreProvider).write(_key, next.toJsonString());
  }

  Future<void> setOpacity(int opacityPercent) {
    if (!jikkyoOpacityOptions.contains(opacityPercent)) {
      return Future.value();
    }
    return _update(state.copyWith(opacityPercent: opacityPercent));
  }

  Future<void> setTextSize(JikkyoTextSizePreset size) =>
      _update(state.copyWith(textSize: size));

  Future<void> setSpeed(JikkyoSpeedPreset speed) =>
      _update(state.copyWith(speed: speed));

  Future<void> setMaxConcurrent(int count) {
    if (!jikkyoMaxConcurrentOptions.contains(count)) {
      return Future.value();
    }
    return _update(state.copyWith(maxConcurrentComments: count));
  }

  Future<void> setAvoidSubtitleArea(bool avoid) =>
      _update(state.copyWith(avoidSubtitleArea: avoid));

  Future<void> setLiveDelaySeconds(int seconds) {
    if (!jikkyoLiveDelayOptions.contains(seconds)) {
      return Future.value();
    }
    return _update(state.copyWith(liveDelaySeconds: seconds));
  }

  Future<void> setForceWhiteText(bool enabled) =>
      _update(state.copyWith(forceWhiteText: enabled));

  Future<void> setHideFixedComments(bool enabled) =>
      _update(state.copyWith(hideFixedComments: enabled));

  Future<void> addNgWord(String word) =>
      _update(state.withAddedNgWord(word));

  Future<void> removeNgWord(String word) =>
      _update(state.withoutNgWord(word));

  Future<void> clearNgWords() => _update(state.withoutAllNgWords());

  Future<void> setChannelOverride(
    String key,
    String jkIdOrOff, {
    String? label,
  }) =>
      _update(state.withChannelOverride(key, jkIdOrOff, label: label));

  Future<void> removeChannelOverride(String key) =>
      _update(state.withoutChannelOverride(key));

  Future<void> clearChannelOverrides() =>
      _update(state.withoutAllChannelOverrides());

  Future<void> resetDefaults() async {
    if (state == JikkyoSettings.defaults) return;
    _dirty = true;
    state = JikkyoSettings.defaults;
    await ref.read(keyValueStoreProvider).write(_key, state.toJsonString());
  }
}

final jikkyoSettingsProvider =
    NotifierProvider<JikkyoSettingsNotifier, JikkyoSettings>(
      JikkyoSettingsNotifier.new,
    );

/// Persisted Niconico Jikkyo ON/OFF toggle (defaults to OFF).
class JikkyoEnabledNotifier extends Notifier<bool> {
  static const _key = 'firetv_jikkyo_enabled';
  bool _dirty = false;

  @override
  bool build() {
    _dirty = false;
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final raw = await store.read(_key);
      if (!ref.mounted || _dirty || raw == null) return;
      final restored = raw == 'true';
      if (restored != state) {
        state = restored;
      }
    });
    return false;
  }

  Future<void> set(bool enabled) async {
    _dirty = true;
    state = enabled;
    await ref.read(keyValueStoreProvider).write(_key, '$enabled');
  }
}

final jikkyoEnabledProvider = NotifierProvider<JikkyoEnabledNotifier, bool>(
  JikkyoEnabledNotifier.new,
);

final jikkyoClientProvider = Provider<JikkyoClient>((ref) {
  final client = NxJikkyoClient();
  ref.onDispose(client.dispose);
  return client;
});

/// Persisted toggle for auto-playing the next episode inside a recorded series
/// folder (Phase 41, defaults to ON).
class AutoPlayNextEpisodeNotifier extends Notifier<bool> {
  static const _key = 'firetv_auto_play_next_episode';
  bool _dirty = false;

  @override
  bool build() {
    _dirty = false;
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final raw = await store.read(_key);
      if (!ref.mounted || _dirty || raw == null) return;
      final restored = raw == 'true';
      if (restored != state) {
        state = restored;
      }
    });
    return true;
  }

  Future<void> set(bool enabled) async {
    _dirty = true;
    state = enabled;
    await ref.read(keyValueStoreProvider).write(_key, '$enabled');
  }
}

final autoPlayNextEpisodeProvider =
    NotifierProvider<AutoPlayNextEpisodeNotifier, bool>(
      AutoPlayNextEpisodeNotifier.new,
    );

/// Debug mode settings (plan 28): the master switch and the
/// enabled category set, persisted in the key-value store.
class DebugSettingsNotifier extends Notifier<DebugSettings> {
  static const _masterKey = 'debug_mode_enabled';
  static const _categoriesKey = 'debug_categories';

  @override
  DebugSettings build() {
    final store = ref.watch(keyValueStoreProvider);
    Future.microtask(() async {
      final master = await store.read(_masterKey);
      final categories = await store.read(_categoriesKey);
      state = DebugSettings(
        master: master == 'true',
        categories: DebugSettings.decodeCategories(categories),
      );
    });
    return const DebugSettings();
  }

  Future<void> setMaster(bool value) async {
    state = state.copyWith(master: value);
    await ref.read(keyValueStoreProvider).write(_masterKey, '$value');
  }

  Future<void> setCategory(DiagCategory category, bool enabled) async {
    final next = {...state.categories};
    if (enabled) {
      next.add(category);
    } else {
      next.remove(category);
    }
    state = state.copyWith(categories: next);
    await ref
        .read(keyValueStoreProvider)
        .write(_categoriesKey, state.encodeCategories());
  }
}

final debugSettingsProvider =
    NotifierProvider<DebugSettingsNotifier, DebugSettings>(
      DebugSettingsNotifier.new,
    );

/// The app-wide diagnostics logger (plan 28). Reflects the current
/// debug settings on every record: master off, the category off,
/// or no store directory records nothing.
final diagLogProvider = Provider<DiagLog>((ref) {
  final dir = ref.watch(storeDirectoryProvider);
  if (dir == null) return const DiagLog.none();
  final sink = FileDebugLogSink(dir);
  return DiagLog((category, message) => sink.write(category, message), (
    category,
  ) {
    final settings = ref.read(debugSettingsProvider);
    return settings.master && settings.categories.contains(category);
  });
});

/// Shares the recorded debug logs through the OS share sheet
/// (plan 46). Null when there is no store directory (tests /
/// headless contexts) — the settings screen then hides the share
/// action, like the log destination display.
final debugLogSharerProvider = Provider<DebugLogSharer?>((ref) {
  final dir = ref.watch(storeDirectoryProvider);
  if (dir == null) return null;
  return DebugLogSharer(storeDirectory: dir);
});

/// Opens the debug log folder in the desktop file manager
/// (plan 71) — the desktop counterpart of the share action
/// above. Null under the same conditions as
/// [debugLogSharerProvider]; the settings screen shows the
/// folder action on desktop instead of the share action.
final debugLogFolderOpenerProvider = Provider<DebugLogFolderOpener?>((ref) {
  final dir = ref.watch(storeDirectoryProvider);
  if (dir == null) return null;
  return DebugLogFolderOpener(storeDirectory: dir);
});

/// Picks a file's bytes for the credential import (plan 84).
/// Unlike the log actions above this needs no store directory,
/// so it is always available.
final fileBytesPickerProvider = Provider<FileBytesPicker>(
  (ref) => FileBytesPicker(),
);

/// Android `Build.VERSION.SDK_INT` resolved at bootstrap (`null` on non-Android/tests).
final androidSdkIntProvider = Provider<int?>((ref) => null);

/// Platform helper for Fire TV (volume max, Tailscale, local file scan).
final fireTvHelperProvider = Provider<FireTvHelper>((ref) => FireTvHelper());

final playbackEngineProvider = Provider<PlaybackEngine>(
  (ref) => DtcpPlaybackEngine(
    credentialStore: ref.watch(credentialStoreProvider),
    srmStore: ref.watch(srmStoreProvider),
    diag: ref.watch(diagLogProvider),
    autoReconnect: Platform.isAndroid,
    akeConnectionFactory: (host, port) =>
        nativeAkeConnectionFactory(host, port, diag: ref.read(diagLogProvider)),
  ),
);

/// The per-device service bundle, assembled from a registration.
/// Control URLs come from [NasneDevice.direct] (the measured
/// fallback forms, plan 11.6) unless a described device is supplied.
class DeviceServices {
  const DeviceServices({
    required this.deviceInfo,
    required this.settings,
    required this.schedules,
    required this.titles,
    required this.metadata,
    required this.live,
    required this.playback,
  });

  final DeviceInfoService deviceInfo;
  final SettingsService settings;
  final ScheduleService schedules;
  final TitleCatalogService titles;
  final MetadataService metadata;
  final LiveCatalogService live;
  final PlaybackEngine playback;
}

DeviceServices assembleDeviceServices(
  RegisteredNasne reg, {
  NasneDevice? describedDevice,
  http.Client? client,
  KeyValueStore? epgCacheStore,
  KeyValueStore? srmKeyValueStore,
  CredentialStore? credentialStore,
  SrmStore? srmStore,
  DiagLog? diagLog,
  bool? autoReconnect,
}) {
  final device = describedDevice ?? NasneDevice.direct(reg.host);
  final plain = WebApiTransport(reg.host, client: client);
  final authed = WebApiTransport(
    reg.host,
    client: client,
    tokenProvider: reg.tokenProvider,
  );
  final soap = SoapTransport(client: client);
  final xsrs = device.controlUrl(SoapServices.scheduledRecording.serviceType);
  final cds = device.controlUrl(SoapServices.contentDirectory.serviceType);
  // X_PvrControl carries X_GetTitleInfo (chapters, plan
  // 112). Unlike the two services above it is not
  // load-bearing — a description without it simply has
  // no chapters — so it is passed through as nullable.
  final pvr = device.controlUrl(SoapServices.pvrControl.serviceType);
  if (xsrs == null || cds == null) {
    throw NasneError.validation(
      'providers',
      'device exposes no XSRS/ContentDirectory control URL',
    );
  }
  final metadata = CompositeMetadataService(
    dlna: DlnaMetadataService(soap: soap, controlUrl: cds),
    epg: WebApiEpgService(
      plain: plain,
      authed: authed,
      diag: diagLog ?? const DiagLog.none(),
      // Persistent guide accumulation (plan 23), backed by the
      // guide cache's own key-value store when one is wired.
      guideCache: epgCacheStore == null ? null : EpgGuideCache(epgCacheStore),
      cacheHost: reg.host,
    ),
  );
  return DeviceServices(
    deviceInfo: WebApiDeviceInfoService(plain),
    settings: WebApiSettingsService(authed),
    schedules: SoapScheduleService(soap: soap, controlUrl: xsrs),
    titles: SoapTitleCatalogService(
      soap: soap,
      xsrsControlUrl: xsrs,
      webApi: plain,
      metadata: metadata,
      pvrControlUrl: pvr,
    ),
    metadata: metadata,
    live: DlnaLiveCatalogService(metadata: metadata),
    playback: DtcpPlaybackEngine(
      credentialStore: credentialStore ?? SecureCredentialStore(),
      srmStore:
          srmStore ??
          KeyValueSrmStore(srmKeyValueStore ?? InMemoryKeyValueStore()),
      diag: diagLog ?? const DiagLog.none(),
      autoReconnect: autoReconnect ?? Platform.isAndroid,
      akeConnectionFactory: (host, port) => nativeAkeConnectionFactory(
        host,
        port,
        diag: diagLog ?? const DiagLog.none(),
      ),
    ),
  );
}

final deviceServicesProvider = Provider.family<DeviceServices, RegisteredNasne>(
  (ref, reg) => assembleDeviceServices(
    reg,
    client: ref.watch(httpClientProvider),
    epgCacheStore: ref.watch(epgGuideCacheStoreProvider),
    srmKeyValueStore: ref.watch(srmKeyValueStoreProvider),
    credentialStore: ref.watch(credentialStoreProvider),
    srmStore: ref.watch(srmStoreProvider),
    diagLog: ref.watch(diagLogProvider),
  ),
);
