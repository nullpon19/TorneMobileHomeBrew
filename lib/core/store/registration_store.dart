/// Local persistence for registrations, cached channel lists and
/// the accumulated programme-guide events (plan 12.7 / 23:
/// registrations + channel lists persist; schedule and title lists
/// are display caches only, with the device as truth).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../errors.dart';
import '../models/channel.dart';
import '../models/device.dart';
import '../models/epg.dart';
import '../parsing/epg.dart' show normalizeAribLogoPng;

/// Serializes asynchronous operations on one store so that
/// read-modify-write sequences never interleave (plan 96). An
/// operation runs only after every previously queued one has
/// finished; a failure fails its own caller but never poisons
/// the queue.
class _OperationQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}

/// The file a store read should use: [file] itself, or — when a
/// crash interrupted the very first write between the flush and
/// the rename — its temporary sibling, which holds a complete
/// state and is adopted rather than lost (plan 96).
Future<File?> _readableSource(File file) async {
  if (await file.exists()) return file;
  final tmp = File('${file.path}.tmp');
  if (await tmp.exists()) return tmp;
  return null;
}

/// Writes [contents] to [file] atomically: the data lands in a
/// sibling temporary file, flushed to disk, and is then renamed
/// over the target, so neither a reader nor a crash ever observes
/// a half-written file (plan 96).
Future<void> _writeFileAtomically(File file, String contents) async {
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(contents, flush: true);
  await tmp.rename(file.path);
}

/// Moves an undecodable store file aside instead of letting the
/// next write silently destroy its contents (plan 96). These
/// files hold the user's own data — registrations, settings, a
/// DTCP revocation list — and the standing rule is that not one
/// byte is lost without a trace: the corrupt file stays on disk
/// under a `.corrupt` name. Best-effort; a failure here never
/// breaks the store itself.
Future<void> _preserveCorruptFile(File file) async {
  try {
    var target = File('${file.path}.corrupt');
    if (await target.exists()) {
      target = File(
        '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
      );
    }
    await file.rename(target.path);
  } on FileSystemException {
    // Best-effort only.
  }
}

/// Stores the user's registered nasne devices.
abstract interface class RegistrationStore {
  Future<List<RegisteredNasne>> loadAll();

  /// Inserts or replaces the registration for [device]'s host.
  Future<void> save(RegisteredNasne device);

  Future<void> remove(String host);
}

class InMemoryRegistrationStore implements RegistrationStore {
  InMemoryRegistrationStore([Iterable<RegisteredNasne>? initial])
    : _byHost = {
        for (final d in initial ?? const <RegisteredNasne>[]) d.host: d,
      };

  final Map<String, RegisteredNasne> _byHost;

  @override
  Future<List<RegisteredNasne>> loadAll() async =>
      List.unmodifiable(_byHost.values);

  @override
  Future<void> save(RegisteredNasne device) async {
    _byHost[device.host] = device;
  }

  @override
  Future<void> remove(String host) async {
    _byHost.remove(host);
  }
}

/// JSON-file backed store: a list of [RegisteredNasne] JSON objects.
///
/// Every operation is serialized through one queue and each write
/// lands atomically (temporary file + rename), so overlapping
/// saves can no longer drop each other's devices and a reader
/// never observes a half-written file (plan 96).
class JsonFileRegistrationStore implements RegistrationStore {
  JsonFileRegistrationStore(this.file);

  final File file;
  final _OperationQueue _queue = _OperationQueue();

  Future<List<RegisteredNasne>> _readRaw() async {
    final source = await _readableSource(file);
    if (source == null) return [];
    try {
      final decoded = jsonDecode(await source.readAsString());
      if (decoded is! List) {
        await _preserveCorruptFile(source);
        return [];
      }
      return [
        for (final e in decoded)
          if (e is Map) RegisteredNasne.fromJson(e.cast<String, dynamic>()),
      ];
    } on FormatException {
      await _preserveCorruptFile(source);
      return [];
    } on NasneError {
      await _preserveCorruptFile(source);
      return [];
    } on TypeError {
      await _preserveCorruptFile(source);
      return [];
    } on FileSystemException {
      return [];
    }
  }

  Future<void> _writeRaw(List<RegisteredNasne> devices) => _writeFileAtomically(
    file,
    jsonEncode([for (final d in devices) d.toJson()]),
  );

