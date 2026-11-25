/// EPG (programme guide) service (plan 12.8 / 21 / 24).
///
/// The acquisition path, determined by measurement and by the
/// unit-side EPG job's code (plan 24): fetch the binary version
/// table from `status/EPGVersionInfoGet` (it enumerates the
/// services the unit's EPG database holds), build an `EPGGet`
/// request body in the job's native format — an 8-byte header
/// (record count u16 BE at +4) plus one 24-byte record per service
/// carrying two 64-segment bitmaps, basic and extended, all set —
/// and POST it to `chEpg/EPGGet` (Content-Type: application/binary,
/// X-DTVToken over the body). The response deobfuscates (XOR 0x9d)
/// and inflates to the concatenation of every EIT section the
/// database holds for the requested segments: the complete guide
/// (8 days, all services, titles on every day) in one call.
///
/// History: plan 21 shipped a recipe that sent the version table
/// itself, repeated three times, as the body. That only appeared
/// to work: the job parsed the table's bytes as its own header and
/// records (the table's [01 0c] bytes read as a record count of
/// 268, whose size check is the "6,440-byte minimum" measured back
/// then), and the version bytes landed in bitmap positions, so a
/// partial, day-skewed subset came back — most visibly, no basic
/// (title-carrying) sections for the days +1..+3. Plan 24 replaced
/// the recipe with the real format; see `buildEpgGetBody`.
library;

import 'dart:isolate';
import 'dart:typed_data';

import '../diagnostics.dart';
import '../endpoints.dart';
import '../errors.dart';
import '../models/channel.dart';
import '../models/epg.dart';
import '../parsing/epg.dart';
import '../store/registration_store.dart';
import '../transport/webapi_transport.dart';

class WebApiEpgService {
  WebApiEpgService({
    required this._plain,
    required this._authed,
    this._guideCache,
    this._cacheHost,
    this._diag = const DiagLog.none(),
  });

  final WebApiTransport _plain;
  final WebApiTransport _authed;

  /// Diagnostics sink (plan 28), category epg.
  final DiagLog _diag;

  /// Persistent accumulation cache (plan 23). A single fetch now
  /// returns the unit's complete stored dataset (plan 24), but that
  /// dataset itself is only as complete as the unit-side EPG store:
  /// after the unit (re)builds its store — a reboot, a channel
  /// rescan — early fetches can still be partial. Merging each fetch
  /// into a persistent cache keeps the fuller picture across such
  /// windows. Null disables accumulation (tests, harness).
  final EpgGuideCache? _guideCache;
  final String? _cacheHost;

  /// Fetches and parses the full programme guide for
  /// [broadcastingType]. [channels] is the type's channel list
  /// (DeviceInfoService.listChannels); sections are anchored on it.
  Future<EpgGuide> getProgrammeGuide(
    int broadcastingType,
    List<Channel> channels,
  ) async {
    final stopwatch = Stopwatch()..start();
    final versionTable = await _plain.getBytes(
      WebApiEndpoints.epgVersionInfoGet,
      params: {'broadcastingType': '$broadcastingType'},
    );
    if (versionTable.isEmpty) {
      throw NasneError.parse('webapi:EPGVersionInfoGet',
          cause: 'empty version table');
    }
    // The version table enumerates the services of the unit-side
    // EPG database; the request asks for every segment of each, on
    // both the basic and the extended side (plan 24).
    // Terrestrial retains its validated parser. The BS version table may
    // contain gaps and non-0xc000 records before valid later services.
    final services = broadcastingType == 3
        ? parseSatelliteEpgVersionServices(versionTable, channels)
        : parseEpgVersionServices(versionTable);
    if (services.isEmpty) {
      if (broadcastingType == 3) {
        return completeBsEpgGuide(
          const EpgGuide(broadcastingType: 3, services: []), channels);
      }
      throw NasneError.parse('webapi:EPGVersionInfoGet',
          cause: 'no service records in version table');
    }
    final body = buildEpgGetBody(services);
    final raw = await _authed.postBinary(
      WebApiEndpoints.epgGet,
      body: body,
    );
    final rawBytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
    final fresh = rawBytes.length >= 16384
        ? await Isolate.run(
            () => parseEpgResponsePayload(
              rawResponse: rawBytes,
              channels: channels,
              broadcastingType: broadcastingType,
            ),
          )
        : parseEpgResponsePayload(
            rawResponse: rawBytes,
            channels: channels,
            broadcastingType: broadcastingType,
          );
    _diag(
      DiagCategory.epg,
      'epg fetch type=$broadcastingType: ${fresh.services.length} '
      'services, '
      '${fresh.services.fold<int>(0, (sum, s) => sum + s.events.length)} '
      'events in ${stopwatch.elapsedMilliseconds} ms',
    );
    final cache = _guideCache;
    final host = _cacheHost;
    if (cache == null || host == null) return fresh;
    // Accumulation is best-effort: a cache failure must never break
    // the guide itself.
    try {
      final cached = await cache.load(host, broadcastingType);
      final merged = (cached.isNotEmpty && fresh.eventCount >= 200)
          ? await Isolate.run(() => mergeEpgGuideWithCache(fresh, cached))
          : mergeEpgGuideWithCache(fresh, cached);
      await cache.save(host, broadcastingType, merged);
      return merged;
    } catch (_) {
      return fresh;
    }
  }

