/// DiscoveryService implementation: SSDP + device description
/// (plan 5.2 / 11.2 / 12.1).
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../errors.dart';
import '../models/device.dart';
import '../transport/ssdp_transport.dart';
import '../transport/xml_util.dart';
import 'interfaces.dart';

/// Returns whether [device] is a generic UPnP/DLNA MediaServer supporting
/// ContentDirectory:1 viewing (excluding nasne and proprietary DTCP+ endpoints).
bool isGenericDlnaMediaServer(NasneDevice device) {
  if (device.isNasne) return false;
  if (device.controlUrl('urn:schemas-upnp-org:service:ContentDirectory:1') ==
      null) {
    return false;
  }
  final isProprietaryDtcpPlus = device.services.keys.any(
    (k) => k.contains('X_DtcpPlus'),
  );
  return !isProprietaryDtcpPlus;
}

class SsdpDiscoveryService implements DiscoveryService {
  SsdpDiscoveryService({
    SsdpTransport? ssdp,
    http.Client? client,
    MulticastLockGuard? lockGuard,
    this.httpTimeout = const Duration(seconds: 10),
  })  : _ssdp = ssdp ?? SsdpTransport(lockGuard: lockGuard),
        _client = client ?? http.Client();

  final SsdpTransport _ssdp;
  final http.Client _client;
  final Duration httpTimeout;

  static const String mediaServerSearchTarget =
      'urn:schemas-upnp-org:device:MediaServer:1';

  @override
  Future<List<NasneDevice>> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final responses = await _ssdp.search(mediaServerSearchTarget,
        timeout: timeout);
    final locations = <String>{};
    for (final r in responses) {
      final loc = r.location;
      if (loc != null && loc.isNotEmpty) locations.add(loc);
    }
    final devices = <NasneDevice>[];
    for (final loc in locations) {
      try {
        final device = await describe(Uri.parse(loc));
        if (device.isNasne) devices.add(device);
      } on NasneError {
        // Not a nasne (or gone): discovery skips it by design.
        continue;
      }
    }
    return devices;
  }

  @override
  Future<NasneDevice> describe(Uri location) async {
    final http.Response resp;
    try {
      resp = await _client.get(location).timeout(httpTimeout);
    } catch (e) {
      throw NasneError.unreachable('ssdp:describe', cause: e);
    }
    if (resp.statusCode != 200) {
      throw NasneError.http(resp.statusCode, 'ssdp:describe');
    }
    return parseDeviceDescription(
        utf8.decode(resp.bodyBytes, allowMalformed: true), location);
  }

  /// Scans the LAN for generic DLNA MediaServer recorders (non-nasne DMS
  /// devices exposing `ContentDirectory:1`), deduplicated by UDN/control URL.
  Future<List<NasneDevice>> discoverDlnaServers({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final responses = await _ssdp.search(
      mediaServerSearchTarget,
      timeout: timeout,
    );
    final locations = <String>{};
    for (final r in responses) {
      final loc = r.location;
      if (loc != null && loc.isNotEmpty) locations.add(loc);
    }
    final devices = <NasneDevice>[];
    final seenIds = <String>{};
    for (final loc in locations) {
      try {
        final device = await describe(Uri.parse(loc));
        if (!isGenericDlnaMediaServer(device)) continue;
        final cds = device.controlUrl(
          'urn:schemas-upnp-org:service:ContentDirectory:1',
        );
        final key = device.udn.trim().isNotEmpty
            ? device.udn.trim()
            : (cds?.toString() ?? device.descriptionUrl.toString());
        if (seenIds.add(key)) {
          devices.add(device);
        }
      } on NasneError {
        continue;
      }
    }
    return devices;
  }

  /// Resolves a manually entered URL (`http://...`) or host (`192.168.x.x` /
  /// `host:port`) into a generic DLNA MediaServer description.
  Future<NasneDevice> probeDlnaServerAddress(
    String rawInput, {
    Duration probeTimeout = const Duration(seconds: 4),
  }) async {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) {
      throw NasneError.validation('dlna:probe', 'アドレスを入力してください');
    }
    final candidates = <Uri>[];
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      final parsed = Uri.tryParse(trimmed);
      if (parsed == null || parsed.host.isEmpty) {
        throw NasneError.validation('dlna:probe', '有効な URL を入力してください');
      }
      if (parsed.path.isNotEmpty && parsed.path != '/') {
        candidates.add(parsed);
      } else {
        for (final path in const [
          '/description.xml',
          '/dms/ddd.xml',
          '/Server0/DDD_S0',
          '/rootDesc.xml',
          '/',
        ]) {
          candidates.add(parsed.replace(path: path));
        }
      }
    } else {
      final parsedHostPort = Uri.tryParse('http://$trimmed');
      if (parsedHostPort == null || parsedHostPort.host.isEmpty) {
        throw NasneError.validation(
          'dlna:probe',
          '有効な IP アドレスまたはホスト名を入力してください',
        );
      }
      if (parsedHostPort.hasPort) {
        for (final path in const [
          '/description.xml',
          '/dms/ddd.xml',
          '/Server0/DDD_S0',
          '/rootDesc.xml',
          '/',
        ]) {
          candidates.add(parsedHostPort.replace(path: path));
        }
      } else {
        const portPaths = <(int, String)>[
          (20003, '/description.xml'),
          (60606, '/Server0/DDD_S0'),
          (55000, '/dms/ddd.xml'),
          (8888, '/description.xml'),
          (49152, '/description.xml'),
          (8200, '/rootDesc.xml'),
        ];
        for (final (port, path) in portPaths) {
          candidates.add(
            Uri(
              scheme: 'http',
              host: parsedHostPort.host,
              port: port,
              path: path,
            ),
          );
        }
      }
    }

    final results = await Future.wait<NasneDevice?>([
      for (final uri in candidates)
        () async {
          try {
            final resp = await _client.get(uri).timeout(probeTimeout);
            if (resp.statusCode != 200) return null;
            final device = parseDeviceDescription(
              utf8.decode(resp.bodyBytes, allowMalformed: true),
              uri,
            );
            return isGenericDlnaMediaServer(device) ? device : null;
          } catch (_) {
            return null;
          }
        }(),
    ]);
    for (final found in results) {
      if (found != null) return found;
    }
    throw NasneError.unreachable(
      'dlna:probe',
      cause: '指定されたアドレスから再生対応の DLNA/DTCP-IP サーバーが見つかりませんでした',
    );
  }
}

