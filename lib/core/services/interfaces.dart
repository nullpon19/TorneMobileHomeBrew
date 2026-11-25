/// Domain service interfaces (plan 5.0 / 12.2).
///
/// UI and domain logic depend only on these interfaces; the concrete
/// transports (SSDP / WebAPI JSON / UPnP SOAP / DLNA) live behind the
/// implementations and can be replaced without touching callers.
library;

import 'dart:typed_data';

import '../dtcp/arib_ts_caption_tap.dart';
import '../models/device.dart';
import '../models/didl.dart';
import '../models/epg.dart';
import '../models/live_channel.dart';
import '../models/live_status.dart';
import '../models/channel.dart';
import '../models/schedule.dart';
import '../models/title.dart';

/// SSDP discovery + description-based identification (plan 5.2 / 12.1).
abstract interface class DiscoveryService {
  /// Scans the LAN for nasne devices. Identification is by device
  /// description content, never by SSDP headers alone (plan 11.2).
  Future<List<NasneDevice>> discover({Duration timeout});

  /// Fetches and parses a device description from [location]
  /// (an SSDP LOCATION URL or a manually entered device root).
  Future<NasneDevice> describe(Uri location);
}

/// Registration flow: description -> MAC -> PIN derivation ->
/// PINVerify (plan 5.2 / 11.5).
abstract interface class RegistrationService {
  /// Runs the full registration against [device] and returns the
  /// record to persist. Throws a NasneError when verification fails.
  Future<RegisteredNasne> register(NasneDevice device);

  /// Re-verifies an existing registration (PINVerify only).
  Future<bool> verify(RegisteredNasne registration);
}

/// Read-side device information (WebAPI `status/*`, plan 12.1).
abstract interface class DeviceInfoService {
  Future<DeviceInfo> getDeviceInfo();
  Future<List<HddEntry>> listHdds();
  Future<HddInfo> getHddInfo(int id);
  Future<NetworkInfo> getNetworkInfo();
  Future<BcasInfo> getBcasInfo();
  Future<List<Channel>> listChannels(int broadcastingType);
  Future<LiveStatus> getLiveStatus();
  Future<List<RecNgItem>> listRecNg();
  Future<ClientInfo> getClientInfo();
}

/// Reservations (UPnP SOAP X_ScheduledRecording, plan 12.1 / 12.3).
abstract interface class ScheduleService {
  Future<List<RecordSchedule>> listSchedules({
    int startingIndex = 0,
    int requestedCount = 50,
  });

  /// Creates a reservation from the full template. Returns the
  /// normalised (list-form) id of the created reservation.
  Future<String> createSchedule(NewRecordSchedule schedule);

  /// Applies a sparse update. Start time and duration are not
  /// updatable (plan 12.5); callers model a time change as
  /// delete + create.
  Future<void> updateSchedule(ScheduleUpdate update);

  /// Deletes by canonical (list-form) id.
  Future<void> deleteSchedule(String id);

  /// Checks a candidate reservation for conflicts, returning the
  /// conflicting existing reservations (empty when none).
  Future<List<RecordSchedule>> checkConflicts(NewRecordSchedule candidate);
}

/// Recorded titles: XSRS primary, WebAPI counts, DIDL complement
/// (plan 12.1 / 12.5). Callers only see the merged model.
abstract interface class TitleCatalogService {
  Future<List<RecordedTitle>> listTitles({bool withMetadata = true});

  /// Progressive variant of [listTitles] (plan 100): emits the
  /// titles accumulated so far as they arrive — a small first
  /// chunk after one short round trip, then one emission per
  /// fetched page — and a final emission, marked complete, once
  /// the DIDL complement is merged. Only the final emission is
  /// the whole list; earlier emissions carry the XSRS fields
  /// alone (no channel name, genre or copy count yet).
  Stream<TitleListProgress> listTitlesProgressively({bool withMetadata = true});
  Future<int> countTitles();
  Future<int> maxTitles();

  /// Deletes a recorded title by its canonical (list-form) id
  /// (plan 86.3). Irreversible; callers confirm with the user
  /// first and keep protected / recording titles away from here
  /// (the UI blocks both before asking).
  Future<void> deleteTitle(String id);

  /// Sets or clears a title's protection (plan 98; the
  /// X_UpdateTitle shape was device-verified in plan 86.3).
  /// The update sends the title's listed item document back
  /// with only `titleProtectFlag` changed, so [title] must be
  /// one obtained from [listTitles]. A protected title refuses
  /// deletion on the unit itself (UPnP error 877).
  Future<void> setTitleProtection(RecordedTitle title, {required bool protect});

  /// The title's thumbnail image bytes (JPEG or PNG), or null
  /// when the unit has none or it cannot be extracted
  /// (plan 86.6). Best-effort decoration: failures come back
  /// as null, never as an error the list has to handle.
  Future<Uint8List?> fetchThumbnail(String id);

  /// Reports where playback of a title stopped, so the unit's
  /// resume point (the XSRS `lastPlaybackTime` resumePoint the
  /// list reads back) follows the viewer across clients
  /// (plan 102). This is the write the official client performs
  /// when its playback ends; without it the unit never learns
  /// a position from this app and "continue" is never offered.
  ///
  /// Measured semantics of the underlying call: the position
  /// travels in milliseconds and the unit keeps whole seconds
  /// (truncated); zero clears the point; the unit does not
  /// clamp at the title's duration, so clearing at the end of
  /// a viewing is the caller's job; every accepted call
  /// re-stamps the title's last-playback time.
  Future<void> setResumePosition(String id, Duration position);