  @override
  Future<List<RegisteredNasne>> loadAll() => _queue.run(_readRaw);

  @override
  Future<void> save(RegisteredNasne device) => _queue.run(() async {
    final devices = await _readRaw();
    devices.removeWhere((d) => d.host == device.host);
    devices.add(device);
    await _writeRaw(devices);
  });

  @override
  Future<void> remove(String host) => _queue.run(() async {
    final devices = await _readRaw();
    devices.removeWhere((d) => d.host == host);
    await _writeRaw(devices);
  });
}

/// Minimal string key-value persistence used for caches.
abstract interface class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class InMemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

/// JSON-file backed key-value store (one JSON object per file).
///
/// Every operation is serialized through one queue and each write
/// lands atomically (temporary file + rename). Before plan 96 the
/// read-modify-write here ran unguarded: overlapping writers —
/// the device selection, the caches, the settings — silently
/// dropped each other's keys, and a read that caught the file
/// mid-write treated it as empty and let the next write wipe
/// every key in it.
class JsonFileKeyValueStore implements KeyValueStore {
  JsonFileKeyValueStore(this.file);

  final File file;
  final _OperationQueue _queue = _OperationQueue();

  Future<Map<String, String>> _readRaw() async {
    final source = await _readableSource(file);
    if (source == null) return {};
    try {
      final raw = await source.readAsString();
      final decoded = raw.length >= 32768
          ? await Isolate.run(() => _decodeKeyValueMap(raw))
          : _decodeKeyValueMap(raw);
      if (decoded == null) {
        await _preserveCorruptFile(source);
        return {};
      }
      return decoded;
    } on FormatException {
      await _preserveCorruptFile(source);
      return {};
    } on TypeError {
      await _preserveCorruptFile(source);
      return {};
    } on FileSystemException {
      return {};
    }
  }

  Future<void> _writeRaw(Map<String, String> values) async {
    var totalLen = 0;
    for (final e in values.entries) {
      totalLen += e.key.length + e.value.length;
      if (totalLen >= 32768) break;
    }
    final encoded = totalLen >= 32768
        ? await Isolate.run(() => _encodeKeyValueMap(values))
        : _encodeKeyValueMap(values);
    await _writeFileAtomically(file, encoded);
  }

  @override
  Future<String?> read(String key) =>
      _queue.run(() async => (await _readRaw())[key]);

  /// Every key currently stored, as one consistent snapshot.
  /// Used by the one-time cache/settings split migration
  /// (app/bootstrap.dart, plan 96).
  Future<Map<String, String>> readAll() => _queue.run(_readRaw);

  @override
  Future<void> write(String key, String value) => _queue.run(() async {
    final values = await _readRaw();
    values[key] = value;
    await _writeRaw(values);
  });

  @override
  Future<void> delete(String key) => _queue.run(() async {
    final values = await _readRaw();
    if (values.remove(key) != null) await _writeRaw(values);
  });
}

/// Cache for channel lists, keyed per device and broadcasting type.
/// Channels are stored in the WebAPI JSON shape so [Channel.fromJson]
/// reads them back unchanged.
class ChannelCache {
  ChannelCache(this._kv);

  final KeyValueStore _kv;

  /// Prefix of every key this cache writes; the split migration
  /// (app/bootstrap.dart, plan 96) moves keys with this prefix
  /// out of the shared settings file into the cache's own file.
  static const String keyPrefix = 'channels:';

  String _key(String host, int broadcastingType) =>
      '$keyPrefix$host:$broadcastingType';

  Future<List<Channel>?> load(String host, int broadcastingType) async {
    final raw = await _kv.read(_key(host, broadcastingType));
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final list = decoded['channels'];
      if (list is! List) return null;
      return [
        for (final e in list)
          if (e is Map)
            Channel.fromJson(
              e.cast<String, dynamic>(),
              broadcastingType: broadcastingType,
            ),
      ];
    } on FormatException {
      return null;
    }
  }

  Future<void> save(
    String host,
    int broadcastingType,
    List<Channel> channels,
  ) async {
    await _kv.write(
      _key(host, broadcastingType),
      jsonEncode({
        'broadcastingType': broadcastingType,
        'fetchedAt': DateTime.now().toIso8601String(),
        'channels': [for (final c in channels) _channelToJson(c)],
      }),
    );
  }

  static Map<String, dynamic> _channelToJson(Channel c) => {
    'networkId': c.networkId,
    'transportStreamId': c.transportStreamId,
    'serviceId': c.serviceId,
    'serviceType': c.serviceType,
    'channelNumber': c.channelNumber,
    'branchNumber': c.branchNumber,
    'serviceName': c.serviceName,
    if (c.serviceProviderName != null)
      'serviceProviderName': c.serviceProviderName,
    if (c.freqChannelNo != null) 'freqChannelNo': c.freqChannelNo,
    if (c.remoteControlKeyId != null)
      'remoteControlKeyId': c.remoteControlKeyId,
    'contract': c.contract,
  };
}

