/// Native [WakelockGuard] (plan 35): a hand-rolled platform
/// channel flips the OS keep-awake switch and reads the value
/// back, so the diagnostics log can prove whether the setting
/// actually stuck.
///
/// This replaces wakelock_plus (plan 32). In the build-13 field
/// test the device slept mid-playback although every enable had
/// "succeeded" — wakelock_plus never reads the value back, so a
/// request the platform ignored (the LiveContainer host is the
/// suspect on iOS) was indistinguishable from one that worked.
/// The native side here returns
/// `UIApplication.isIdleTimerDisabled` (iOS) / the window's
/// `FLAG_KEEP_SCREEN_ON` bit (Android) after every set, and can
/// be polled for the current value.
///
/// Failures are NOT swallowed here: a missing channel (e.g. a
/// native build that predates this one) must surface in the log
/// via [PlaybackWakelock], not hide. On platforms with no such
/// switch (desktop), the guard reports the requested state —
/// there is no idle timer for this app to suppress there.
library;

import 'dart:io';

import 'package:flutter/services.dart';

import '../core/core.dart';

class NativeWakelockGuard implements WakelockGuard {
  NativeWakelockGuard({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.markun.tmhb/wakelock';

  final MethodChannel _channel;

  bool get _supported =>
      Platform.isIOS ||
      Platform.isAndroid ||
      Platform.isMacOS ||
      Platform.isWindows;

  /// The state last applied on an unsupported platform, so
  /// [read] stays consistent with [apply] there.
  bool _lastApplied = false;

  @override
  Future<bool> apply(bool keepAwake) async {
    if (!_supported) {
      _lastApplied = keepAwake;
      return keepAwake;
    }
    final readback = await _channel.invokeMethod<bool>(
      'setKeepAwake',
      {'keepAwake': keepAwake},
    );
    return readback ?? keepAwake;
  }

  @override
  Future<bool> read() async {
    if (!_supported) return _lastApplied;
    final readback = await _channel.invokeMethod<bool>('getKeepAwake');
    return readback ?? _lastApplied;
  }
}
