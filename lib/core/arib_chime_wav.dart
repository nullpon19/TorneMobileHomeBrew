/// Pure-Dart WAV synthesizer for ARIB STD-B24 built-in chime sounds (e.g.
/// Emergency Earthquake Warning / data broadcast chimes).
///
/// Uses the exact same synthesis math as `MainActivity.kt` (`playAribBuiltinSound`)
/// so iOS, macOS, and Windows play the identical chime timbres as Fire TV /
/// Android without bundling external audio asset files.
library;

import 'dart:math' as math;
import 'dart:typed_data';

const int _sampleRate = 44100;

int _clampInt16(double value) {
  final rounded = value.toInt();
  if (rounded < -32768) return -32768;
  if (rounded > 32767) return 32767;
  return rounded;
}

/// Synthesizes a 44.1 kHz, 16-bit mono PCM RIFF/WAVE buffer for [soundId].
Uint8List synthesizeAribBuiltinSoundWav(int soundId, {bool urgent = false}) {
  final Int16List pcm;
  if (urgent) {
    const totalMs = 4600;
    const totalSamples = (_sampleRate * totalMs) ~/ 1000;
    final mix = Float64List(totalSamples);
    const strikeTimesMs = [0, 980, 1960, 2940];
    const tailSamples = (_sampleRate * 1660) ~/ 1000;
    const attackSamples = 350;
    for (final strikeMs in strikeTimesMs) {
      final startSample = (_sampleRate * strikeMs) ~/ 1000;
      for (var i = 0; i < tailSamples; i++) {
        final idx = startSample + i;
        if (idx >= totalSamples) break;
        final t = i / _sampleRate;
        final envAttack = i < attackSamples ? i / attackSamples : 1.0;
        final s = envAttack *
            (math.sin(2.0 * math.pi * 523.25 * t) * math.exp(-2.35 * t) * 1.00 +
                math.sin(2.0 * math.pi * 1046.50 * t) *
                    math.exp(-4.2 * t) *
                    0.14 +
                math.sin(2.0 * math.pi * 2616.25 * t) *
                    math.exp(-5.0 * t) *
                    0.22 +
                math.sin(2.0 * math.pi * 3662.75 * t) *
                    math.exp(-5.5 * t) *
                    0.28 +
                math.sin(2.0 * math.pi * 5232.50 * t) *
                    math.exp(-6.2 * t) *
                    0.32 +
                math.sin(2.0 * math.pi * 5755.75 * t) *
                    math.exp(-6.5 * t) *
                    0.30 +
                math.sin(2.0 * math.pi * 6279.00 * t) *
                    math.exp(-6.8 * t) *
                    0.26);
        mix[idx] += s;
      }
    }
    pcm = Int16List(totalSamples);
    const gain = 0.48;
    for (var i = 0; i < totalSamples; i++) {
      pcm[i] = _clampInt16(mix[i] * gain * 32767.0);
    }
  } else if (soundId >= 0 && soundId <= 4) {
    const totalMs = 1900;
    const totalSamples = (_sampleRate * totalMs) ~/ 1000;
    final mix = Float64List(totalSamples);
    const strikeTimesMs = [0, 200, 400, 600, 800, 1000];
    const strikeFreqs = [
      1046.50,
      1567.98,
      2637.02,
      1046.50,
      1567.98,
      2637.02,
    ];
    const tailSamples = (_sampleRate * 850) ~/ 1000;
    const attackSamples = (_sampleRate * 8) ~/ 1000;
    for (var n = 0; n < strikeTimesMs.length; n++) {
      final startSample = (_sampleRate * strikeTimesMs[n]) ~/ 1000;
      final freq = strikeFreqs[n];
      for (var i = 0; i < tailSamples; i++) {
        final idx = startSample + i;
        if (idx >= totalSamples) break;
        final t = i / _sampleRate;
        final envAttack = i < attackSamples ? i / attackSamples : 1.0;
        final s = envAttack *
            math.exp(-2.8 * t) *
            (math.sin(2.0 * math.pi * freq * t) +
                0.08 * math.sin(2.0 * math.pi * (3.0 * freq) * t));
        mix[idx] += s;
      }
    }
    pcm = Int16List(totalSamples);
    const gain = 0.34;
    for (var i = 0; i < totalSamples; i++) {
      pcm[i] = _clampInt16(mix[i] * gain * 32767.0);
    }
  } else {
    final List<({List<double> freqs, int durationMs, double gain})> segments =
        soundId == 13
        ? const [
            (freqs: [880.0], durationMs: 180, gain: 0.40),
            (freqs: [659.25], durationMs: 220, gain: 0.40),
            (freqs: [880.0], durationMs: 180, gain: 0.40),
            (freqs: [659.25], durationMs: 240, gain: 0.40),
          ]
        : const [
            (freqs: [880.0], durationMs: 180, gain: 0.24),
          ];
    var totalSamples = 0;
    for (final seg in segments) {
      totalSamples += (_sampleRate * seg.durationMs) ~/ 1000;
    }
    pcm = Int16List(totalSamples);
    var offset = 0;
    const attackSamples = (_sampleRate * 8) ~/ 1000;
    for (final seg in segments) {
      final count = (_sampleRate * seg.durationMs) ~/ 1000;
      for (var i = 0; i < count; i++) {
        final t = i / _sampleRate;
        var sum = 0.0;
        for (final f in seg.freqs) {
          sum += math.sin(2.0 * math.pi * f * t);
        }
        final avg = sum / seg.freqs.length;
        final envAttack = i < attackSamples ? i / attackSamples : 1.0;
        final envDecay = math.exp(-3.5 * i / count);
        pcm[offset + i] = _clampInt16(
          avg * envAttack * envDecay * seg.gain * 32767.0,
        );
      }
      offset += count;
    }
  }

  return _encodeMono16BitWav(pcm, sampleRate: _sampleRate);
}

Uint8List _encodeMono16BitWav(Int16List samples, {required int sampleRate}) {
  final dataBytes = samples.length * 2;
  final totalBytes = 44 + dataBytes;
  final out = Uint8List(totalBytes);
  final view = ByteData.sublistView(out);

  // RIFF chunk descriptor
  out.setRange(0, 4, [0x52, 0x49, 0x46, 0x46]); // "RIFF"
  view.setUint32(4, 36 + dataBytes, Endian.little);
  out.setRange(8, 12, [0x57, 0x41, 0x56, 0x45]); // "WAVE"

  // fmt subchunk
  out.setRange(12, 16, [0x66, 0x6D, 0x74, 0x20]); // "fmt "
  view.setUint32(16, 16, Endian.little); // PCM subchunk size
  view.setUint16(20, 1, Endian.little); // AudioFormat = 1 (PCM)
  view.setUint16(22, 1, Endian.little); // NumChannels = 1
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, sampleRate * 2, Endian.little); // ByteRate
  view.setUint16(32, 2, Endian.little); // BlockAlign
  view.setUint16(34, 16, Endian.little); // BitsPerSample

  // data subchunk
  out.setRange(36, 40, [0x64, 0x61, 0x74, 0x61]); // "data"
  view.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    view.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return out;
}
