/// Reservation models (plan 12.5), sourced from xsrs items.
///
/// Contract fixed by the phase 0 measurements (plan 11.7):
///  * The canonical id is the list-form item id (a decimal string).
///    The create response's `RecordScheduleID` is the same value with a
///    literal `0x` prefix; it is normalised here and never kept.
///  * Create requires the full torne template; a missing
///    desiredMatchingID is rejected with 402.
///  * Update is sparse only (condition / quality / priority /
///    destination). Start time and duration cannot be changed through
///    the update action; the app layer models a time change as
///    delete + create.
///  * After an update the service re-reads; the re-read value is truth
///    (a desiredQualityMode change may be accepted yet not stored).
library;

import '../errors.dart';

/// Channel reference as it appears in an xsrs `scheduledChannelID`.
class ScheduleChannel {
  const ScheduleChannel({
    required this.broadcastingType,
    required this.channelType,
    required this.serviceId,
  });

  final int broadcastingType;
  final int channelType;
  final int serviceId;

  /// The xsrs element text form (`0x%04x`).
  String get serviceIdHex =>
      '0x${serviceId.toRadixString(16).padLeft(4, '0')}';

  static int parseServiceId(String text) {
    final t = text.trim();
    final parsed = (t.startsWith('0x') || t.startsWith('0X'))
        ? int.tryParse(t.substring(2), radix: 16)
        : int.tryParse(t);
    if (parsed == null) {
      throw NasneError.parse(
        'xsrs:scheduledChannelID',
        cause: 'invalid serviceId: $text',
      );
    }
    return parsed;
  }
}

/// One reservation, as listed by `X_GetRecordScheduleList`.
class RecordSchedule {
  const RecordSchedule({
    required this.id,
    required this.start,
    required this.durationSeconds,
    required this.conditionId,
    required this.channel,
    required this.desiredQualityMode,
    required this.desiredMatchingId,
    this.matchingIdType,
    required this.reservationCreatorId,
    required this.priorityFlag,
    required this.recordDestinationId,
    this.title,
    this.conflictId,
  });

  /// Canonical (list-form) id.
  final String id;
  final DateTime start;
  final int durationSeconds;

  /// Server-normalised condition id ("1" when created with an empty one).
  final String conditionId;
  final ScheduleChannel channel;
  final int desiredQualityMode;

  /// Server-normalised 4-element form (`0x..,0x..,0x..,0x..`).
  final String desiredMatchingId;
  final String? matchingIdType;
  final String reservationCreatorId;
  final int priorityFlag;
  final String recordDestinationId;

  /// Present in list items when the device resolved a programme name.
  final String? title;

  /// Present in conflict-list items (plan 11.7 fixture): the id of the
  /// conflicting existing reservation.
  final String? conflictId;

  DateTime get end => start.add(Duration(seconds: durationSeconds));
}

/// Everything needed to create a reservation (the full template).
class NewRecordSchedule {
  const NewRecordSchedule({
    required this.start,
    required this.durationSeconds,
    required this.channel,
    required this.networkId,
    this.eventId = 0,
    this.desiredQualityMode = 100,
    this.conditionId = '',
    this.reservationCreatorId = '2000',
    this.priorityFlag = 0,
    this.recordDestinationId = 'HDD',
  });

  final DateTime start;
  final int durationSeconds;
  final ScheduleChannel channel;

  /// networkId of the channel (decimal; rendered as `0x%04x`).
  final int networkId;

  /// EPG event id; 0 for a manual (time-based) reservation. Phase 0
  /// confirmed the no-event form is accepted (plan 12.5).
  final int eventId;

  final int desiredQualityMode;

  /// Empty means "server default" (normalised to "1" by the device).
  final String conditionId;
  final String reservationCreatorId;
  final int priorityFlag;
  final String recordDestinationId;

  /// The desiredMatchingID value in send form: `,,0x<networkId>,0x<eventId>`.
  String get desiredMatchingId =>
      ',,0x${networkId.toRadixString(16).padLeft(4, '0')},'
      '0x${eventId.toRadixString(16).padLeft(4, '0')}';
}

/// A sparse schedule update (plan 12.5).
///
/// Measured update contract (phase 1 update matrix, FW 2.60):
/// X_UpdateRecordSchedule succeeds only when `priorityFlag` is
/// present AND at least one other field is present. priorityFlag
/// alone faults 853; any field set without priorityFlag faults 402.
/// [priorityFlag] is therefore required here — pass the currently
/// stored value when the change is about another field. Note the
/// device accepts the call without necessarily reflecting the sent
/// values (priorityFlag 0->1 and desiredQualityMode 100->101 were
/// both accepted but not reflected); callers must re-read and trust
/// the re-read (plan 12.5).
class ScheduleUpdate {
  const ScheduleUpdate({
    required this.id,
    required this.priorityFlag,
    this.conditionId,
    this.desiredQualityMode,
    this.recordDestinationId,
  });

  final String id;
  final String? conditionId;
  final int? desiredQualityMode;
  final int priorityFlag;
  final String? recordDestinationId;

  /// True when at least one changeable field besides the mandatory
  /// priorityFlag is present.
  bool get hasChangeField =>
      conditionId != null ||
      desiredQualityMode != null ||
      recordDestinationId != null;

  bool get isEmpty => !hasChangeField;
}

/// Normalises an id coming from a create response: the device returns
/// `0x` + the decimal list id (plan 11.7, fixtures), and the prefixed
/// form fails deletion with 803, so only the bare form is ever kept.
String normalizeScheduleId(String raw) {
  final t = raw.trim();
  if (t.startsWith('0x') || t.startsWith('0X')) return t.substring(2);
  return t;
}