  /// Fetches the channel logos of [broadcastingType] as
  /// serviceId -> PNG bytes (services without a logo are absent).
  Future<Map<int, List<int>>> getChannelLogos(int broadcastingType) async {
    final raw = await _plain.getBytes(
      WebApiEndpoints.channelLogoDataGet,
      params: {'broadcastingType': '$broadcastingType'},
    );
    return parseChannelLogos(raw);
  }
}

/// Merges a freshly fetched [fresh] guide with the accumulated
/// [cached] events (serviceId -> events, from [EpgGuideCache]).
///
/// The fresh guide is authoritative: its services, channels and
/// events form the base. For an event present in both (same eventId
/// and start), fields the fresh copy lacks are filled from the
/// cached copy; fresh values always win. Cached events absent from
/// the fresh guide are carried over, except ones that ended more
/// than a day before the fresh guide starts (past data the UI no
/// longer shows; this also bounds the cache size). The result is
/// sorted by start within each service.
EpgGuide mergeEpgGuideWithCache(
  EpgGuide fresh,
  Map<int, List<EpgEvent>> cached,
) {
  if (cached.isEmpty || fresh.services.isEmpty) return fresh;
  final freshFrom = fresh.from;
  if (freshFrom == null) return fresh;
  final cutoff = freshFrom.subtract(const Duration(days: 1));
  (int, int) keyOf(EpgEvent e) =>
      (e.eventId, e.start.microsecondsSinceEpoch);
  return EpgGuide(
    broadcastingType: fresh.broadcastingType,
    services: [
      for (final service in fresh.services)
        EpgServiceGuide(
          channel: service.channel,
          events: _mergeEvents(
            service.events,
            cached[service.channel.serviceId] ?? const [],
            keyOf,
            cutoff,
          ),
        ),
    ],
  );
}

List<EpgEvent> _mergeEvents(
  List<EpgEvent> fresh,
  List<EpgEvent> cached,
  (int, int) Function(EpgEvent) keyOf,
  DateTime cutoff,
) {
  if (cached.isEmpty) return fresh;
  final cachedByKey = {for (final e in cached) keyOf(e): e};
  final freshKeys = {for (final e in fresh) keyOf(e)};
  final merged = <EpgEvent>[
    for (final e in fresh) _fillFrom(e, cachedByKey[keyOf(e)]),
    for (final e in cached)
      if (!freshKeys.contains(keyOf(e)) && e.end.isAfter(cutoff)) e,
  ];
  merged.sort((a, b) {
    final byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : a.eventId.compareTo(b.eventId);
  });
  return merged;
}

/// [fresh] with each still-null field taken from [cached] (its
/// accumulated twin). Returns [fresh] unchanged when there is no
/// twin or nothing to fill.
EpgEvent _fillFrom(EpgEvent fresh, EpgEvent? cached) {
  if (cached == null) return fresh;
  if (fresh.title != null &&
      fresh.shortText != null &&
      fresh.description != null &&
      fresh.cast != null &&
      fresh.extendedText != null &&
      fresh.extendedItems.isNotEmpty &&
      fresh.genreLevel1 != null &&
      fresh.genreLevel2 != null) {
    return fresh;
  }
  return EpgEvent(
    eventId: fresh.eventId,
    start: fresh.start,
    duration: fresh.duration,
    title: fresh.title ?? cached.title,
    shortText: fresh.shortText ?? cached.shortText,
    description: fresh.description ?? cached.description,
    cast: fresh.cast ?? cached.cast,
    extendedItems:
        fresh.extendedItems.isNotEmpty ? fresh.extendedItems : cached.extendedItems,
    extendedText: fresh.extendedText ?? cached.extendedText,
    genreLevel1: fresh.genreLevel1 ?? cached.genreLevel1,
    genreLevel2: fresh.genreLevel2 ?? cached.genreLevel2,
  );
}
