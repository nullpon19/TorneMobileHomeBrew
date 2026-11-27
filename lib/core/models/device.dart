/// Device / registration / information models (plan 12.5).
library;

import '../json_util.dart';
import '../token.dart';

/// One UPnP service entry from a device description, with its control
/// URL already resolved to an absolute URL.
class UpnpServiceInfo {
  const UpnpServiceInfo({
    required this.serviceType,
    required this.controlUrl,
    this.scpdUrl,
    this.eventSubUrl,
  });

  final String serviceType;
  final Uri controlUrl;
  final Uri? scpdUrl;
  final Uri? eventSubUrl;
}

/// A UPnP device that answered discovery, identified by its description.
///
/// Identification as a nasne is by description content, not by SSDP
/// headers: the real device's SSDP response carries no USN for the DMS
/// device (plan 11.2), so the description is the source of truth.
class NasneDevice {
  const NasneDevice({
    required this.host,
    required this.descriptionUrl,
    required this.friendlyName,
    required this.modelName,
    required this.manufacturer,
    required this.udn,
    required this.services,
  });

  /// Host name / IP address the description was fetched from.
  final String host;

  final Uri descriptionUrl;
  final String friendlyName;
  final String modelName;
  final String manufacturer;
  final String udn;

  /// serviceType URN -> service info.
  final Map<String, UpnpServiceInfo> services;

  bool get isNasne => modelName == 'nasne';

  Uri? controlUrl(String serviceType) => services[serviceType]?.controlUrl;

  /// Builds a device handle for a manually entered address, using the
  /// measured fallback control URL forms (plan 12.2 / 12.3). Used when
  /// SSDP discovery is unavailable; the description can still be fetched
  /// and [DiscoveryService.describe] preferred whenever possible.
  factory NasneDevice.direct(String host) {
    Uri url(int port, String path) => Uri(
          scheme: 'http',
          host: host,
          port: port,
          path: path,
        );
    return NasneDevice(
      host: host,
      descriptionUrl: url(58888, '/'),
      friendlyName: 'nasne',
      modelName: 'nasne',
      manufacturer: '',
      udn: '',
      services: {
        'urn:schemas-xsrs-org:service:X_ScheduledRecording:2':
            UpnpServiceInfo(
          serviceType: 'urn:schemas-xsrs-org:service:X_ScheduledRecording:2',
          controlUrl: url(64230, '/XSRS'),
        ),
        'urn:schemas-s-bras-org:service:X_PvrControl:1': UpnpServiceInfo(
          serviceType: 'urn:schemas-s-bras-org:service:X_PvrControl:1',
          controlUrl: url(64230, '/X_PvrControl'),
        ),
        'urn:schemas-upnp-org:service:ContentDirectory:1': UpnpServiceInfo(
          serviceType: 'urn:schemas-upnp-org:service:ContentDirectory:1',
          controlUrl: url(58888, '/MediaServer_ContentDirectory/control'),
        ),
        'urn:schemas-upnp-org:service:ConnectionManager:1': UpnpServiceInfo(
          serviceType: 'urn:schemas-upnp-org:service:ConnectionManager:1',
          controlUrl: url(58888, '/MediaServer_ConnectionManager/control'),
        ),
      },
    );
  }
}

/// A registered nasne: what the app persists after a successful
/// PINVerify (plan 5.2 / 5.5). The PIN itself is never stored; it is
/// derived from [macAddr] on demand.
class RegisteredNasne {
  const RegisteredNasne({
    required this.host,
    required this.udn,
    required this.friendlyName,
    required this.macAddr,
    this.registeredAt,
  });

  final String host;
  final String udn;
  final String friendlyName;

  /// MAC address as returned by `status/networkIfInfoGet`
  /// (the PIN derivation source, plan 11.5).
  final String macAddr;

  final DateTime? registeredAt;

  String get pin => TokenProvider.derivePin(macAddr);

  TokenProvider get tokenProvider => TokenProvider(pin);

  Map<String, dynamic> toJson() => {
        'host': host,
        'udn': udn,
        'friendlyName': friendlyName,
        'macAddr': macAddr,
        if (registeredAt != null)
          'registeredAt': registeredAt!.toIso8601String(),
      };

