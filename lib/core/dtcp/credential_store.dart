/// Storage for the user's own DTCP-IP device credential pair.
///
/// Design (plan 26.4): the pair is kept only in the OS vault
/// (iOS Keychain / Android Keystore) through flutter_secure_storage;
/// it is never written to a plain file, never logged, never included
/// in cloud backup or analytics payloads, and never leaves the
/// device except inside the AKE protocol itself. Import validates
/// the pair (see [DeviceCredentials]) before anything is stored, and
/// deleting the pair removes it from the vault.
library;

import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../errors.dart';
import '../store/registration_store.dart';
import 'ake.dart';
import 'dtcp_crypto.dart';
import 'srm.dart';

/// Vault access for the credential pair. The production
/// implementation is [SecureCredentialStore]; tests use
/// [InMemoryCredentialStore].
abstract interface class CredentialStore {
  /// The stored pair, or null when nothing has been imported.
  /// Throws a validation error when stored bytes no longer verify
  /// (corrupted vault contents).
  Future<DeviceCredentials?> load();

  /// Validates and stores [certificate] + [privateKey]. An existing
  /// pair is removed first, so a failed import never leaves a
  /// half-written pair behind.
  Future<void> save({
    required List<int> certificate,
    required List<int> privateKey,
  });

  /// Removes the pair from the vault.
  Future<void> delete();

  Future<bool> get hasCredentials;
}

/// Non-sensitive facts the settings UI may show about the stored
/// pair: identifiers and a fingerprint, never key material.
class CredentialSummary {
  const CredentialSummary({
    required this.deviceIdHex,
    required this.certificateSha1Hex,
  });

  /// 5-byte device ID from the certificate, hex.
  final String deviceIdHex;

  /// SHA-1 fingerprint of the (public) certificate.
  final String certificateSha1Hex;

  static CredentialSummary of(DeviceCredentials credentials) =>
      CredentialSummary(
        deviceIdHex: credentials.deviceId
            .toRadixString(16)
            .padLeft(10, '0')
            .toUpperCase(),
        certificateSha1Hex: bytesToHex(sha1Bytes(credentials.certificate))
            .toUpperCase(),
      );
}

/// flutter_secure_storage-backed store. On iOS the items are
/// first-unlock, this-device-only (Keychain), which also excludes
/// them from iCloud Keychain sync; on Android they are encrypted
/// with a Keystore-held key.
///
/// On macOS the items go to the legacy login keychain
/// (usesDataProtectionKeychain: false, plan 47). The plugin's
/// default — the data protection keychain — requires a
/// keychain-access-groups entitlement, and an ad-hoc signed app
/// (how the desktop build is distributed) cannot carry one:
/// launchd refuses to spawn it at all. The legacy keychain is
/// still the OS vault, so the "OS vault only" rule holds.
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({this.authorityKeys = const []})
    : _storage = const FlutterSecureStorage(
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
        mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      );

  final FlutterSecureStorage _storage;

  /// DTLA authority keys for validation; empty = the real DTLA
  /// keys. Non-empty only in tests (test authority).
  final List<Uint8List> authorityKeys;

  static const String _certKey = 'dtcp_certificate';
  static const String _privKey = 'dtcp_private_key';

  static String _encode(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _decode(String hex) {
    if (hex.length.isOdd) {
      throw NasneError.validation(
        'dtcp:store',
        'stored credential data is corrupted',
      );
    }
    return hexToBytes(hex);
  }

  @override
  Future<DeviceCredentials?> load() async {
    final certHex = await _storage.read(key: _certKey);
    final privHex = await _storage.read(key: _privKey);
    if (certHex == null && privHex == null) return null;
    if (certHex == null || privHex == null) {
      throw NasneError.validation(
        'dtcp:store',
        'stored credential data is incomplete',
      );
    }
    return DeviceCredentials(
      certificate: _decode(certHex),
      privateKey: _decode(privHex),
      authorityKeys: authorityKeys,
    );
  }

  @override
  Future<void> save({
    required List<int> certificate,
    required List<int> privateKey,
  }) async {
    // Validation first: DeviceCredentials throws on any problem and
    // nothing is written in that case.
    DeviceCredentials(
      certificate: certificate,
      privateKey: privateKey,
      authorityKeys: authorityKeys,
    );
    await delete();
    await _storage.write(key: _certKey, value: _encode(certificate));
    await _storage.write(key: _privKey, value: _encode(privateKey));
  }

  @override
  Future<void> delete() async {
    // Delete each key only when it is actually stored. On macOS,
    // flutter_secure_storage_darwin's delete probes the
    // synchronizable keychain variant first, and for an ad-hoc
    // signed app a SecItemDelete carrying
    // kSecAttrSynchronizable=true returns
    // errSecMissingEntitlement (-34018) -- not errSecItemNotFound --
    // when there is nothing to delete; the plugin then reports the
    // whole delete as failed (measured on the real machine,
    // plan 47). Reads are unaffected, and when an item does exist
    // the plugin's second (non-synchronizable) pass deletes it and
    // the call succeeds, so guarding on presence avoids the failure
    // without changing the semantics. This is also what makes
    // save() work on a first import: it deletes before writing.
    if (await _storage.read(key: _certKey) != null) {
      await _storage.delete(key: _certKey);
    }
    if (await _storage.read(key: _privKey) != null) {
      await _storage.delete(key: _privKey);
    }
  }

  @override
  Future<bool> get hasCredentials async =>
      (await _storage.read(key: _certKey)) != null;
}

/// Test-only in-memory store (same validation behaviour).
class InMemoryCredentialStore implements CredentialStore {
  InMemoryCredentialStore({this.authorityKeys = const []});

  final List<Uint8List> authorityKeys;
  DeviceCredentials? _credentials;

  @override
  Future<DeviceCredentials?> load() async => _credentials;

  @override
  Future<void> save({
    required List<int> certificate,
    required List<int> privateKey,
  }) async {
    final validated = DeviceCredentials(
      certificate: certificate,
      privateKey: privateKey,
      authorityKeys: authorityKeys,
    );
    _credentials = validated;
  }

  @override
  Future<void> delete() async => _credentials = null;

  @override
  Future<bool> get hasCredentials async => _credentials != null;
}

/// SRM persistence in a key-value store. The SRM is DTLA-signed
/// public data (plan 26.4), unlike the credential pair. Since
/// plan 96 the store behind this is the SRM's own file: the SRM
/// is DTCP protocol state (a revocation list) rewritten during
/// AKE — neither a user setting nor a display cache — so it no
/// longer shares a file with either.
class KeyValueSrmStore implements SrmStore {
  KeyValueSrmStore(this._store);

  final KeyValueStore _store;

  /// The key the SRM is stored under; the split migration
  /// (app/bootstrap.dart, plan 96) moves this key out of the
  /// legacy shared settings file.
  static const String storageKey = 'dtcp_srm';

  @override
  Future<Srm?> load() async {
    final raw = await loadRaw();
    if (raw == null) return null;
    try {
      return Srm.parse(raw);
    } on NasneError {
      return null; // A stored SRM that no longer verifies is dropped.
    }
  }

  @override
  Future<Uint8List?> loadRaw() async {
    final hex = await _store.read(storageKey);
    if (hex == null || hex.isEmpty) return null;
    try {
      return hexToBytes(hex);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> save(Uint8List raw, Srm srm) async {
    await _store.write(storageKey, bytesToHex(raw));
  }
}