/// Persistent accumulation of programme-guide events, keyed per
/// device and broadcasting type (plan 23). Only the events are
/// stored (serviceId -> events); channels always come from the
/// fresh fetch. See WebApiEpgService for why accumulation exists.
class EpgGuideCache {
  EpgGuideCache(this._kv);

  final KeyValueStore _kv;

  /// Prefix of every key this cache writes; the split migration
  /// (app/bootstrap.dart, plan 96) moves keys with this prefix
  /// out of the shared settings file into the cache's own file.
  static const String keyPrefix = 'epg-guide:';

  String _key(String host, int broadcastingType) =>
      '$keyPrefix$host:$broadcastingType';

  Future<Map<int, List<EpgEvent>>> load(
    String host,
    int broadcastingType,
  ) async {
    final raw = await _kv.read(_key(host, broadcastingType));
    if (raw == null) return const {};
    if (raw.length >= 32768) {
      return Isolate.run(() => _decodeEpgGuideCacheJson(raw));
    }
    return _decodeEpgGuideCacheJson(raw);
  }

  Future<void> save(String host, int broadcastingType, EpgGuide guide) async {
    final savedAtIso = DateTime.now().toIso8601String();
    final encoded = guide.eventCount >= 200
        ? await Isolate.run(
            () => _encodeEpgGuideCacheJson(broadcastingType, savedAtIso, guide),
          )
        : _encodeEpgGuideCacheJson(broadcastingType, savedAtIso, guide);
    await _kv.write(_key(host, broadcastingType), encoded);
  }

  static Map<String, dynamic> _eventToJson(EpgEvent e) => {
    'eventId': e.eventId,
    'start': e.start.toIso8601String(),
    'durationSec': e.duration.inSeconds,
    if (e.title != null) 'title': e.title,
    if (e.shortText != null) 'shortText': e.shortText,
    if (e.description != null) 'description': e.description,
    if (e.cast != null) 'cast': e.cast,
    if (e.extendedText != null) 'extendedText': e.extendedText,
    if (e.genreLevel1 != null) 'genreLevel1': e.genreLevel1,
    if (e.genreLevel2 != null) 'genreLevel2': e.genreLevel2,
    'extendedItems': [
      for (final i in e.extendedItems) {'label': i.label, 'value': i.value},
    ],
  };

  static EpgEvent _eventFromJson(Map<String, dynamic> j) => EpgEvent(
    eventId: (j['eventId'] as num).toInt(),
    start: DateTime.parse(j['start'] as String),
    duration: Duration(seconds: (j['durationSec'] as num).toInt()),
    title: j['title'] as String?,
    shortText: j['shortText'] as String?,
    description: j['description'] as String?,
    cast: j['cast'] as String?,
    extendedItems: [
      for (final i in (j['extendedItems'] as List? ?? const []))
        if (i is Map)
          EpgExtendedItem(
            label: i['label'].toString(),
            value: i['value'].toString(),
          ),
    ],
    extendedText: j['extendedText'] as String?,
    genreLevel1: (j['genreLevel1'] as num?)?.toInt(),
    genreLevel2: (j['genreLevel2'] as num?)?.toInt(),
  );
}

Map<String, String>? _decodeKeyValueMap(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return null;
  return {
    for (final e in decoded.entries) e.key.toString(): e.value.toString(),
  };
}

String _encodeKeyValueMap(Map<String, String> values) => jsonEncode(values);

Map<int, List<EpgEvent>> _decodeEpgGuideCacheJson(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const {};
    final services = decoded['services'];
    if (services is! List) return const {};
    return {
      for (final s in services)
        if (s is Map && s['serviceId'] is num && s['events'] is List)
          (s['serviceId'] as num).toInt(): [
            for (final e in s['events'] as List)
              if (e is Map) EpgGuideCache._eventFromJson(e.cast<String, dynamic>()),
          ],
    };
  } catch (_) {
    return const {};
  }
}

