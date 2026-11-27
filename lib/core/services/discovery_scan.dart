/// Subnet-scan discovery (plan 16.3): a unicast alternative to SSDP
/// for environments where multicast is unavailable — on iOS the
/// multicast entitlement cannot be obtained for sideloaded apps, and
/// SSDP discovery was measured not to work there (plan 16.2).
///
/// The scan derives the /24 subnets of this device's own private
/// IPv4 addresses, probes every host with a short-timeout WebAPI
/// request (the measured `status/boxNameGet` shape is the filter),
/// and identifies candidates by their device description — the same
/// identification rule as SSDP discovery (description content, plan
/// 5.2). When the description cannot be fetched, the measured
/// fallback control URLs are used, mirroring manual registration.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../endpoints.dart';
import '../errors.dart';
import '../models/device.dart';
import 'discovery.dart';
import 'interfaces.dart';

/// Supplies the subnet base prefixes to scan, each of the form
/// `192.168.11` (the /24 is implied). Injectable for tests.
typedef SubnetBaseProvider = Future<List<String>> Function();

bool _isPrivateIpv4(InternetAddress address) {
  final parts = address.address.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]) ?? -1;
  final b = int.tryParse(parts[1]) ?? -1;
  if (a == 10) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  return false;
}

/// Default [SubnetBaseProvider]: the /24 base of every private IPv4
/// address assigned to this device. dart:io exposes no netmask, so
/// /24 is assumed — the home-LAN norm (plan 16.3).
Future<List<String>> localSubnetBases() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  final bases = <String>{};
  for (final iface in interfaces) {
    for (final address in iface.addresses) {
      if (!_isPrivateIpv4(address)) continue;
      final parts = address.address.split('.');
      bases.add('${parts[0]}.${parts[1]}.${parts[2]}');
    }
  }
  final sorted = bases.toList()
    ..sort((a, b) {
      int priority(String base) {
        if (base.startsWith('192.168.')) return 0;
        if (base.startsWith('172.')) return 1;
        return 2;
      }

      final byPrio = priority(a).compareTo(priority(b));
      return byPrio != 0 ? byPrio : a.compareTo(b);
    });
  return sorted;
}

/// Discovery by unicast subnet scan. See the library comment.
class SubnetScanDiscoveryService implements DiscoveryService {
  SubnetScanDiscoveryService({
    http.Client? client,
    this.probeTimeout = const Duration(milliseconds: 800),
    this.concurrency = 32,
    SubnetBaseProvider? subnetBases,
    this._describer,
  })  : _client = client ?? http.Client(),
        _subnetBases = subnetBases ?? localSubnetBases;

  final http.Client _client;

  /// Per-host probe timeout. One /24 sweep costs at most
  /// ceil(254 / [concurrency]) × [probeTimeout] (~3.2 s at the
  /// defaults); hosts that refuse or answer return far sooner.
  final Duration probeTimeout;

  /// Number of hosts probed in parallel.
  final int concurrency;

  final SubnetBaseProvider _subnetBases;

  /// Used for the authoritative description-based identification;
  /// defaults to the SSDP service's `describe` (transport only).
  final DiscoveryService? _describer;

  DiscoveryService get _describeService =>
      _describer ?? SsdpDiscoveryService(client: _client);

  @override
  Future<List<NasneDevice>> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    // [timeout] is the SSDP search window in the sibling
    // implementation; the scan is bounded by probeTimeout × batches
    // instead and ignores it.
    //
    // Subnets are scanned one at a time and the scan stops at the
    // first subnet that yields a device: a phone normally has a
    // single subnet anyway, and on multi-interface machines this
    // keeps dead virtual subnets (docker bridges, VPNs) from adding
    // their sweep time after the nasne has already been found.
    final bases = await _subnetBases();
    for (final base in bases) {
      final devices = await _scanSubnet(base);
      if (devices.isNotEmpty) return devices;
    }
    return const [];
  }

  Future<List<NasneDevice>> _scanSubnet(String base) async {
    final hosts = [for (var i = 1; i <= 254; i++) '$base.$i'];
    final candidates = <String>[];
    for (var start = 0; start < hosts.length; start += concurrency) {
      final batch = hosts.skip(start).take(concurrency);
      final results = await Future.wait([
        for (final host in batch)
          _probe(host).then((ok) => (host, ok)),
      ]);
      for (final (host, ok) in results) {
        if (ok) candidates.add(host);
      }
    }
    final devices = <NasneDevice>[];
    for (final host in candidates) {
      final device = await _identify(host);
      if (device != null) devices.add(device);
    }
    return devices;
  }

  /// Cheap filter: the nasne WebAPI answers `status/boxNameGet` with
  /// a JSON object carrying `errorcode: 0` and a `name`.
  Future<bool> _probe(String host) async {
    final abort = Completer<void>();
    final timer = Timer(probeTimeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      final req = http.AbortableRequest(
        'GET',
        Uri(
          scheme: 'http',
          host: host,
          port: 64210,
          path: WebApiEndpoints.boxNameGet.path,
        ),
        abortTrigger: abort.future,
      );
      final streamed = await _client.send(req).timeout(probeTimeout);
      if (streamed.statusCode != 200) {
        await streamed.stream.drain<void>().catchError((_) {});
        return false;
      }
      final bodyBytes = await streamed.stream.toBytes().timeout(probeTimeout);
      final decoded = jsonDecode(utf8.decode(bodyBytes));
      return decoded is Map &&
          decoded['errorcode'] == 0 &&
          decoded.containsKey('name');
    } catch (_) {
      if (!abort.isCompleted) abort.complete();
      return false;
    } finally {
      timer.cancel();
    }
  }

  /// Authoritative identification by device description (plan 5.2),
  /// falling back to the measured direct control URLs when the
  /// description cannot be fetched — the manual-registration rule.
  Future<NasneDevice?> _identify(String host) async {
    try {
      final device = await _describeService.describe(
        Uri(scheme: 'http', host: host, port: 58888, path: '/'),
      );
      return device.isNasne ? device : null;
    } catch (_) {
      return NasneDevice.direct(host);
    }
  }

  @override
  Future<NasneDevice> describe(Uri location) =>
      _describeService.describe(location);
}

/// Tries discovery implementations in order and returns the first
/// non-empty result (plan 16.3): SSDP first, subnet scan as the
/// fallback for multicast-restricted environments.
class CompositeDiscoveryService implements DiscoveryService {
  const CompositeDiscoveryService(this._chain);

  final List<DiscoveryService> _chain;

  @override
  Future<List<NasneDevice>> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    Object? lastError;
    var anySucceeded = false;
    for (final service in _chain) {
      try {
        final found = await service.discover(timeout: timeout);
        anySucceeded = true;
        if (found.isNotEmpty) return found;
      } on NasneError catch (e) {
        lastError = e;
      } on SocketException catch (e) {
        lastError = e;
      }
    }
    if (!anySucceeded && lastError != null) {
      if (lastError is NasneError) throw lastError;
      throw NasneError.unreachable('discovery', cause: lastError);
    }
    return const [];
  }

  @override
  Future<NasneDevice> describe(Uri location) =>
      _chain.first.describe(location);
}
