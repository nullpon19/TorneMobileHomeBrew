/// Optional compile-time preset seeding for personal Fire TV builds.
///
/// Values are injected at build time via `--dart-define-from-file` so that
/// no personal credential bytes or device identifiers live in source files.
/// Each preset is applied at most once on first launch (tracked by dedicated
/// key-value flags), so any later user edit or deletion is preserved across
/// restarts.
library;

import '../core/core.dart';

/// Build-time preset values supplied via `String.fromEnvironment`.
class FireTvPreset {
  const FireTvPreset({
    this.certHex = '',
    this.keyHex = '',
    this.nasneHost = '',
    this.nasneUdn = '',
    this.nasneName = '',
    this.nasneMac = '',
  });

  const FireTvPreset.fromEnvironment()
    : certHex = const String.fromEnvironment('TMHB_PRESET_CERT_HEX'),
      keyHex = const String.fromEnvironment('TMHB_PRESET_KEY_HEX'),
      nasneHost = const String.fromEnvironment('TMHB_PRESET_NASNE_HOST'),
      nasneUdn = const String.fromEnvironment('TMHB_PRESET_NASNE_UDN'),
      nasneName = const String.fromEnvironment('TMHB_PRESET_NASNE_NAME'),
      nasneMac = const String.fromEnvironment('TMHB_PRESET_NASNE_MAC');

  final String certHex;
  final String keyHex;
  final String nasneHost;
  final String nasneUdn;
  final String nasneName;
  final String nasneMac;

  bool get hasCredentials =>
      certHex.trim().isNotEmpty && keyHex.trim().isNotEmpty;

  bool get hasNasne =>
      nasneHost.trim().isNotEmpty && nasneMac.trim().isNotEmpty;
}

const String presetCredAppliedKey = 'firetv_preset_cred_applied';
const String presetNasneAppliedKey = 'firetv_preset_nasne_applied';

/// Applies compile-time credential and nasne presets once when not yet applied
/// and no user data is already stored.
Future<void> applyFireTvPresetsIfNeeded({
  required KeyValueStore keyValues,
  required CredentialStore credentialStore,
  required RegistrationStore registrationStore,
  FireTvPreset preset = const FireTvPreset.fromEnvironment(),
  DiagLog diag = const DiagLog.none(),
}) async {
  if (preset.hasCredentials &&
      await keyValues.read(presetCredAppliedKey) != 'true') {
    try {
      if (!await credentialStore.hasCredentials) {
        await credentialStore.save(
          certificate: hexToBytes(preset.certHex.trim().toLowerCase()),
          privateKey: hexToBytes(preset.keyHex.trim().toLowerCase()),
        );
      }
      await keyValues.write(presetCredAppliedKey, 'true');
    } catch (_) {
      // Never log raw error details or key bytes for credential operations.
      diag(DiagCategory.ui, 'firetv preset credential apply failed');
    }
  }

  if (preset.hasNasne &&
      await keyValues.read(presetNasneAppliedKey) != 'true') {
    try {
      final existing = await registrationStore.loadAll();
      if (existing.isEmpty) {
        final name = preset.nasneName.trim();
        await registrationStore.save(
          RegisteredNasne(
            host: preset.nasneHost.trim(),
            udn: preset.nasneUdn.trim(),
            friendlyName: name.isEmpty ? 'nasne' : name,
            macAddr: preset.nasneMac.trim(),
            registeredAt: DateTime.now(),
          ),
        );
      }
      await keyValues.write(presetNasneAppliedKey, 'true');
    } catch (_) {
      diag(DiagCategory.ui, 'firetv preset nasne apply failed');
    }
  }
}
