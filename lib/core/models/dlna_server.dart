/// Generic DLNA / DTCP-IP MediaServer models and DIDL mapping helpers
/// (viewing-only home-LAN playback for third-party DLNA/DTCP-IP recorders).
library;

import '../json_util.dart';
import '../time_util.dart';
import 'device.dart';
import 'didl.dart';
import 'schedule.dart';
import 'title.dart';

/// Persisted registration entry for a generic DLNA / DTCP-IP MediaServer.
class RegisteredDlnaServer {
  const RegisteredDlnaServer({
    required this.id,
    required this.host,
    required this.friendlyName,
    required this.descriptionUrl,
    required this.contentDirectoryControlUrl,
    this.modelName = '',
    this.manufacturer = '',
    this.udn = '',
    this.registeredAt,
  });

  /// Stable key for this server (typically UDN, falling back to control URL).
  final String id;
  final String host;
  final String friendlyName;
  final String descriptionUrl;
  final String contentDirectoryControlUrl;
  final String modelName;
  final String manufacturer;
  final String udn;
  final DateTime? registeredAt;

  factory RegisteredDlnaServer.fromDevice(NasneDevice device) {
    final cds = device.controlUrl(
      'urn:schemas-upnp-org:service:ContentDirectory:1',
    );
    if (cds == null) {
      throw ArgumentError('Device has no ContentDirectory:1 service');
    }
    final stableId = device.udn.trim().isNotEmpty
        ? device.udn.trim()
        : cds.toString();
    final name = device.friendlyName.trim().isNotEmpty
        ? device.friendlyName.trim()
        : (device.modelName.trim().isNotEmpty
              ? device.modelName.trim()
              : device.host);
    return RegisteredDlnaServer(
      id: stableId,
      host: device.host,
      friendlyName: name,
      descriptionUrl: device.descriptionUrl.toString(),
      contentDirectoryControlUrl: cds.toString(),
      modelName: device.modelName,
      manufacturer: device.manufacturer,
      udn: device.udn,
      registeredAt: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'host': host,
    'friendlyName': friendlyName,
    'descriptionUrl': descriptionUrl,
    'contentDirectoryControlUrl': contentDirectoryControlUrl,
    if (modelName.isNotEmpty) 'modelName': modelName,
    if (manufacturer.isNotEmpty) 'manufacturer': manufacturer,
    if (udn.isNotEmpty) 'udn': udn,
    if (registeredAt != null) 'registeredAt': registeredAt!.toIso8601String(),
  };

  factory RegisteredDlnaServer.fromJson(Map<String, dynamic> json) {
    const src = 'store:RegisteredDlnaServer';
    return RegisteredDlnaServer(
      id: reqString(json, 'id', src),
      host: reqString(json, 'host', src),
      friendlyName: optString(json, 'friendlyName') ?? 'DLNA レコーダー',
      descriptionUrl: reqString(json, 'descriptionUrl', src),
      contentDirectoryControlUrl: reqString(
        json,
        'contentDirectoryControlUrl',
        src,
      ),
      modelName: optString(json, 'modelName') ?? '',
      manufacturer: optString(json, 'manufacturer') ?? '',
      udn: optString(json, 'udn') ?? '',
      registeredAt: switch (optString(json, 'registeredAt')) {
        null => null,
        final s => DateTime.tryParse(s),
      },
    );
  }
}

/// Returns whether a DIDL `<res>` entry represents playable A/V content
/// (excluding JPEG/PNG thumbnail entries).
bool isPlayableVideoRes(TitleRes res) {
  final proto = res.protocolInfo.trim().toLowerCase();
  if (res.url.trim().isEmpty) return false;
  if (proto.isEmpty) return true;
  if (proto.contains('image/')) return false;
  return proto.contains('application/x-dtcp1') ||
      proto.contains(':video/') ||
      proto.contains('video/');
}

int? _inferBroadcastingTypeFromDidl(DidlItem item) {
  final objType =
      (item.properties['arib:objectType'] ?? item.properties['objectType'] ?? '')
          .trim()
          .toUpperCase();
  if (objType == 'ARIB_TB') return 2;
  if (objType == 'ARIB_BS') return 3;
  if (objType == 'ARIB_CS') return 4;
  return null;
}

/// Parses an ISO-8601 `dc:date` string as JST (`+09:00`) when offset is
/// omitted or explicit.
DateTime? parseDidlDate(String? raw) => parseJstDateTime(raw);

/// Converts a generic DLNA [DidlItem] into a [RecordedTitle] so existing
/// playback, subtitle, detail, and Jikkyo past-log flows can consume it.
RecordedTitle dlnaItemToRecordedTitle(DidlItem item) {
  final playableRes = [
    for (final r in item.res)
      if (isPlayableVideoRes(r)) r,
  ];
  Duration? bestDuration;
  for (final r in playableRes) {
    if (r.duration != null && r.duration! > Duration.zero) {
      bestDuration = r.duration;
      break;
    }
  }
  final btype = _inferBroadcastingTypeFromDidl(item);
  final channel = btype != null
      ? ScheduleChannel(
          broadcastingType: btype,
          channelType: btype,
          serviceId: item.channelNr ?? 0,
        )
      : null;
  return RecordedTitle(
    id: item.id,
    title: item.title,
    scheduledStart: parseDidlDate(item.date),
    scheduledDurationSeconds: bestDuration?.inSeconds,
    channel: channel,
    description: item.description,
    longDescription: item.longDescription,
    channelName: item.channelName,
    genre: item.genre,
    copyCountRemaining: item.copyCountRemaining,
    res: playableRes,
  );
}