/// Parses a UPnP device description document into a [NasneDevice].
/// Exposed for fixture tests; [location] is the URL the document was
/// fetched from and the base for resolving relative control URLs.
NasneDevice parseDeviceDescription(String xmlText, Uri location) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xmlText);
  } catch (e) {
    throw NasneError.parse('ssdp:describe', cause: e);
  }
  final deviceElement = firstDescendant(doc.rootElement, 'device');
  if (deviceElement == null) {
    throw NasneError.parse('ssdp:describe', cause: 'no <device> element');
  }
  String text(String name) => childText(deviceElement, name) ?? '';

  final services = <String, UpnpServiceInfo>{};
  final serviceList = firstChild(deviceElement, 'serviceList');
  if (serviceList != null) {
    for (final service in childElements(serviceList, 'service')) {
      final type = childText(service, 'serviceType');
      final control = childText(service, 'controlURL');
      if (type == null || control == null) continue;
      Uri? resolve(String? value) =>
          value == null ? null : location.resolve(value);
      services[type] = UpnpServiceInfo(
        serviceType: type,
        controlUrl: location.resolve(control),
        scpdUrl: resolve(childText(service, 'SCPDURL')),
        eventSubUrl: resolve(childText(service, 'eventSubURL')),
      );
    }
  }

  return NasneDevice(
    host: location.host,
    descriptionUrl: location,
    friendlyName: text('friendlyName'),
    modelName: text('modelName'),
    manufacturer: text('manufacturer'),
    udn: text('UDN'),
    services: services,
  );
}
