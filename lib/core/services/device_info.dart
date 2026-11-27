/// DeviceInfoService implementation over WebAPI GETs (plan 12.1).
library;

import '../endpoints.dart';
import '../errors.dart';
import '../json_util.dart';
import '../models/channel.dart';
import '../models/device.dart';
import '../models/live_status.dart';
import '../transport/webapi_transport.dart';
import 'interfaces.dart';

class WebApiDeviceInfoService implements DeviceInfoService {
  WebApiDeviceInfoService(this._transport);

  final WebApiTransport _transport;

  @override
  Future<DeviceInfo> getDeviceInfo() async {
    final responses = await Future.wait([
      _transport.getJson(WebApiEndpoints.boxNameGet),
      _transport.getJson(WebApiEndpoints.softwareVersionGet),
      _transport.getJson(WebApiEndpoints.currDateGet),
      _transport.getJson(WebApiEndpoints.areaInfoGet),
      _transport.getJson(WebApiEndpoints.isFinishSetup),
    ]);
    final name = responses[0];
    final version = responses[1];
    final date = responses[2];
    final area = responses[3];
    final setup = responses[4];
    return DeviceInfo(
      name: optString(name, 'name') ?? '',
      softwareVersion: optString(version, 'softwareVersion') ?? '',
      backdatedVersion: optString(version, 'backdatedVersion'),
      currDate: optString(date, 'currDate'),
      areaIdentifierCode: optString(area, 'areaIdentifierCode'),
      pref: optString(area, 'pref'),
      zipCode: optString(area, 'zipCode'),
      finishSetup: optBool(setup, 'finishSetUpFlag'),
      updateExists: null,
    );
  }

  @override
  Future<bool?> checkSoftwareUpdate() async {
    try {
      final update = await _transport.getJson(
        WebApiEndpoints.updateCheck,
        timeoutOverride: const Duration(seconds: 5),
        maxAttempts: 1,
      );
      return optBool(update, 'existFlag');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<HddEntry>> listHdds() async {
    final json = await _transport.getJson(WebApiEndpoints.hddListGet);
    return [
      for (final e in optList(json, 'HDD'))
        if (e is Map) HddEntry.fromJson(e.cast<String, dynamic>()),
    ];
  }

  @override
  Future<HddInfo> getHddInfo(int id) async {
    final json = await _transport.getJson(
      WebApiEndpoints.hddInfoGet,
      params: {'id': '$id'},
    );
    final hdd = json['HDD'];
    if (hdd is! Map) {
      throw NasneError.parse(
        'webapi:/status/HDDInfoGet',
        cause: 'response has no "HDD" object',
      );
    }
    return HddInfo.fromJson(hdd.cast<String, dynamic>());
  }

  @override
  Future<NetworkInfo> getNetworkInfo() async {
    final json = await _transport.getJson(WebApiEndpoints.networkIfInfoGet);
    return NetworkInfo.fromJson(json);
  }

  @override
  Future<BcasInfo> getBcasInfo() async {
    final json = await _transport.getJson(WebApiEndpoints.bcasInfoGet);
    return BcasInfo.fromJson(json);
  }

  @override
  Future<List<Channel>> listChannels(int broadcastingType) async {
    final json = await _transport.getJson(
      WebApiEndpoints.channelListGet,
      params: {'broadcastingType': '$broadcastingType'},
    );
    return [
      for (final e in optList(json, 'channel'))
        if (e is Map)
          Channel.fromJson(e.cast<String, dynamic>(),
              broadcastingType: broadcastingType),
    ];
  }

  @override
  Future<LiveStatus> getLiveStatus() async {
    final json =
        await _transport.getJson(WebApiEndpoints.liveStreamStatusListGet);
    return LiveStatus.fromJson(json);
  }

  @override
  Future<List<RecNgItem>> listRecNg() async {
    final json = await _transport.getJson(WebApiEndpoints.recNgListGet);
    return [
      for (final e in optList(json, 'item'))
        if (e is Map) RecNgItem.fromJson(e.cast<String, dynamic>()),
    ];
  }

  @override
  Future<ClientInfo> getClientInfo() async {
    final json = await _transport.getJson(WebApiEndpoints.requestClientInfoGet);
    final client = json['client'];
    if (client is! Map) return const ClientInfo();
    return ClientInfo.fromJson(client.cast<String, dynamic>());
  }
}
