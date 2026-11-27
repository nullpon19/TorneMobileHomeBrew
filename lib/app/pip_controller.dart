/// Picture-in-Picture / floating mini-player controller via `com.markun.tmhb/pip`.
///
/// Supported natively on Android (phone, tablet, Fire TV with Android 8+ PiP)
/// and desktop platforms (macOS / Windows always-on-top mini window).
/// Safely reports unsupported (`false`) on iOS (pending future native video-layer
/// PiP bridging), Web, and test environments without a registered plugin handler.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PipController {
  PipController({
    MethodChannel? channel,
    EventChannel? eventChannel,
    Stream<bool>? eventStreamOverride,
    bool? isSupportedOverride,
  }) : _channel = channel ?? const MethodChannel(_channelName),
       _eventChannel = eventChannel ?? const EventChannel(_eventChannelName),
       _eventStreamOverride = eventStreamOverride, // ignore: prefer_initializing_formals
       _isSupportedOverride = isSupportedOverride; // ignore: prefer_initializing_formals

  static const String _channelName = 'com.markun.tmhb/pip';
  static const String _eventChannelName = 'com.markun.tmhb/pip_events';

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  final Stream<bool>? _eventStreamOverride;
  final bool? _isSupportedOverride;

  bool get _hasPlatformImplementation =>
      !kIsWeb && (Platform.isAndroid || Platform.isMacOS || Platform.isWindows);

  Future<bool> isSupported() async {
    if (_isSupportedOverride != null) return _isSupportedOverride;
    if (!_hasPlatformImplementation) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> enterPip({int aspectWidth = 16, int aspectHeight = 9}) async {
    if (_isSupportedOverride == false ||
        (_isSupportedOverride == null && !_hasPlatformImplementation)) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('enterPip', {
            'aspectWidth': aspectWidth,
            'aspectHeight': aspectHeight,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> exitPip() async {
    if (_isSupportedOverride == false ||
        (_isSupportedOverride == null && !_hasPlatformImplementation)) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('exitPip') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> setAutoPipEnabled(bool enabled) async {
    if (_isSupportedOverride == false ||
        (_isSupportedOverride == null && !_hasPlatformImplementation)) {
      return;
    }
    try {
      await _channel.invokeMethod<bool>('setAutoPipEnabled', {
        'enabled': enabled,
      });
    } on MissingPluginException {
      // Safe no-op in tests or unsupported platforms.
    } on PlatformException {
      // Non-fatal.
    }
  }

  Stream<bool> get onPipModeChanged {
    if (_eventStreamOverride != null) return _eventStreamOverride;
    if (_isSupportedOverride == false ||
        (_isSupportedOverride == null && !_hasPlatformImplementation)) {
      return const Stream<bool>.empty();
    }
    StreamSubscription<dynamic>? sub;
    late final StreamController<bool> controller;
    controller = StreamController<bool>.broadcast(
      onListen: () {
        try {
          sub = _eventChannel.receiveBroadcastStream().listen(
            (event) {
              if (!controller.isClosed) {
                controller.add(event == true);
              }
            },
            onError: (_) {},
          );
        } on MissingPluginException {
          // Safe no-op in tests or unsupported environments.
        } on PlatformException {
          // Safe no-op when native channel is unavailable.
        }
      },
      onCancel: () {
        final active = sub;
        sub = null;
        if (active != null) {
          unawaited(active.cancel().catchError((_) {}));
        }
      },
    );
    return controller.stream;
  }
}