  /// The title's chapter positions (plan 112): the
  /// unit's silence-cut chapter points, read from
  /// X_GetTitleInfo (X_PvrControl) and validated against
  /// the recording's duration — the unit also serves
  /// broken chapter data for some titles (plan 110),
  /// and a title whose data fails validation, like one
  /// with no chapters, simply returns an empty list.
  /// Best-effort decoration in the [fetchThumbnail]
  /// sense: any failure — transport, fault, unparseable
  /// or invalid data — comes back as an empty list,
  /// never as an error playback has to handle.
  /// [durationSeconds] is the title's listed duration,
  /// the bound the validation checks the points
  /// against.
  Future<List<Duration>> fetchChapters(
    String id, {
    required int durationSeconds,
  });
}

/// Settings reads and the verified writes (WebAPI, plan 12.1).
/// Writes go through the token-authenticated POST path.
abstract interface class SettingsService {
  Future<String> getBoxName();
  Future<int> getMobileBitrate();
  Future<void> setBoxName(String name);
  Future<void> setMobileBitrate(int bitrateInfo);
}

/// Live channels: the DMS LiveTuner tree (plan 39). Each channel
/// carries the programme currently on air; the enumeration is a
/// DIDL walk (the X_GetLiveChList SOAP action returns terrestrial
/// service ids only and carries no programme information, so it
/// is not the primary path — live survey, 2026-11-17).
abstract interface class LiveCatalogService {
  /// All bands with their channels, in the device's order.
  Future<List<LiveBand>> listLiveChannels();
}

/// DLNA ContentDirectory Browse (plan 12.1) and the programme
/// guide behind the same boundary (plan 12.8 / 21).
abstract interface class MetadataService {
  /// The container holding all recordings (plan 11.8).
  static const String allRecordingsContainer = '0/video/all';

  /// The container holding the live tuner bands (plan 39).
  static const String liveTunerContainer = '0/video/LiveTuner';

  Future<DidlDocument> browse(String objectId);

  /// The full EPG programme guide for a broadcasting type
  /// (terrestrial = 2), anchored on the type's channel list.
  Future<EpgGuide> getProgrammeGuide(
    int broadcastingType,
    List<Channel> channels,
  );

  /// Channel logos of a broadcasting type: serviceId -> PNG bytes.
  /// Services without a logo are absent from the map.
  Future<Map<int, List<int>>> getChannelLogos(int broadcastingType);
}

/// A running playback session (Phase 5): the player reads the
/// decrypted stream from [mediaUri] (a loopback URL) until [stop]
/// tears the session down.
abstract interface class PlaybackSession {
  Uri get mediaUri;
  Future<void> stop();
}

/// Optional read-only streaming transfer counters exposed by a loopback
/// [PlaybackSession] so the player can observe whether decrypted bytes are
/// actively flowing during unseekable live pre-buffering.
abstract interface class StreamTransferMetrics {
  int get servedBytes;
  DateTime? get firstByteServedAt;
  DateTime? get lastByteServedAt;
  int get consecutiveReconnectErrors;
}

/// Optional diagnostic counters exposed by a loopback [PlaybackSession] for
/// release-safe startup tracing and timeout diagnostics (no secrets/URLs).
abstract interface class StreamDiagnosticMetrics {
  int get cipherBytes;
  int get plaintextBytes;
  int get downstreamRequestCount;
  Object? get lastUpstreamError;
}

/// Optional live-edge flush hook exposed by a loopback [PlaybackSession] so the
/// player can discard paused backlog and reconnect upstream at the latest
/// broadcast edge without redoing DTCP-IP AKE.
abstract interface class LiveEdgeResettable {
  Future<void> resetToLiveEdge();
}

/// Optional read-only ARIB STD-B24 caption layout & clear-event feed tapped
/// from the plaintext MPEG-TS/TTS stream in `DtcpProxy`.
abstract interface class AribCaptionLayoutSource {
  List<AribCaptionLayoutEvent> get aribCaptionEvents;
  double? get firstStreamPtsSeconds;
}

/// Playback boundary (plan 5.7). v1 shipped only the stub, which
/// reports [NasneErrorCategory.unsupported]; Phase 5 substitutes
/// the DTCP-IP engine (plan 26) behind the same boundary.
abstract interface class PlaybackEngine {
  bool get isSupported;

  /// Starts playback of [title] via [res] and returns the live
  /// session. The v1 stub always throws a NasneError of category
  /// `unsupported`; the DTCP-IP engine throws `validation` when no
  /// credential pair has been imported.
  Future<PlaybackSession> startPlayback(RecordedTitle title, TitleRes res);

  /// Starts live viewing of [channel] via [res] (plan 39): the
  /// same DTCP-IP path as a recording, against the channel's
  /// endless stream. Switching channels is starting a new session
  /// after stopping the old one; there is no resume or seek.
  Future<PlaybackSession> startLivePlayback(LiveChannel channel, TitleRes res);
}