String _encodeEpgGuideCacheJson(
  int broadcastingType,
  String savedAtIso,
  EpgGuide guide,
) =>
    jsonEncode({
      'broadcastingType': broadcastingType,
      'savedAt': savedAtIso,
      'services': [
        for (final s in guide.services)
          {
            'serviceId': s.channel.serviceId,
            'events': [
              for (final e in s.events) EpgGuideCache._eventToJson(e),
            ],
          },
      ],
    });

/// Default retention window before station logos are refreshed from nasne.
const Duration channelLogoCacheMaxAge = Duration(days: 7);

/// Builds a deterministic signature of [channels] (`serviceId`, `channelNumber`,
/// `serviceName`) so station lineup/name changes trigger a logo cache refresh.
String buildChannelLogoSignature(List<Channel> channels) {
  if (channels.isEmpty) return '';
  final sorted = List<Channel>.of(channels)
    ..sort((a, b) {
      final bySid = a.serviceId.compareTo(b.serviceId);
      if (bySid != 0) return bySid;
      final byNum = a.channelNumber.compareTo(b.channelNumber);
      if (byNum != 0) return byNum;
      return a.serviceName.compareTo(b.serviceName);
    });
  return [
    for (final c in sorted)
      '${c.serviceId}:${c.channelNumber}:${c.serviceName.trim()}',
  ].join('|');
}

/// Persistent disk cache for broadcast station logo PNGs, keyed per device and
/// broadcasting type (`serviceId -> Uint8List`).
class ChannelLogoCache {
  ChannelLogoCache(this._kv);

  final KeyValueStore _kv;

  static const String keyPrefix = 'channel-logos:';

  String _key(String host, int broadcastingType) =>
      '$keyPrefix$host:$broadcastingType';

  Future<Map<int, Uint8List>?> load(
    String host,
    int broadcastingType, {
    Duration? maxAge,
    String? expectedChannelsSignature,
    DateTime? now,
  }) async {
    final raw = await _kv.read(_key(host, broadcastingType));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      if (maxAge != null) {
        final savedRaw = decoded['savedAt'];
        final savedAt =
            savedRaw is String ? DateTime.tryParse(savedRaw) : null;
        if (savedAt != null) {
          final currentTime = now ?? DateTime.now();
          if (currentTime.difference(savedAt) >= maxAge) return null;
        }
      }
      if (expectedChannelsSignature != null &&
          expectedChannelsSignature.isNotEmpty) {
        final cachedSig = decoded['channelsSignature'];
        if (cachedSig is! String || cachedSig != expectedChannelsSignature) {
          return null;
        }
      }
      final logosRaw = decoded['logos'];
      if (logosRaw is! Map) return null;
      final out = <int, Uint8List>{};
      for (final entry in logosRaw.entries) {
        final sid = int.tryParse(entry.key.toString());
        final b64 = entry.value;
        if (sid == null || b64 is! String || b64.isEmpty) continue;
        final bytes = base64Decode(b64);
        if (bytes.isNotEmpty) {
          out[sid] = normalizeAribLogoPng(bytes);
        }
      }
      return out.isEmpty ? null : out;
    } on FormatException {
      return null;
    }
  }

  Future<void> save(
    String host,
    int broadcastingType,
    Map<int, List<int>> logos, {
    String? channelsSignature,
    DateTime? savedAt,
  }) async {
    if (logos.isEmpty) return;
    final payload = <String, dynamic>{
      'broadcastingType': broadcastingType,
      'savedAt': (savedAt ?? DateTime.now()).toIso8601String(),
      if (channelsSignature != null && channelsSignature.isNotEmpty)
        'channelsSignature': channelsSignature,
      'logos': {
        for (final entry in logos.entries)
          if (entry.value.isNotEmpty)
            '${entry.key}': base64Encode(
              normalizeAribLogoPng(
                entry.value is Uint8List
                    ? entry.value as Uint8List
                    : Uint8List.fromList(entry.value),
              ),
            ),
      },
    };
    await _kv.write(_key(host, broadcastingType), jsonEncode(payload));
  }

  Future<void> delete(String host, int broadcastingType) =>
      _kv.delete(_key(host, broadcastingType));
}
