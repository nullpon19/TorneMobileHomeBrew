/// Android / Fire TV platform helpers via `com.markun.tmhb/firetv_helper`.
///
/// Wraps OS media volume maxing, VPN / Tailscale status and launch,
/// and direct credential-file discovery on Fire OS 8 devices that lack
/// an interactive DocumentsUI file picker. On non-Android platforms and
/// in widget tests without a platform handler, every call safely falls
/// back without throwing.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Metadata for a candidate credential file discovered on local storage.
class CredentialCandidateFile {
  const CredentialCandidateFile({
    required this.path,
    required this.name,
    required this.folder,
    required this.size,
  });

  final String path;
  final String name;
  final String folder;
  final int size;
}

/// Platform channel wrapper for Fire TV specific helpers.
class FireTvHelper {
  FireTvHelper({
    MethodChannel? channel,
    bool? isAndroidOverride,
    bool? isTvOverride,
  }) : _channel = channel ?? const MethodChannel(_channelName),
       _isAndroidOverride = isAndroidOverride, // ignore: prefer_initializing_formals
       _isTvOverride = isTvOverride; // ignore: prefer_initializing_formals

  static const String _channelName = 'com.markun.tmhb/firetv_helper';

  final MethodChannel _channel;
  final bool? _isAndroidOverride;
  final bool? _isTvOverride;

  bool get isAndroid => _isAndroidOverride ?? (!kIsWeb && Platform.isAndroid);

  Future<bool> isTvDevice() async {
    if (_isTvOverride != null) return _isTvOverride;
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isTvDevice') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> setMediaVolumeMax() async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('setMediaVolumeMax') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> isVpnActive() async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isVpnActive') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> isTailscaleInstalled() async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isTailscaleInstalled') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> tryConnectTailscale() async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('tryConnectTailscale') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> launchTailscale() async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('launchTailscale') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> hasStoragePermission() async {
    if (!isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('hasStoragePermission') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> requestStoragePermission() async {
    if (!isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('requestStoragePermission') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<String?> getAppFilesDirPath() async {
    if (!isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('getAppFilesDirPath');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Returns Android `Build.VERSION.SDK_INT`, or `null` on non-Android platforms.
  Future<int?> getAndroidSdkInt() async {
    if (!isAndroid) return null;
    try {
      return await _channel.invokeMethod<int>('getAndroidSdkInt');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Returns free bytes available on Android's internal cache partition, or
  /// `null` on non-Android platforms / errors.
  Future<int?> getCacheAvailableBytes() async {
    if (!isAndroid) return null;
    try {
      return await _channel.invokeMethod<int>('getCacheAvailableBytes');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<List<CredentialCandidateFile>> listCredentialCandidateFiles() async {
    if (!isAndroid) return const [];
    try {
      final raw = await _channel.invokeListMethod<dynamic>(
        'listCredentialCandidateFiles',
      );
      if (raw == null) return const [];
      final files = <CredentialCandidateFile>[];
      for (final item in raw) {
        if (item is Map) {
          final path = item['path'];
          final name = item['name'];
          final folder = item['folder'];
          final size = item['size'];
          if (path is String && name is String && folder is String) {
            files.add(
              CredentialCandidateFile(
                path: path,
                name: name,
                folder: folder,
                size: size is int ? size : 0,
              ),
            );
          }
        }
      }
      return files;
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  Future<Uint8List?> readFileBytes(String path) async {
    if (!isAndroid) return null;
    try {
      return await _channel.invokeMethod<Uint8List>('readFileBytes', {
        'path': path,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Plays a synthesized ARIB STD-B24 built-in chime without stealing audio
  /// focus from `mpv`. Safe no-op on non-Android platforms or unmocked tests.
  Future<bool> playAribBuiltinSound(int soundId, {bool urgent = false}) async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('playAribBuiltinSound', {
            'soundId': soundId,
            'urgent': urgent,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Checks TCP reachability to [host] on nasne's WebAPI port (64210) or
  /// UPnP port (64220).
  Future<bool> isNasneReachable(
    String host, {
    Duration timeout = const Duration(milliseconds: 1800),
  }) async {
    for (final port in const [64210, 64220]) {
      try {
        final socket = await Socket.connect(host, port, timeout: timeout);
        socket.destroy();
        return true;
      } catch (_) {
        // Try next port or treat as unreachable.
      }
    }
    return false;
  }
}
