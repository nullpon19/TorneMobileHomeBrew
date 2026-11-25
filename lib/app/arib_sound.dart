/// Cross-platform ARIB STD-B24 built-in sound player.
///
/// Android uses the low-latency Kotlin AudioTrack synthesizer in
/// `FireTvHelper`; iOS, macOS, and Windows synthesize identical 44.1 kHz WAV
/// bytes in Dart and play them through `com.markun.tmhb/arib_sound` without
/// interrupting mpv playback audio.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/arib_chime_wav.dart';
import 'firetv_helper.dart';

class AribSoundPlayer {
  AribSoundPlayer({
    FireTvHelper? fireTvHelper,
    MethodChannel? channel,
    bool? isAndroidOverride,
    bool? isNativeWavSupportedOverride,
  }) : _fireTvHelper = fireTvHelper ?? FireTvHelper(),
       _channel = channel ?? const MethodChannel(_channelName),
       _isAndroidOverride = isAndroidOverride, // ignore: prefer_initializing_formals
       _isNativeWavSupportedOverride = isNativeWavSupportedOverride; // ignore: prefer_initializing_formals

  static const String _channelName = 'com.markun.tmhb/arib_sound';

  final FireTvHelper _fireTvHelper;
  final MethodChannel _channel;
  final bool? _isAndroidOverride;
  final bool? _isNativeWavSupportedOverride;

  bool get _isAndroid => _isAndroidOverride ?? _fireTvHelper.isAndroid;
  bool get _isNativeWavSupported =>
      _isNativeWavSupportedOverride ??
      (!kIsWeb && (Platform.isIOS || Platform.isMacOS || Platform.isWindows));

  Future<bool> playAribBuiltinSound(int soundId, {bool urgent = false}) async {
    if (_isAndroid) {
      return _fireTvHelper.playAribBuiltinSound(soundId, urgent: urgent);
    }
    if (!_isNativeWavSupported) return false;
    try {
      final wav = synthesizeAribBuiltinSoundWav(soundId, urgent: urgent);
      return await _channel.invokeMethod<bool>('playWav', {'wav': wav}) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
