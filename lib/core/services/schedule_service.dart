/// ScheduleService implementation over UPnP SOAP XSRS (plan 12.3).
library;

import '../endpoints.dart';
import '../errors.dart';
import '../models/schedule.dart';
import '../parsing/xsrs.dart';
import '../transport/soap_transport.dart';
import 'interfaces.dart';
import 'paged_list.dart';

class SoapScheduleService implements ScheduleService {
  SoapScheduleService({
    required this._soap,
    required this._controlUrl,
  });

  final SoapTransport _soap;
  final Uri _controlUrl;

  static const String _serviceType =
      'urn:schemas-xsrs-org:service:X_ScheduledRecording:2';

  Future<SoapResponse> _call(String action,
      [Map<String, String> args = const {}]) {
    SoapServices.scheduledRecording.action(action); // validates the name
    return _soap.call(
      controlUrl: _controlUrl,
      serviceType: _serviceType,
      action: action,
      args: args,
    );
  }

  Map<String, String> _listArgs(int startingIndex, int requestedCount) => {
        'SearchCriteria': '',
        'Filter': '*',
        'StartingIndex': '$startingIndex',
        'RequestedCount': '$requestedCount',
        'SortCriteria': '',
      };

  @override
  Future<List<RecordSchedule>> listSchedules({
    int startingIndex = 0,
    int requestedCount = 50,
  }) async {
    final items = <RecordSchedule>[];
    await fetchAllListPages(
      initialStartingIndex: startingIndex,
      requestPage: (index) =>
          _call('X_GetRecordScheduleList', _listArgs(index, requestedCount)),
      consumePage: (resp) {
        final result = resp.result;
        if (result == null) {
          throw NasneError.parse(
            'soap:X_GetRecordScheduleList',
            cause: 'missing Result',
          );
        }
        final page = [
          for (final item in parseXsrsItems(
            result,
            'soap:X_GetRecordScheduleList',
          ))
            recordScheduleFromXsrs(
              item,
              source: 'soap:X_GetRecordScheduleList',
            ),
        ];
        items.addAll(page);
        return page.length;
      },
    );
    return items;
  }

  @override
  Future<String> createSchedule(NewRecordSchedule schedule) async {
    final elements = buildXsrsDocument(buildCreateItemXml(schedule));
    final resp = await _call('X_CreateRecordSchedule', {'Elements': elements});
    final rawId = resp.values['RecordScheduleID'];
    if (rawId == null || rawId.isEmpty) {
      throw NasneError.parse('soap:X_CreateRecordSchedule',
          cause: 'missing RecordScheduleID in response');
    }
    // The response form carries a literal "0x" prefix over the decimal
    // list id and fails deletion with 803 (plan 11.7); keep only the
    // normalised form.
    return normalizeScheduleId(rawId);
  }

  @override
  Future<void> updateSchedule(ScheduleUpdate update) async {
    if (!update.hasChangeField) {
      // Measured rule (phase 1 update matrix): the device faults
      // priorityFlag-only updates with 853 and updates without
      // priorityFlag with 402, so require the mandatory priorityFlag
      // (in the model) plus at least one change field, client-side.
      throw NasneError.validation('soap:X_UpdateRecordSchedule',
          'update needs priorityFlag plus at least one change field');
    }
    final elements = buildXsrsDocument(buildUpdateItemXml(update));
    await _call('X_UpdateRecordSchedule', {'Elements': elements});
  }

  @override
  Future<void> deleteSchedule(String id) async {
    await _call('X_DeleteRecordSchedule', {'RecordScheduleID': id});
  }

  @override
  Future<List<RecordSchedule>> checkConflicts(
      NewRecordSchedule candidate) async {
    // Phase 1 re-confirmation (plan 13): the phase 0 Fault from this
    // action was NOT a reservation-count quirk. A variant matrix on
    // the real device isolated the cause: the phase 0 candidate used
    // the compact +0900 datetime notation, which the xsrs write-side
    // actions reject (Fault 402 without an item id attribute, 803
    // with id=""); the colon form +09:00 succeeds at any reservation
    // count, including zero. A Fault here is therefore a genuine
    // request-shape error and propagates unchanged.
    final elements = buildXsrsDocument(buildCreateItemXml(candidate));
    final resp = await _call('X_GetConflictList', {'Elements': elements});
    final result = resp.result;
    if (result == null) return const [];
    return [
      for (final item in parseXsrsItems(result, 'soap:X_GetConflictList'))
        recordScheduleFromXsrs(item, source: 'soap:X_GetConflictList'),
    ];
  }
}