  factory RegisteredNasne.fromJson(Map<String, dynamic> json) {
    return RegisteredNasne(
      host: reqString(json, 'host', 'store:RegisteredNasne'),
      udn: optString(json, 'udn') ?? '',
      friendlyName: optString(json, 'friendlyName') ?? 'nasne',
      macAddr: reqString(json, 'macAddr', 'store:RegisteredNasne'),
      registeredAt: switch (optString(json, 'registeredAt')) {
        null => null,
        final s => DateTime.tryParse(s),
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RegisteredNasne &&
          runtimeType == other.runtimeType &&
          host == other.host &&
          udn == other.udn &&
          friendlyName == other.friendlyName &&
          macAddr == other.macAddr &&
          registeredAt == other.registeredAt;

  @override
  int get hashCode =>
      Object.hash(host, udn, friendlyName, macAddr, registeredAt);
}

/// Aggregated device information from the `status/*Get` reads (plan 12.5).
class DeviceInfo {
  const DeviceInfo({
    required this.name,
    required this.softwareVersion,
    this.backdatedVersion,
    this.currDate,
    this.areaIdentifierCode,
    this.pref,
    this.zipCode,
    this.finishSetup,
    this.updateExists,
  });

  final String name;
  final String softwareVersion;
  final String? backdatedVersion;

  /// Raw `currDate` string (ISO form) as returned by the device.
  final String? currDate;
  final String? areaIdentifierCode;
  final String? pref;
  final String? zipCode;
  final bool? finishSetup;
  final bool? updateExists;
}

/// One entry of `status/HDDListGet`.
///
/// Entries are told apart by [id]: id 0 is the internal drive and
/// any other id is an external one (plan 89.8). The response's
/// `internalFlag` does not follow its name — the internal drive
/// reports 0 and an external drive reported 1 — so [internal]
/// keeps the raw flag value and must not be used to tell the
/// drives apart (plan 116).
class HddEntry {
  const HddEntry({
    required this.id,
    required this.internal,
    required this.mounted,
    required this.registered,
  });

  final int id;

  /// Raw `internalFlag` value; inverted from its name (see the
  /// class doc). Use [id] to tell internal from external.
  final bool internal;
  final bool mounted;
  final bool registered;

  factory HddEntry.fromJson(Map<String, dynamic> json) {
    const src = 'webapi:/status/HDDListGet';
    return HddEntry(
      id: reqInt(json, 'id', src),
      internal: flag(json, 'internalFlag'),
      mounted: (optInt(json, 'mountStatus') ?? 0) != 0,
      registered: flag(json, 'registerFlag'),
    );
  }
}

/// Detail of one HDD from `status/HDDInfoGet` (sizes are bytes).
///
/// [serialNumber] identifies the physical drive; per plan section 7 it
/// must be masked in displays and records outside the device itself.
class HddInfo {
  const HddInfo({
    required this.id,
    required this.internal,
    required this.format,
    required this.name,
    this.vendorId,
    this.productId,
    this.serialNumber,
    required this.usedBytes,
    required this.freeBytes,
    required this.totalBytes,
  });

  final int id;
  final bool internal;
  final String format;
  final String name;
  final String? vendorId;
  final String? productId;
  final String? serialNumber;
  final int usedBytes;
  final int freeBytes;
  final int totalBytes;

  factory HddInfo.fromJson(Map<String, dynamic> json) {
    const src = 'webapi:/status/HDDInfoGet';
    return HddInfo(
      id: reqInt(json, 'id', src),
      internal: flag(json, 'internalFlag'),
      format: optString(json, 'format') ?? '',
      name: optString(json, 'name') ?? '',
      vendorId: optString(json, 'vendorID'),
      productId: optString(json, 'productID'),
      serialNumber: optString(json, 'serialNumber'),
      usedBytes: reqInt(json, 'usedVolumeSize', src),
      freeBytes: reqInt(json, 'freeVolumeSize', src),
      totalBytes: reqInt(json, 'totalVolumeSize', src),
    );
  }
}

/// `status/networkIfInfoGet` (plan 11.4). [macAddr] is the PIN source.
class NetworkInfo {
  const NetworkInfo({
    required this.macAddr,
    required this.ipv4Addr,
    this.gateway,
    this.subnetMask,
    this.primaryDns,
    this.secondaryDns,
    this.dhcpEnabled = false,
  });

  final String macAddr;
  final String ipv4Addr;
  final String? gateway;
  final String? subnetMask;
  final String? primaryDns;
  final String? secondaryDns;
  final bool dhcpEnabled;

  factory NetworkInfo.fromJson(Map<String, dynamic> json) {
    const src = 'webapi:/status/networkIfInfoGet';
    return NetworkInfo(
      macAddr: reqString(json, 'macAddr', src),
      ipv4Addr: reqString(json, 'ipv4Addr', src),
      gateway: optString(json, 'gateway'),
      subnetMask: optString(json, 'subnetMask'),
      primaryDns: optString(json, 'primaryDNS'),
      secondaryDns: optString(json, 'secondaryDNS'),
      dhcpEnabled: flag(json, 'enableDHCPFlag'),
    );
  }
}

/// `status/BCASInfoGet`. [cardId] identifies the B-CAS card; mask it in
/// displays and records (plan section 7 convention).
class BcasInfo {
  const BcasInfo({this.cardId, this.info, this.returnCode, this.status, this.sw});

  final String? cardId;
  final String? info;
  final String? returnCode;
  final String? status;
  final String? sw;

  factory BcasInfo.fromJson(Map<String, dynamic> json) {
    return BcasInfo(
      cardId: optString(json, 'cardId'),
      info: optString(json, 'info'),
      returnCode: optString(json, 'returnCode'),
      status: optString(json, 'status'),
      sw: optString(json, 'sw'),
    );
  }
}

/// The requesting client's own registration record, as returned by
/// `status/requestClientInfoGet` (measured working in phase 0).
class ClientInfo {
  const ClientInfo({
    this.ipv4Addr,
    this.macAddr,
    this.registered = false,
    this.name,
    this.userAgent,
    this.lastAccessDate,
  });

  final String? ipv4Addr;
  final String? macAddr;
  final bool registered;
  final String? name;
  final String? userAgent;
  final String? lastAccessDate;

  factory ClientInfo.fromJson(Map<String, dynamic> json) {
    return ClientInfo(
      ipv4Addr: optString(json, 'ipv4Addr'),
      macAddr: optString(json, 'macAddr'),
      registered: flag(json, 'registerFlag'),
      name: optString(json, 'name'),
      userAgent: optString(json, 'userAgent'),
      lastAccessDate: optString(json, 'lastAccessDate'),
    );
  }
}
