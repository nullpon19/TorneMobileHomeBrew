/// Desktop fullscreen window controller via `com.markun.tmhb/window_control`.
///
/// Supported natively on macOS (`NSWindow.toggleFullScreen`) and Windows
/// (borderless monitor fullscreen). Safely no-ops on mobile / test environments.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DesktopWindowController {
  DesktopWindowController({MethodChannel? channel, bool? isDesktopOverride})
    : _channel = channel ?? const MethodChannel(_channelName),
      _isDesktopOverride = isDesktopOverride; // ignore: prefer_initializing_formals

  static const String _channelName = 'com.markun.tmhb/window_control';

  final MethodChannel _channel;
  final bool? _isDesktopOverride;

  bool get isSupported =>
      _isDesktopOverride ??
      (!kIsWeb && (Platform.isMacOS || Platform.isWindows));

  Future<bool> isFullscreen() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('isFullscreen') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> setFullscreen(bool fullscreen) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('setFullscreen', {
            'fullscreen': fullscreen,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> toggleFullscreen() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('toggleFullscreen') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
