/// Compatibility helpers for libmpv initialization on Android <= 28 (Fire OS 6/7).
library;

import 'dart:ffi';
import 'dart:io';

typedef _MpvWakeupNative = Void Function(Pointer<Void> ctx);
typedef _MpvWakeupDart = void Function(Pointer<Void> ctx);

_MpvWakeupDart? _cachedMpvWakeup;
String? _cachedMpvWakeupPath;

/// Whether [Player] should use synchronous property/command setup (`async: false`)
/// to avoid the libmpv + Dart FFI `NativeCallable` wakeup race observed on
/// Android API 28 (Fire OS 7) and below.
bool shouldUseLegacySyncMpvInit({
  required bool isAndroid,
  required int? androidSdkInt,
}) => isAndroid && androidSdkInt != null && androidSdkInt <= 28;

/// Invokes `mpv_wakeup(handle)` directly via FFI to drain any pending initial
/// libmpv events when a wakeup callback is attached after `mpv_initialize`.
bool kickMpvEventLoop(
  int handle, {
  String libraryPath = 'libmpv.so',
  bool? isAndroidOverride,
}) {
  if (handle == 0) return false;
  if (!(isAndroidOverride ?? Platform.isAndroid)) return false;
  try {
    if (_cachedMpvWakeup == null || _cachedMpvWakeupPath != libraryPath) {
      final lib = DynamicLibrary.open(libraryPath);
      _cachedMpvWakeup = lib.lookupFunction<_MpvWakeupNative, _MpvWakeupDart>(
        'mpv_wakeup',
      );
      _cachedMpvWakeupPath = libraryPath;
    }
    _cachedMpvWakeup!(Pointer<Void>.fromAddress(handle));
    return true;
  } catch (_) {
    return false;
  }
}
