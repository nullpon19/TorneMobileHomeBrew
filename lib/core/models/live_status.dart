/// Live status aggregate model (plan 12.4 / 12.5).
///
/// `status/liveStreamStatusListGet` returns a snapshot of
/// generation-tagged sections (CAMsg / EMMMsg / EIT_PF / recNgList /
/// channel lists / ...). A section whose content the client has not
/// yet been given arrives as `{generation: n}` only; the model keeps
/// both the generation and, when present, the typed entries.
library;

import '../broadcast_text.dart';
import '../json_util.dart';
import '../time_util.dart';

/// One generation-tagged section of the aggregate snapshot.
class LiveSection {
  const LiveSection({required this.generation, required this.raw});

  final int generation;

  /// The section object as returned (entries included when populated).
  final Map<String, dynamic> raw;
}

/// A programme entry of EIT_PF (present / following).
///
/// The phase 0 fixture captured EIT_PF in its unpopulated
/// (`generation` only) state; the entry parser is therefore defensive:
/// known keys are typed, everything is also kept in [raw]. The parser
/// is finalised against the real entry shape captured in phase 1.
class ProgramInfo {
  const ProgramInfo({
    this.title,
    this.startTime,
    this.durationSeconds,
    this.eventId,
    this.serviceId,
    this.networkId,
    required this.raw,
  });

  final String? title;
  final DateTime? startTime;
  final int? durationSeconds;
  final int? eventId;
  final int? serviceId;
  final int? networkId;
  final Map<String, dynamic> raw;

  factory ProgramInfo.fromJson(Map<String, dynamic> json) {
    return ProgramInfo(
      title: normalizeBroadcastTextOrNull(
          optString(json, 'title') ?? optString(json, 'eventName')),
      startTime: parseNasneDateTime(
          optString(json, 'startTime') ?? optString(json, 'startDateTime')),
      durationSeconds:
          optInt(json, 'duration') ?? optInt(json, 'durationSeconds'),
      eventId: optInt(json, 'eventId') ?? optInt(json, 'eventID'),
      serviceId: optInt(json, 'serviceId') ?? optInt(json, 'serviceID'),
      networkId: optInt(json, 'networkId') ?? optInt(json, 'networkID'),
      raw: json,
    );
  }
}

/// The EIT_PF section: now / next programme information (plan 12.8).
class EitPf {
  const EitPf({required this.generation, this.present, this.following, required this.raw});

  final int generation;
  final ProgramInfo? present;
  final ProgramInfo? following;
  final Map<String, dynamic> raw;

  /// Whether real entries were present (false for the generation-only
  /// shape captured in phase 0).
  bool get populated => present != null || following != null;

  factory EitPf.fromSection(Map<String, dynamic>? section) {
    if (section == null) {
      return const EitPf(generation: 0, raw: {});
    }
    ProgramInfo? pick(List<String> keys) {
      for (final k in keys) {
        final v = section[k];
        if (v is Map) return ProgramInfo.fromJson(v.cast<String, dynamic>());
        if (v is List && v.isNotEmpty && v.first is Map) {
          return ProgramInfo.fromJson(
              (v.first as Map).cast<String, dynamic>());
        }
      }
      return null;
    }

    return EitPf(
      generation: optInt(section, 'generation') ?? 0,
      present: pick(const ['present', 'pfPresent', 'now', 'current']),
      following: pick(const ['following', 'pfFollowing', 'next']),
      raw: section,
    );
  }
}

/// One recording-failure entry. The full shape is available from the
/// standalone `status/recNgListGet` (plan 11.4); the aggregate section
/// carries the same items when populated.
class RecNgItem {
  const RecNgItem({
    required this.id,
    this.title,
    this.startTime,
    this.durationSeconds,
    this.serviceId,
    this.broadcastingType,
    this.desiredQualityMode,
    this.ngId,
    required this.raw,
  });

  final String id;
  final String? title;
  final DateTime? startTime;
  final int? durationSeconds;
  final int? serviceId;
  final int? broadcastingType;
  final int? desiredQualityMode;
  final int? ngId;
  final Map<String, dynamic> raw;

  factory RecNgItem.fromJson(Map<String, dynamic> json) {
    const src = 'webapi:/status/recNgListGet';
    return RecNgItem(
      id: reqString(json, 'id', src),
      title: normalizeBroadcastTextOrNull(optString(json, 'title')),
      startTime: parseNasneDateTime(optString(json, 'scheduledStartDateTime')),
      durationSeconds: optInt(json, 'scheduledDuration'),
      serviceId: optInt(json, 'scheduledChannelID'),
      broadcastingType: optInt(json, 'broadcastingType'),
      desiredQualityMode: optInt(json, 'desiredQualityMode'),
      ngId: optInt(json, 'ngID'),
      raw: json,
    );
  }
}

/// The aggregate live status snapshot.
class LiveStatus {
  const LiveStatus({required this.sections, required this.raw});

  /// Section name -> section (generation + raw content).
  final Map<String, LiveSection> sections;

  /// The whole response object.
  final Map<String, dynamic> raw;

  LiveSection? section(String name) => sections[name];

  EitPf get eitPf => EitPf.fromSection(sections['EIT_PF']?.raw);

  /// CA messages from the CAMsg section (empty when unpopulated).
  List<String> get caMessages => _messagesOf('CAMsg');

  /// EMM messages from the EMMMsg section (empty when unpopulated).
  List<String> get emmMessages => _messagesOf('EMMMsg');

  List<String> _messagesOf(String name) {
    final raw = sections[name]?.raw;
    if (raw == null) return const [];
    final out = <String>[];
    void collect(Object? v) {
      if (v is String) {
        if (v.isNotEmpty) out.add(v);
      } else if (v is List) {
        for (final e in v) {
          collect(e);
        }
      } else if (v is Map) {
        for (final e in v.values) {
          collect(e);
        }
      }
    }

    for (final entry in raw.entries) {
      if (entry.key == 'generation') continue;
      collect(entry.value);
    }
    return out;
  }

  /// Recording failures carried inside the aggregate (the standalone
  /// endpoint is the reliable source; this is a convenience view).
  List<RecNgItem> get recNgItems {
    final raw = sections['recNgList']?.raw;
    if (raw == null) return const [];
    return [
      for (final e in optList(raw, 'item'))
        if (e is Map) RecNgItem.fromJson(e.cast<String, dynamic>()),
    ];
  }

  factory LiveStatus.fromJson(Map<String, dynamic> json) {
    final sections = <String, LiveSection>{};
    for (final entry in json.entries) {
      if (entry.key == 'errorcode') continue;
      final v = entry.value;
      if (v is Map) {
        final m = v.cast<String, dynamic>();
        sections[entry.key] = LiveSection(
          generation: optInt(m, 'generation') ?? 0,
          raw: m,
        );
      }
    }
    return LiveStatus(sections: sections, raw: json);
  }
}
