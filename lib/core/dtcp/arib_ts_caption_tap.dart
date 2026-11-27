/// Lightweight MPEG-TS/TTS tap that extracts ARIB STD-B24 caption layout
/// coordinates (`SWF`/`SDF`/`SDP`/`ACPS`/`APS`) and clear timing (`CS`/`TIME`)
/// directly from decrypted streams passing through `DtcpProxy`.
library;

import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import '../arib_b24.dart';

/// Decoded uncompressed ARIB STD-B24 DRCS bitmap glyph (`0x30` 1-byte / `0x31` 2-byte).
class AribDrcsGlyph {
  const AribDrcsGlyph._({
    required this.width,
    required this.height,
    required this.maxLevel,
    required this.levels,
    required this.signature,
  });

  factory AribDrcsGlyph.fromLevels({
    required int width,
    required int height,
    required int maxLevel,
    required Uint8List levels,
  }) {
    var hash = 0x811C9DC5;
    void mix(int byte) {
      hash ^= byte & 0xFF;
      hash = (hash * 0x01000193) & 0x7FFFFFFF;
    }

    mix(width);
    mix(height);
    mix(maxLevel);
    for (final b in levels) {
      mix(b);
    }
    return AribDrcsGlyph._(
      width: width,
      height: height,
      maxLevel: maxLevel < 1 ? 1 : maxLevel,
      levels: levels,
      signature: hash,
    );
  }

  final int width;
  final int height;
  final int maxLevel;
  final Uint8List levels;
  final int signature;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AribDrcsGlyph) return false;
    if (signature != other.signature ||
        width != other.width ||
        height != other.height ||
        maxLevel != other.maxLevel ||
        levels.length != other.levels.length) {
      return false;
    }
    for (var i = 0; i < levels.length; i++) {
      if (levels[i] != other.levels[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => signature;
}

/// One decoded styled span inside an ARIB caption line.
class AribCaptionStyledRun {
  const AribCaptionStyledRun({
    required this.text,
    this.colorArgb = 0xFFFFFFFF,
    this.scale = 1.0,
    this.drcsGlyph,
  });

  final String text;
  final int colorArgb;
  final double scale;
  final AribDrcsGlyph? drcsGlyph;
}

/// Horizontal & vertical bounds and decoded styled text runs of one ARIB caption line.
class AribCaptionLinePlacement {
  const AribCaptionLinePlacement({
    required this.normalizedX,
    required this.normalizedY,
    required this.endNormalizedX,
    required this.charCount,
    this.runs = const [],
    this.backgroundColorArgb,
  });

  /// Normalized left edge (`0.0..1.0` across [AribCaptionLayoutEvent.planeWidth]).
  final double normalizedX;

  /// Normalized vertical center (`0.0..1.0` across [AribCaptionLayoutEvent.planeHeight]).
  final double normalizedY;

  /// Normalized right edge of the last non-space character on this line.
  final double endNormalizedX;

  /// Number of visible characters measured on this line.
  final int charCount;

  /// Decoded ARIB STD-B24 styled text runs for direct rendering.
  final List<AribCaptionStyledRun> runs;

  /// Optional ARIB background color specified via `COL 0x50..0x5F` / `RCS`.
  final int? backgroundColorArgb;
}

/// Decoded caption or superimpose positioning, styled text, and timing metadata from one ARIB PES.
class AribCaptionLayoutEvent {
  const AribCaptionLayoutEvent({
    required this.ptsSeconds,
    required this.planeWidth,
    required this.planeHeight,
    required this.lines,
    required this.isClearOnly,
    this.clearAfterSeconds,
    this.startsWithClear = false,
    this.builtinSoundId,
    this.sequence = 0,
    this.receivedAt,
    this.isSuperimpose = false,
  });

  final double ptsSeconds;
  final double planeWidth;
  final double planeHeight;
  final List<AribCaptionLinePlacement> lines;
  final bool isClearOnly;
  final double? clearAfterSeconds;
  final bool startsWithClear;
  final int? builtinSoundId;
  final int sequence;
  final DateTime? receivedAt;
  final bool isSuperimpose;

  bool get hasDecodedText => lines.any(
    (l) => l.runs.any((r) => r.drcsGlyph != null || r.text.trim().isNotEmpty),
  );
}

class _MutableLineBucket {
  _MutableLineBucket({
    required this.baselineY,
    required this.centerY,
    required this.minX,
    required this.maxEndX,
    required this.charCount,
    this.backgroundColorArgb,
  });

  double baselineY;
  double centerY;
  double minX;
  double maxEndX;
  int charCount;
  int? backgroundColorArgb;
  bool pendingSpace = false;
  final List<AribCaptionStyledRun> runs = [];

  void appendText(
    String text,
    int colorArgb,
    double scale, {
    AribDrcsGlyph? drcsGlyph,
  }) {
    if (text.isEmpty && drcsGlyph == null) return;
    if (pendingSpace && runs.isNotEmpty) {
      _appendMerged(' ', runs.last.colorArgb, runs.last.scale);
    }
    pendingSpace = false;
    _appendMerged(text, colorArgb, scale, drcsGlyph: drcsGlyph);
  }

  void _appendMerged(
    String text,
    int colorArgb,
    double scale, {
    AribDrcsGlyph? drcsGlyph,
  }) {
    if (text.isEmpty && drcsGlyph == null) return;
    if (drcsGlyph == null &&
        runs.isNotEmpty &&
        runs.last.drcsGlyph == null &&
        runs.last.colorArgb == colorArgb &&
        runs.last.scale == scale) {
      final prev = runs.removeLast();
      runs.add(
        AribCaptionStyledRun(
          text: '${prev.text}$text',
          colorArgb: colorArgb,
          scale: scale,
        ),
      );
      return;
    }
    runs.add(
      AribCaptionStyledRun(
        text: text,
        colorArgb: colorArgb,
        scale: scale,
        drcsGlyph: drcsGlyph,
      ),
    );
  }

  List<AribCaptionStyledRun> buildTrimmedRuns() {
    if (runs.isEmpty) return const [];
    final out = List<AribCaptionStyledRun>.of(runs);
    while (out.isNotEmpty) {
      if (out.first.drcsGlyph != null) break;
      final trimmed = out.first.text.replaceFirst(RegExp(r'^ +'), '');
      if (trimmed == out.first.text) break;
      if (trimmed.isEmpty) {
        out.removeAt(0);
      } else {
        out[0] = AribCaptionStyledRun(
          text: trimmed,
          colorArgb: out.first.colorArgb,
          scale: out.first.scale,
        );
        break;
      }
    }
    while (out.isNotEmpty) {
      if (out.last.drcsGlyph != null) break;
      final trimmed = out.last.text.replaceFirst(RegExp(r' +$'), '');
      if (trimmed == out.last.text) break;
      if (trimmed.isEmpty) {
        out.removeLast();
      } else {
        out[out.length - 1] = AribCaptionStyledRun(
          text: trimmed,
          colorArgb: out.last.colorArgb,
          scale: out.last.scale,
        );
        break;
      }
    }
    return List<AribCaptionStyledRun>.unmodifiable(out);
  }
}

/// Parses MPEG-TS (`188` B) or MPEG-TTS (`192` B) plaintext byte slices on the
/// fly and retains a rolling ring buffer of recent [AribCaptionLayoutEvent]s.
class AribTsCaptionTap {
  static const int _tsPacketSize = 188;
  static const int _ttsPacketSize = 192;
  static const int _maxCarryBytes = _ttsPacketSize * 3;
  static const int _maxBufferedEvents = 2400;
  static const int _maxSuperimposeEvents = 256;
  static const int _maxDrcsGlyphs = 512;
  static const int _maxPesBytes = 64 * 1024;
  static const int _maxPsiBytes = 4096;

  /// Roll-over period for 33-bit 90 kHz MPEG-TS timestamps (~26.5 hours).
  static const double ptsWrapSeconds = 8589934592.0 / 90000.0;

  Uint8List _carry = Uint8List(0);
  int _packetStride = 0; // 0 = unsynced, 188 = TS, 192 = TTS
  int _pmtPid = -1;
  int _captionPid = -1;
  int _captionComponentTag = 0xFF;
  int _superimposePid = -1;
  int _superimposeComponentTag = 0xFF;
  double? _firstStreamPtsSeconds;
  double? _lastAvPtsSeconds;

  BytesBuilder? _patSection;
  int _patExpectedLen = 0;
  BytesBuilder? _pmtSection;
  int _pmtExpectedLen = 0;

  BytesBuilder? _captionPes;
  double? _captionPesPtsSeconds;
  int _captionExpectedPayloadBytes = 0;

  BytesBuilder? _superimposePes;
  double? _superimposePesPtsSeconds;
  int _superimposeExpectedPayloadBytes = 0;
  int _superimposeSeqCounter = 0;

  final List<AribCaptionLayoutEvent> _events = [];
  final Map<int, AribDrcsGlyph> _drcsGlyphs = {};
  final List<AribCaptionLayoutEvent> _superimposeEvents = [];
  final Map<int, AribDrcsGlyph> _superimposeDrcsGlyphs = {};
  int _skipPrefixBytes = 0;

  List<AribCaptionLayoutEvent> get events => UnmodifiableListView(_events);
  List<AribCaptionLayoutEvent> get superimposeEvents =>
      UnmodifiableListView(_superimposeEvents);
  Map<int, AribDrcsGlyph> get drcsGlyphs =>
      UnmodifiableMapView(_drcsGlyphs);
  double? get firstStreamPtsSeconds => _firstStreamPtsSeconds;
  int? get captionPid => _captionPid >= 0 ? _captionPid : null;
  int? get superimposePid => _superimposePid >= 0 ? _superimposePid : null;

  /// Resets framing and partial PES buffers across seek jumps while preserving
  /// discovered PIDs, anchor PTS, DRCS glyphs, and buffered events.
  void resetFraming() {
    _carry = Uint8List(0);
    _skipPrefixBytes = 0;
    _patSection = null;
    _patExpectedLen = 0;
    _pmtSection = null;
    _pmtExpectedLen = 0;
    _captionPes = null;
    _captionPesPtsSeconds = null;
    _captionExpectedPayloadBytes = 0;
    _superimposePes = null;
    _superimposePesPtsSeconds = null;
    _superimposeExpectedPayloadBytes = 0;
  }

  /// Clears all framing, PIDs, stream PTS origin, DRCS glyphs, and cached layout events.
  void resetAll() {
    resetFraming();
    _packetStride = 0;
    _pmtPid = -1;
    _captionPid = -1;
    _captionComponentTag = 0xFF;
    _superimposePid = -1;
    _superimposeComponentTag = 0xFF;
    _firstStreamPtsSeconds = null;
    _lastAvPtsSeconds = null;
    _superimposeSeqCounter = 0;
    _events.clear();
    _drcsGlyphs.clear();
    _superimposeEvents.clear();
    _superimposeDrcsGlyphs.clear();
  }

  /// Feeds decrypted plaintext TS/TTS bytes into the tap.
  void feed(List<int> chunk) {
    if (chunk.isEmpty) return;

    var raw = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    if (_skipPrefixBytes > 0) {
      if (raw.length <= _skipPrefixBytes) {
        _skipPrefixBytes -= raw.length;
        return;
      }
      raw = Uint8List.sublistView(raw, _skipPrefixBytes);
      _skipPrefixBytes = 0;
    }

    final Uint8List buf;
    if (_carry.isEmpty) {
      buf = raw;
    } else {
      final combined = Uint8List(_carry.length + raw.length);
      combined.setAll(0, _carry);
      combined.setAll(_carry.length, raw);
      buf = combined;
      _carry = Uint8List(0);
    }

    var pos = 0;
    while (pos < buf.length) {
      if (_packetStride == 0) {
        final synced = _detectSync(buf, pos);
        if (synced == null) {
          final tailLen = math.min(_maxCarryBytes, buf.length - pos);
          _carry = Uint8List.fromList(buf.sublist(buf.length - tailLen));
          return;
        }
        pos = synced.offset;
        _packetStride = synced.stride;
      }

      if (pos + _tsPacketSize > buf.length) {
        _carry = Uint8List.fromList(buf.sublist(pos));
        return;
      }

      if (buf[pos] != 0x47) {
        _packetStride = 0;
        continue;
      }

      _processTsPacket(buf, pos);
      final nextPos = pos + _packetStride;
      if (nextPos > buf.length) {
        _skipPrefixBytes = nextPos - buf.length;
        return;
      }
      pos = nextPos;
    }
  }

  ({int offset, int stride})? _detectSync(Uint8List buf, int start) {
    for (var i = start; i < buf.length; i++) {
      if (buf[i] != 0x47) continue;
      // Check 192-byte TTS before 188-byte TS because nasne streams are TTS.
      if (i + _ttsPacketSize * 2 < buf.length &&
          buf[i + _ttsPacketSize] == 0x47 &&
          buf[i + _ttsPacketSize * 2] == 0x47) {
        return (offset: i, stride: _ttsPacketSize);
      }
      if (i + _tsPacketSize * 2 < buf.length &&
          buf[i + _tsPacketSize] == 0x47 &&
          buf[i + _tsPacketSize * 2] == 0x47) {
        return (offset: i, stride: _tsPacketSize);
      }
    }
    return null;
  }

  void _processTsPacket(Uint8List buf, int tsOffset) {
    final b1 = buf[tsOffset + 1];
    if ((b1 & 0x80) != 0) return; // Transport error indicator.
    final pid = ((b1 & 0x1F) << 8) | buf[tsOffset + 2];
    final pusi = (b1 & 0x40) != 0;

    // Fast path: skip all irrelevant video/audio packets once origin PTS is set
    // (unless superimpose PID is active, in which case track latest A/V PTS).
    if (pid != 0 &&
        pid != _pmtPid &&
        pid != _captionPid &&
        pid != _superimposePid &&
        ((_firstStreamPtsSeconds != null && _superimposePid < 0) || !pusi)) {
      return;
    }

    final afc = (buf[tsOffset + 3] >> 4) & 0x03;
    if ((afc & 0x01) == 0) return; // No payload.

    var payloadRel = 4;
    if ((afc & 0x02) != 0) {
      final adapLen = buf[tsOffset + 4];
      payloadRel = 5 + adapLen;
      if (payloadRel >= _tsPacketSize) return;
    }

    final pStart = tsOffset + payloadRel;
    final pEnd = tsOffset + _tsPacketSize;
    final payloadLen = pEnd - pStart;
    if (payloadLen <= 0) return;

    if (pid == 0) {
      _feedPsi(buf, pStart, pEnd, pusi, isPat: true);
      return;
    }
    if (pid == _pmtPid) {
      _feedPsi(buf, pStart, pEnd, pusi, isPat: false);
      return;
    }
    if (pid == _captionPid) {
      _feedCaptionPesSlice(buf, pStart, pEnd, pusi);
      return;
    }
    if (pid == _superimposePid) {
      _feedSuperimposePesSlice(buf, pStart, pEnd, pusi);
      return;
    }

    // Record initial A/V stream PTS as anchor and update latest PTS for
    // headerless superimpose packets (`stream_id=0xBF`).
    if ((_firstStreamPtsSeconds == null || _superimposePid >= 0) &&
        pusi &&
        payloadLen >= 14) {
      if (buf[pStart] == 0x00 &&
          buf[pStart + 1] == 0x00 &&
          buf[pStart + 2] == 0x01) {
        final streamId = buf[pStart + 3];
        if (streamId >= 0xC0 && streamId <= 0xEF && (buf[pStart + 7] & 0x80) != 0) {
          final pts = _decodePtsSeconds(buf, pStart + 9);
          _firstStreamPtsSeconds ??= pts;
          _lastAvPtsSeconds = pts;
        }
      }
    }
  }

  void _feedPsi(
    Uint8List buf,
    int pStart,
    int pEnd,
    bool pusi, {
    required bool isPat,
  }) {
    var cursor = pStart;
    if (pusi) {
      if (cursor >= pEnd) return;
      final pointer = buf[cursor];
      cursor += 1 + pointer;
      if (cursor + 3 > pEnd) return;
      final secLen = ((buf[cursor + 1] & 0x0F) << 8) | buf[cursor + 2];
      final expected = 3 + secLen;
      if (expected < 8 || expected > _maxPsiBytes) return;
      final builder = BytesBuilder(copy: false)
        ..add(Uint8List.sublistView(buf, cursor, math.min(pEnd, cursor + expected)));
      if (isPat) {
        _patSection = builder;
        _patExpectedLen = expected;
      } else {
        _pmtSection = builder;
        _pmtExpectedLen = expected;
      }
    } else {
      final builder = isPat ? _patSection : _pmtSection;
      final expected = isPat ? _patExpectedLen : _pmtExpectedLen;
      if (builder == null || expected <= 0) return;
      final remaining = expected - builder.length;
      if (remaining > 0) {
        builder.add(Uint8List.sublistView(buf, cursor, math.min(pEnd, cursor + remaining)));
      }
    }

    final active = isPat ? _patSection : _pmtSection;
    final expectedLen = isPat ? _patExpectedLen : _pmtExpectedLen;
    if (active == null || active.length < expectedLen) return;
    final section = active.takeBytes();
    if (isPat) {
      _patSection = null;
      _patExpectedLen = 0;
      _parsePat(section);
    } else {
      _pmtSection = null;
      _pmtExpectedLen = 0;
      _parsePmt(section);
    }
  }

  void _parsePat(Uint8List section) {
    if (section.length < 12 || section[0] != 0x00) return;
    final end = section.length - 4; // Exclude CRC_32.
    for (var i = 8; i + 4 <= end; i += 4) {
      final programNumber = (section[i] << 8) | section[i + 1];
      if (programNumber == 0) continue; // NIT PID.
      _pmtPid = ((section[i + 2] & 0x1F) << 8) | section[i + 3];
      return;
    }
  }

  void _parsePmt(Uint8List section) {
    if (section.length < 16 || section[0] != 0x02) return;
    final end = section.length - 4;
    final programInfoLen = ((section[10] & 0x0F) << 8) | section[11];
    var i = 12 + programInfoLen;
    while (i + 5 <= end) {
      final streamType = section[i];
      final esPid = ((section[i + 1] & 0x1F) << 8) | section[i + 2];
      final esInfoLen = ((section[i + 3] & 0x0F) << 8) | section[i + 4];
      final descStart = i + 5;
      final descEnd = math.min(end, descStart + esInfoLen);

      if (streamType == 0x06) {
        var isAribCaption = false;
        var isAribSuperimpose = false;
        var componentTag = 0xFE;
        var superimposeTag = 0xFE;
        var d = descStart;
        while (d + 2 <= descEnd) {
          final tag = section[d];
          final dLen = section[d + 1];
          final dData = d + 2;
          if (dData + dLen > descEnd) break;
          if (tag == 0xFD && dLen >= 2) {
            final dataCompId = (section[dData] << 8) | section[dData + 1];
            if (dataCompId == 0x0008 || dataCompId == 0x0012) {
              isAribCaption = true;
            }
          } else if (tag == 0x52 && dLen >= 1) {
            final cTag = section[dData];
            // ARIB TR-B14 caption component tags: 0x30..0x37 (0x87 = 1seg),
            // superimpose component tags: 0x38..0x3F.
            if ((cTag >= 0x30 && cTag <= 0x37) || cTag == 0x87) {
              isAribCaption = true;
              componentTag = cTag;
            } else if (cTag >= 0x38 && cTag <= 0x3F) {
              isAribSuperimpose = true;
              superimposeTag = cTag;
            }
          }
          d = dData + dLen;
        }
        if (isAribSuperimpose) {
          isAribCaption = false;
          if (_superimposePid < 0 || superimposeTag < _superimposeComponentTag) {
            _superimposePid = esPid;
            _superimposeComponentTag = superimposeTag;
          }
        }
        if (isAribCaption &&
            (_captionPid < 0 || componentTag < _captionComponentTag)) {
          _captionPid = esPid;
          _captionComponentTag = componentTag;
        }
      }
      i = descEnd;
    }
  }

  void _feedCaptionPesSlice(Uint8List buf, int pStart, int pEnd, bool pusi) {
    if (pusi) {
      _flushCaptionPes();
      if (pEnd - pStart < 9) return;
      if (buf[pStart] != 0x00 ||
          buf[pStart + 1] != 0x00 ||
          buf[pStart + 2] != 0x01 ||
          buf[pStart + 3] != 0xBD) {
        return;
      }
      final pesPacketLen = (buf[pStart + 4] << 8) | buf[pStart + 5];
      final flags2 = buf[pStart + 7];
      final hdrDataLen = buf[pStart + 8];
      final pesPayloadOff = pStart + 9 + hdrDataLen;
      double? ptsSeconds;
      if ((flags2 & 0x80) != 0 && pStart + 14 <= pEnd && hdrDataLen >= 5) {
        ptsSeconds = _decodePtsSeconds(buf, pStart + 9);
      }
      if (pesPayloadOff > pEnd) return;
      final expectedPayload = pesPacketLen > (3 + hdrDataLen)
          ? pesPacketLen - 3 - hdrDataLen
          : 0;
      _captionPesPtsSeconds = ptsSeconds;
      _captionExpectedPayloadBytes = expectedPayload;
      _captionPes = BytesBuilder(copy: false)
        ..add(Uint8List.sublistView(buf, pesPayloadOff, pEnd));
      _maybeFlushCompletePes();
      return;
    }

    final pes = _captionPes;
    if (pes == null) return;
    if (pes.length + (pEnd - pStart) > _maxPesBytes) {
      _captionPes = null;
      _captionPesPtsSeconds = null;
      _captionExpectedPayloadBytes = 0;
      return;
    }
    pes.add(Uint8List.sublistView(buf, pStart, pEnd));
    _maybeFlushCompletePes();
  }

  void _maybeFlushCompletePes() {
    final pes = _captionPes;
    if (pes == null) return;
    if (_captionExpectedPayloadBytes > 0 &&
        pes.length >= _captionExpectedPayloadBytes) {
      _flushCaptionPes();
    }
  }

  void _flushCaptionPes() {
    final pes = _captionPes;
    final pts = _captionPesPtsSeconds;
    final expectedLen = _captionExpectedPayloadBytes;
    _captionPes = null;
    _captionPesPtsSeconds = null;
    _captionExpectedPayloadBytes = 0;
    if (pes == null) return;
    var payload = pes.takeBytes();
    if (expectedLen > 0 && payload.length > expectedLen) {
      payload = Uint8List.sublistView(payload, 0, expectedLen);
    }
    final event = _parseCaptionPesPayload(
      payload,
      ptsSeconds: pts ?? 0.0,
      drcsGlyphs: _drcsGlyphs,
    );
    if (pts != null && event != null) {
      final dupIdx = _events.indexWhere(
        (e) =>
            (e.ptsSeconds - event.ptsSeconds).abs() < 0.02 &&
            e.isClearOnly == event.isClearOnly,
      );
      if (dupIdx >= 0) {
        _events[dupIdx] = event;
      } else {
        _events.add(event);
        if (_events.length > _maxBufferedEvents) {
          _events.removeRange(0, _events.length - _maxBufferedEvents);
        }
      }
    }
  }

  void _feedSuperimposePesSlice(Uint8List buf, int pStart, int pEnd, bool pusi) {
    if (pusi) {
      _flushSuperimposePes();
      if (pEnd - pStart < 6) return;
      if (buf[pStart] != 0x00 ||
          buf[pStart + 1] != 0x00 ||
          buf[pStart + 2] != 0x01) {
        return;
      }
      final streamId = buf[pStart + 3];
      final pesPacketLen = (buf[pStart + 4] << 8) | buf[pStart + 5];
      final int pesPayloadOff;
      final int expectedPayload;
      double? ptsSeconds;
      if (streamId == 0xBF) {
        // ARIB STD-B24 superimpose uses private_stream_2 (no optional PES header/PTS).
        pesPayloadOff = pStart + 6;
        expectedPayload = pesPacketLen;
        ptsSeconds = _lastAvPtsSeconds ?? _firstStreamPtsSeconds ?? 0.0;
      } else if (streamId == 0xBD) {
        if (pEnd - pStart < 9) return;
        final flags2 = buf[pStart + 7];
        final hdrDataLen = buf[pStart + 8];
        pesPayloadOff = pStart + 9 + hdrDataLen;
        expectedPayload = pesPacketLen > (3 + hdrDataLen)
            ? pesPacketLen - 3 - hdrDataLen
            : 0;
        if ((flags2 & 0x80) != 0 && pStart + 14 <= pEnd && hdrDataLen >= 5) {
          ptsSeconds = _decodePtsSeconds(buf, pStart + 9);
        } else {
          ptsSeconds = _lastAvPtsSeconds ?? _firstStreamPtsSeconds ?? 0.0;
        }
      } else {
        return;
      }
      if (pesPayloadOff > pEnd) return;
      _superimposePesPtsSeconds = ptsSeconds;
      _superimposeExpectedPayloadBytes = expectedPayload;
      _superimposePes = BytesBuilder(copy: false)
        ..add(Uint8List.sublistView(buf, pesPayloadOff, pEnd));
      _maybeFlushCompleteSuperimposePes();
      return;
    }

    final pes = _superimposePes;
    if (pes == null) return;
    if (pes.length + (pEnd - pStart) > _maxPesBytes) {
      _superimposePes = null;
      _superimposePesPtsSeconds = null;
      _superimposeExpectedPayloadBytes = 0;
      return;
    }
    pes.add(Uint8List.sublistView(buf, pStart, pEnd));
    _maybeFlushCompleteSuperimposePes();
  }

  void _maybeFlushCompleteSuperimposePes() {
    final pes = _superimposePes;
    if (pes == null) return;
    if (_superimposeExpectedPayloadBytes > 0 &&
        pes.length >= _superimposeExpectedPayloadBytes) {
      _flushSuperimposePes();
    }
  }

  void _flushSuperimposePes() {
    final pes = _superimposePes;
    final pts = _superimposePesPtsSeconds;
    final expectedLen = _superimposeExpectedPayloadBytes;
    _superimposePes = null;
    _superimposePesPtsSeconds = null;
    _superimposeExpectedPayloadBytes = 0;
    if (pes == null) return;
    var payload = pes.takeBytes();
    if (expectedLen > 0 && payload.length > expectedLen) {
      payload = Uint8List.sublistView(payload, 0, expectedLen);
    }
    final nextSeq = _superimposeSeqCounter + 1;
    final event = _parseCaptionPesPayload(
      payload,
      ptsSeconds: pts ?? 0.0,
      drcsGlyphs: _superimposeDrcsGlyphs,
      isSuperimpose: true,
      sequence: nextSeq,
      receivedAt: DateTime.now(),
    );
    if (event != null) {
      _superimposeSeqCounter = nextSeq;
      _superimposeEvents.add(event);
      if (_superimposeEvents.length > _maxSuperimposeEvents) {
        _superimposeEvents.removeRange(
          0,
          _superimposeEvents.length - _maxSuperimposeEvents,
        );
      }
    }
  }

  static double _decodePtsSeconds(Uint8List buf, int off) {
    final p0 = buf[off];
    final p1 = buf[off + 1];
    final p2 = buf[off + 2];
    final p3 = buf[off + 3];
    final p4 = buf[off + 4];
    final pts90k =
        (((p0 & 0x0E) >> 1) << 30) |
        (p1 << 22) |
        ((p2 >> 1) << 15) |
        (p3 << 7) |
        (p4 >> 1);
    return pts90k / 90000.0;
  }

  /// Namespaced cache key for 1-byte DRCS characters (`DRCS-1..15`, `0x41..0x4F`).
  static int drcsOneByteKey(int setFinalByte, int code7Bit) =>
      0x10000 | ((setFinalByte & 0x7F) << 8) | (code7Bit & 0x7F);

  /// Namespaced cache key for 2-byte DRCS characters (`DRCS-0`).
  static int drcsTwoByteKey(int code16) => 0x20000 | (code16 & 0x7F7F);

  /// Bits per pixel for uncompressed ARIB DRCS bitmap (`mode == 0` or `1`).
  static int drcsBitsPerPixel(int mode, int depth) {
    if (mode == 0) return 1;
    final gradations = depth + 2;
    if (gradations <= 2) return 1;
    if (gradations <= 4) return 2;
    if (gradations <= 16) return 4;
    return 8;
  }

  /// Parses an ARIB STD-B24 DRCS data unit (`0x30` 1-byte or `0x31` 2-byte)
  /// and caches decoded uncompressed glyph bitmaps in [out].
  static void parseAribDrcsDataUnit(
    Uint8List data, {
    required bool isTwoByte,
    required Map<int, AribDrcsGlyph> out,
  }) {
    if (data.isEmpty) return;
    final numberOfCode = data[0];
    var off = 1;
    for (var c = 0; c < numberOfCode; c++) {
      if (off + 3 > data.length) break;
      final charCode = (data[off] << 8) | data[off + 1];
      final numberOfFont = data[off + 2];
      off += 3;
      final key = isTwoByte
          ? drcsTwoByteKey(charCode)
          : (0x10000 | (charCode & 0x7F7F));
      var storedFont0 = false;
      for (var f = 0; f < numberOfFont; f++) {
        if (off >= data.length) break;
        final fontAndMode = data[off++];
        final fontId = (fontAndMode >> 4) & 0x0F;
        final mode = fontAndMode & 0x0F;
        if (mode == 0x00 || mode == 0x01) {
          if (off + 3 > data.length) return;
          final depth = data[off++];
          final width = data[off++];
          final height = data[off++];
          final bpp = drcsBitsPerPixel(mode, depth);
          final totalBits = width * height * bpp;
          final byteLen = (totalBits + 7) >> 3;
          if (off + byteLen > data.length) return;
          if (width > 0 && height > 0 && (fontId == 0 || !storedFont0)) {
            final pixelCount = width * height;
            final levels = Uint8List(pixelCount);
            final mask = (1 << bpp) - 1;
            var bitPos = 0;
            for (var p = 0; p < pixelCount; p++) {
              final byteIdx = off + (bitPos >> 3);
              final bitInByte = bitPos & 0x07;
              final word =
                  (data[byteIdx] << 8) |
                  (byteIdx + 1 < data.length ? data[byteIdx + 1] : 0);
              final shift = 16 - bpp - bitInByte;
              levels[p] = (word >> shift) & mask;
              bitPos += bpp;
            }
            final glyph = AribDrcsGlyph.fromLevels(
              width: width,
              height: height,
              maxLevel: mask,
              levels: levels,
            );
            out.remove(key);
            out[key] = glyph;
            while (out.length > _maxDrcsGlyphs) {
              out.remove(out.keys.first);
            }
            if (fontId == 0) storedFont0 = true;
          }
          off += byteLen;
        } else {
          if (off + 4 > data.length) return;
          final geoLen = (data[off + 2] << 8) | data[off + 3];
          off += 4 + geoLen;
          if (off > data.length) return;
        }
      }
    }
  }

  static AribCaptionLayoutEvent? _parseCaptionPesPayload(
    Uint8List payload, {
    required double ptsSeconds,
    Map<int, AribDrcsGlyph>? drcsGlyphs,
    bool isSuperimpose = false,
    int sequence = 0,
    DateTime? receivedAt,
  }) {
    if (payload.length < 10) return null;
    final dataIdentifier = payload[0];
    final privateStreamId = payload[1];
    // 0x80 = synchronized closed caption PES, 0x81 = superimpose PES,
    // 0xFF = private stream marker.
    final expectedDataId = isSuperimpose ? 0x81 : 0x80;
    if (dataIdentifier != expectedDataId || privateStreamId != 0xFF) return null;
    final pesPrivateLen = payload[2] & 0x0F;
    var off = 3 + pesPrivateLen;
    if (off + 6 > payload.length) return null;

    final dataGroupId = (payload[off] >> 2) & 0x3F;
    final groupType = dataGroupId & 0x1F;
    // Allow caption/superimpose management (0) & primary language statement (1).
    if (groupType != 0 && groupType != 1) return null;

    off += 5; // data_group_id+version(1), link(1), last_link(1), size(2)
    final activeDrcs = drcsGlyphs ?? <int, AribDrcsGlyph>{};

    if (groupType == 0) {
      if (off + 2 > payload.length) return null;
      final tmd = (payload[off++] >> 6) & 0x03;
      if (tmd == 0x02) {
        off += 5; // OTM(36 bits) + reserved(4 bits)
      }
      if (off >= payload.length) return null;
      final numLanguages = payload[off++];
      for (var l = 0; l < numLanguages; l++) {
        if (off >= payload.length) return null;
        final dmf = payload[off++] & 0x0F;
        if (dmf == 0x0C || dmf == 0x0D || dmf == 0x0E) {
          off += 1; // DC
        }
        off += 4; // ISO_639_language_code(3B) + Format/TCS/rollup_mode(1B)
        if (off > payload.length) return null;
      }
      if (off + 3 > payload.length) return null;
      final loopLen =
          (payload[off] << 16) | (payload[off + 1] << 8) | payload[off + 2];
      off += 3;
      final loopEnd = math.min(payload.length, off + loopLen);
      var u = off;
      while (u + 5 <= loopEnd) {
        if (payload[u] != 0x1F) break;
        final unitParam = payload[u + 1];
        final unitSize =
            (payload[u + 2] << 16) | (payload[u + 3] << 8) | payload[u + 4];
        u += 5;
        if (u + unitSize > loopEnd) break;
        if ((unitParam == 0x30 || unitParam == 0x31) && unitSize > 0) {
          parseAribDrcsDataUnit(
            Uint8List.sublistView(payload, u, u + unitSize),
            isTwoByte: unitParam == 0x31,
            out: activeDrcs,
          );
        }
        u += unitSize;
      }
      return null;
    }

    if (off + 4 > payload.length) return null;
    final tmd = (payload[off] >> 6) & 0x03;
    off += 1;
    if (tmd == 0x01 || tmd == 0x02) {
      off += 5; // STM(36 bits) + reserved(4 bits)
    }
    if (off + 3 > payload.length) return null;
    final loopLen =
        (payload[off] << 16) | (payload[off + 1] << 8) | payload[off + 2];
    off += 3;
    final loopEnd = math.min(payload.length, off + loopLen);

    final statementBytes = BytesBuilder(copy: false);
    var u = off;
    while (u + 5 <= loopEnd) {
      if (payload[u] != 0x1F) break;
      final unitParam = payload[u + 1];
      final unitSize =
          (payload[u + 2] << 16) | (payload[u + 3] << 8) | payload[u + 4];
      u += 5;
      if (u + unitSize > loopEnd) break;
      if ((unitParam == 0x30 || unitParam == 0x31) && unitSize > 0) {
        parseAribDrcsDataUnit(
          Uint8List.sublistView(payload, u, u + unitSize),
          isTwoByte: unitParam == 0x31,
          out: activeDrcs,
        );
      } else if (unitParam == 0x20 && unitSize > 0) {
        statementBytes.add(Uint8List.sublistView(payload, u, u + unitSize));
      }
      u += unitSize;
    }

    final body = statementBytes.takeBytes();
    if (body.isEmpty) return null;
    return parseAribStatementBody(
      body,
      ptsSeconds: ptsSeconds,
      drcsGlyphs: activeDrcs,
      isSuperimpose: isSuperimpose,
      sequence: sequence,
      receivedAt: receivedAt,
    );
  }

  /// Parses an ARIB STD-B24 caption/superimpose statement body
  /// (`data_unit_parameter == 0x20`) into positioned character line bounds and
  /// timed clear markers.
  static AribCaptionLayoutEvent? parseAribStatementBody(
    Uint8List body, {
    required double ptsSeconds,
    Map<int, AribDrcsGlyph>? drcsGlyphs,
    bool isSuperimpose = false,
    int sequence = 0,
    DateTime? receivedAt,
  }) {
    // Default Profile A writing plane & character geometry (960x540).
    var planeW = 960.0;
    var planeH = 540.0;
    var dispLeft = 170.0;
    var dispTop = 30.0;
    var dispRight = dispLeft + 620.0;

    var fontW = 36.0;
    var fontH = 36.0;
    var horInt = 4.0;
    var verInt = 24.0;

    var curFontW = fontW;
    var curFontH = fontH;
    var curHorInt = horInt;
    var curVerInt = verInt;
    var isRuby = false;

    double charStepX() => math.max(1.0, curFontW + curHorInt);
    double charStepY() => math.max(1.0, curFontH + curVerInt);

    var curX = dispLeft;
    var curY = dispTop + charStepY() - 1.0;
    var hasExplicitCursorPos = false;

    // ISO-2022 state: G0=Kanji(2B), G1=Alnum(1B), G2=Hiragana(1B), G3=Macro(1B).
    final gBytes = [2, 1, 1, 1];
    final gFinal = [0x42, 0x4A, 0x30, 0x70];
    final gIsMosaic = [false, false, false, false];
    final gIsDrcs = [false, false, false, false];
    var g3IsMacro = true;
    var gl = 0;
    var gr = 2;
    int? singleShift;
    var repeatCount = 1;
    var curColorArgb = 0xFFFFFFFF;
    int? curBgColorArgb;
    int? rasterColorArgb;
    int? builtinSoundId;
    var colPalette = 0;

    var hasClear = false;
    var startsWithClear = false;
    var timeWaitSeconds = 0.0;
    double? clearAfterSeconds;
    final lines = <_MutableLineBucket>[];

    void recordVisibleGlyph(
      double width,
      String text, {
      AribDrcsGlyph? drcsGlyph,
    }) {
      if (curX >= dispRight && width > 0) {
        curX = dispLeft;
        curY += charStepY();
      }
      final glyphStartX = curX;
      final glyphEndX = curX + width;
      curX = glyphEndX;
      if (isRuby) return;

      final baselineY = curY;
      final centerY = (curY - curFontH * 0.5).clamp(0.0, planeH).toDouble();
      final threshold = math.max(10.0, (fontH + verInt) * 0.45);
      _MutableLineBucket? target;
      for (final bucket in lines) {
        if ((bucket.baselineY - baselineY).abs() <= threshold &&
            glyphStartX - bucket.maxEndX <= fontW * 3.0 &&
            bucket.minX - glyphEndX <= fontW * 3.0) {
          target = bucket;
          break;
        }
      }
      if (target == null) {
        target = _MutableLineBucket(
          baselineY: baselineY,
          centerY: centerY,
          minX: glyphStartX,
          maxEndX: glyphEndX,
          charCount: 1,
          backgroundColorArgb: isSuperimpose
              ? (curBgColorArgb ?? rasterColorArgb)
              : null,
        );
        lines.add(target);
      } else {
        if (glyphStartX - target.maxEndX >= fontW * 0.45) {
          target.pendingSpace = true;
        }
        if (glyphStartX < target.minX) target.minX = glyphStartX;
        if (glyphEndX > target.maxEndX) target.maxEndX = glyphEndX;
        target.charCount += 1;
        if (isSuperimpose && target.backgroundColorArgb == null) {
          target.backgroundColorArgb = curBgColorArgb ?? rasterColorArgb;
        }
      }
      target.appendText(text, curColorArgb, 1.0, drcsGlyph: drcsGlyph);
    }

    var i = 0;
    while (i < body.length) {
      final b = body[i];

      // --- C0 Controls (0x00..0x20) -----------------------------------------
      if (b < 0x20 || b == 0x20) {
        i++;
        switch (b) {
          case 0x08: // APB (active position backward)
            curX = math.max(dispLeft, curX - charStepX());
          case 0x09: // APF (active position forward)
            curX += charStepX();
          case 0x0A: // APD (active position down)
            curY += charStepY();
          case 0x0B: // APU (active position up)
            curY -= charStepY();
          case 0x0C: // CS (clear screen)
            hasClear = true;
            if (lines.isNotEmpty && timeWaitSeconds > 0.0) {
              clearAfterSeconds = timeWaitSeconds;
              // Do not discard already-placed cue layout; it lasts until timed CS.
              i = body.length;
              break;
            }
            lines.clear();
            startsWithClear = true;
            curX = dispLeft;
            curY = dispTop + charStepY() - 1.0;
            hasExplicitCursorPos = false;
          case 0x0D: // APR (active position return)
            curX = dispLeft;
            curY += charStepY();
          case 0x0E: // LS1
            gl = 1;
          case 0x0F: // LS0
            gl = 0;
          case 0x16: // PAPF
            if (i < body.length) {
              final count = body[i++] & 0x3F;
              curX += charStepX() * count;
            }
          case 0x19: // SS2
            singleShift = 2;
          case 0x1B: // ESC
            if (i >= body.length) break;
            final e1 = body[i++];
            switch (e1) {
              case 0x6E:
                gl = 2;
              case 0x6F:
                gl = 3;
              case 0x7E:
                gr = 1;
              case 0x7D:
                gr = 2;
              case 0x7C:
                gr = 3;
              case 0x24: // 2-byte designation
                if (i >= body.length) break;
                final e2 = body[i++];
                if (e2 >= 0x28 && e2 <= 0x2B) {
                  final target = e2 - 0x28;
                  gBytes[target] = 2;
                  if (target == 3) g3IsMacro = false;
                  if (i < body.length && body[i] == 0x20) {
                    i++;
                    gFinal[target] = i < body.length ? body[i++] : 0x40;
                    gIsMosaic[target] = false;
                    gIsDrcs[target] = true;
                  } else if (i < body.length) {
                    final fin = body[i++];
                    gFinal[target] = fin;
                    gIsDrcs[target] = false;
                    gIsMosaic[target] = fin >= 0x32 && fin <= 0x35;
                  }
                } else if (e2 == 0x20) {
                  gBytes[0] = 2;
                  gFinal[0] = i < body.length ? body[i++] : 0x40;
                  gIsMosaic[0] = false;
                  gIsDrcs[0] = true;
                } else {
                  gBytes[0] = 2;
                  gFinal[0] = e2;
                  gIsDrcs[0] = false;
                  gIsMosaic[0] = e2 >= 0x32 && e2 <= 0x35;
                }
              default:
                if (e1 >= 0x28 && e1 <= 0x2B) {
                  final target = e1 - 0x28;
                  if (i < body.length && body[i] == 0x20) {
                    // 1-byte DRCS
                    i++;
                    gBytes[target] = 1;
                    gFinal[target] = i < body.length ? body[i++] : 0x41;
                    gIsMosaic[target] = false;
                    gIsDrcs[target] = true;
                    if (target == 3) g3IsMacro = false;
                  } else if (i < body.length) {
                    final fin = body[i++];
                    gBytes[target] = _isTwoByteFinal(fin) ? 2 : 1;
                    gFinal[target] = fin;
                    gIsDrcs[target] = false;
                    gIsMosaic[target] = fin >= 0x32 && fin <= 0x35;
                    if (target == 3) g3IsMacro = fin == 0x70;
                  }
                }
            }
          case 0x1C: // APS (active position set: row, col)
            if (i + 1 < body.length) {
              final row = body[i++] & 0x3F;
              final col = body[i++] & 0x3F;
              curX = dispLeft + col * charStepX();
              curY = dispTop + (row + 1) * charStepY() - 1.0;
              hasExplicitCursorPos = true;
            }
          case 0x1D: // SS3
            singleShift = 3;
          case 0x20: // SP
            curX += charStepX() * repeatCount;
            repeatCount = 1;
          default:
            break;
        }
        continue;
      }

      // --- C1 Controls (0x80..0xA0) -----------------------------------------
      if (b >= 0x80 && b <= 0xA0) {
        i++;
        if (b >= 0x80 && b <= 0x87) {
          curColorArgb = _aribClutColorArgb(b - 0x80);
          continue;
        }
        switch (b) {
          case 0x88: // SSZ (half-width & half-height; ruby/small)
            curFontW = fontW / 2.0;
            curFontH = fontH / 2.0;
            curHorInt = horInt / 2.0;
            curVerInt = verInt / 2.0;
            isRuby = true;
          case 0x89: // MSZ (half-width)
            curFontW = fontW / 2.0;
            curFontH = fontH;
            curHorInt = horInt / 2.0;
            curVerInt = verInt;
            isRuby = false;
          case 0x8A: // NSZ (normal size)
            curFontW = fontW;
            curFontH = fontH;
            curHorInt = horInt;
            curVerInt = verInt;
            isRuby = false;
          case 0x8B: // SZX
            if (i < body.length) {
              final sz = body[i++];
              isRuby = sz == 0x60;
              if (sz == 0x41) {
                curFontW = fontW;
                curFontH = fontH * 2.0;
              } else if (sz == 0x44) {
                curFontW = fontW * 2.0;
                curFontH = fontH;
              } else if (sz == 0x45) {
                curFontW = fontW * 2.0;
                curFontH = fontH * 2.0;
              }
            }
          case 0x90: // COL
            if (i < body.length) {
              if (body[i] == 0x20 && i + 1 < body.length) {
                colPalette = body[i + 1] & 0x07;
                i += 2;
              } else {
                final p = body[i++];
                if (p >= 0x40 && p <= 0x4F) {
                  curColorArgb = _aribClutColorArgb(
                    ((colPalette & 0x0F) << 4) | (p - 0x40),
                  );
                } else if (p >= 0x50 && p <= 0x5F) {
                  curBgColorArgb = _aribClutBackgroundColorArgb(
                    colPalette,
                    p - 0x50,
                  );
                }
              }
            }
          case 0x92: // CDC
            if (i < body.length) {
              if (body[i] == 0x20 && i + 1 < body.length) {
                i += 2;
              } else {
                i += 1;
              }
            }
          case 0x91: // FLC
          case 0x93: // POL
          case 0x94: // WMM
          case 0x97: // HLC
            if (i < body.length) i++;
          case 0x98: // RPC
            if (i < body.length) {
              final p = body[i++] & 0x3F;
              repeatCount = p == 0 ? 1 : p;
            }
          case 0x95: // MACRO (terminated by 0x4F)
            while (i < body.length && body[i] != 0x4F) {
              i++;
            }
            if (i < body.length) i++;
          case 0x9B: // CSI
            final params = <int>[];
            var curParam = 0;
            var hasDigits = false;
            var finalByte = 0;
            while (i < body.length) {
              final cb = body[i++];
              if (cb >= 0x30 && cb <= 0x39) {
                curParam = curParam * 10 + (cb - 0x30);
                hasDigits = true;
              } else if (cb == 0x3B) {
                params.add(hasDigits ? curParam : 0);
                curParam = 0;
                hasDigits = false;
              } else if (cb >= 0x40 && cb <= 0x7F) {
                if (hasDigits) params.add(curParam);
                finalByte = cb;
                break;
              }
            }
            switch (finalByte) {
              case 0x53: // SWF (Set Writing Format)
                if (params.length == 1) {
                  switch (params[0]) {
                    case 5:
                    case 6:
                    case 9:
                    case 10:
                      planeW = 720.0;
                      planeH = 480.0;
                    case 7:
                    case 8:
                      planeW = 960.0;
                      planeH = 540.0;
                    case 11:
                    case 12:
                      planeW = 1920.0;
                      planeH = 1080.0;
                  }
                } else if (params.length >= 2 &&
                    params[0] >= 160 &&
                    params[1] >= 120) {
                  planeW = params[0].toDouble();
                  planeH = params[1].toDouble();
                }
              case 0x56: // SDF (Set Display Format)
                if (params.length >= 2 && params[0] > 0 && params[1] > 0) {
                  dispRight = dispLeft + params[0].toDouble();
                }
              case 0x5F: // SDP (Set Display Position)
                if (params.length >= 2) {
                  final oldW = math.max(1.0, dispRight - dispLeft);
                  dispLeft = params[0].toDouble();
                  dispTop = params[1].toDouble();
                  dispRight = dispLeft + oldW;
                  if (lines.isEmpty) {
                    curX = dispLeft;
                    curY = dispTop + charStepY() - 1.0;
                    hasExplicitCursorPos = false;
                  }
                }
              case 0x57: // SSM (Character Composition Dot Designation)
                if (params.length >= 2 && params[0] > 0 && params[1] > 0) {
                  fontW = params[0].toDouble();
                  fontH = params[1].toDouble();
                  curFontW = fontW;
                  curFontH = fontH;
                  if (lines.isEmpty && !hasExplicitCursorPos) {
                    curY = dispTop + charStepY() - 1.0;
                  }
                }
              case 0x58: // SHS (Set Horizontal Spacing)
                if (params.isNotEmpty) {
                  horInt = params[0].toDouble();
                  curHorInt = horInt;
                }
              case 0x59: // SVS (Set Vertical Spacing)
                if (params.isNotEmpty) {
                  verInt = params[0].toDouble();
                  curVerInt = verInt;
                  if (lines.isEmpty && !hasExplicitCursorPos) {
                    curY = dispTop + charStepY() - 1.0;
                  }
                }
              case 0x61: // ACPS (Active Coordinate Position Set)
                if (params.length >= 2) {
                  curX = params[0].toDouble();
                  curY = params[1].toDouble();
                  hasExplicitCursorPos = true;
                }
              case 0x68: // PRA (Play Built-in Sound)
                if (params.isNotEmpty) {
                  builtinSoundId = params.first;
                }
              case 0x6E: // RCS (Raster Colour Command)
                if (params.isNotEmpty) {
                  rasterColorArgb = _aribClutBackgroundColorArgb(
                    colPalette,
                    params.first,
                  );
                }
            }
          case 0x9D: // TIME
            if (i < body.length) {
              final mode = body[i++];
              if (mode == 0x20 && i < body.length) {
                final val = body[i++];
                if (val >= 0x40 && val <= 0x7F) {
                  timeWaitSeconds += (val & 0x3F) * 0.1;
                }
              } else {
                while (i < body.length) {
                  final tb = body[i++];
                  if (tb >= 0x40 && tb <= 0x7F) break;
                }
              }
            }
          case 0xA0: // 8-bit nbsp
            curX += charStepX() * repeatCount;
            repeatCount = 1;
          default:
            break;
        }
        continue;
      }

      // --- Graphic Characters (GL 0x21..0x7E / GR 0xA1..0xFE) ----------------
      final area = singleShift ?? (b >= 0xA1 ? gr : gl);
      singleShift = null;
      final byteCount = gBytes[area];
      final finalByte = gFinal[area];
      final isMosaic = gIsMosaic[area];
      final isDrcs = gIsDrcs[area];
      final first = b & 0x7F;
      var second = 0;
      i++;
      if (area == 3 && g3IsMacro && first >= 0x60 && first <= 0x6F) {
        _applyAribDefaultMacro(
          first,
          gBytes: gBytes,
          gFinal: gFinal,
          gIsMosaic: gIsMosaic,
          gIsDrcs: gIsDrcs,
        );
        g3IsMacro = true;
        gl = 0;
        gr = 2;
        repeatCount = 1;
        continue;
      }
      if (byteCount == 2) {
        if (i >= body.length) break;
        second = body[i++] & 0x7F;
        if (second < 0x21) continue;
      }

      final isSpaceCell =
          !isDrcs &&
          ((byteCount == 2 && first == 0x21 && second == 0x21) ||
              (byteCount == 1 && first == 0x20));
      final count = repeatCount;
      repeatCount = 1;
      String? decodedChar;
      AribDrcsGlyph? drcsGlyph;
      if (!isSpaceCell && !isMosaic) {
        if (isDrcs) {
          final key = byteCount == 2
              ? drcsTwoByteKey((first << 8) | second)
              : drcsOneByteKey(finalByte, first);
          drcsGlyph = drcsGlyphs?[key];
          decodedChar = drcsGlyph != null ? '\uFFFC' : '〓';
        } else if (byteCount == 2) {
          decodedChar = decodeAribB24TwoByteCell(
            (first << 8) | second,
            finalByte,
          );
        } else {
          decodedChar = decodeAribB24OneByteCell(
            first,
            finalByte,
            halfWidth: curFontW < fontW,
          );
        }
      }
      for (var r = 0; r < count; r++) {
        if (isSpaceCell || isMosaic) {
          curX += charStepX();
        } else {
          recordVisibleGlyph(
            charStepX(),
            decodedChar ?? '',
            drcsGlyph: drcsGlyph,
          );
        }
      }
    }

    if (lines.isEmpty) {
      if (!hasClear && builtinSoundId == null) return null;
      return AribCaptionLayoutEvent(
        ptsSeconds: ptsSeconds,
        planeWidth: planeW,
        planeHeight: planeH,
        lines: const [],
        isClearOnly: hasClear && builtinSoundId == null,
        startsWithClear: startsWithClear,
        builtinSoundId: builtinSoundId,
        sequence: sequence,
        receivedAt: receivedAt,
        isSuperimpose: isSuperimpose,
      );
    }

    lines.sort((a, b) {
      final yCmp = a.baselineY.compareTo(b.baselineY);
      if (yCmp != 0) return yCmp;
      return a.minX.compareTo(b.minX);
    });
    final safeW = planeW > 0 ? planeW : 960.0;
    final safeH = planeH > 0 ? planeH : 540.0;
    return AribCaptionLayoutEvent(
      ptsSeconds: ptsSeconds,
      planeWidth: safeW,
      planeHeight: safeH,
      lines: [
        for (final line in lines)
          AribCaptionLinePlacement(
            normalizedX: (line.minX / safeW).clamp(0.02, 0.90).toDouble(),
            normalizedY: (line.centerY / safeH).clamp(0.02, 0.98).toDouble(),
            endNormalizedX: (line.maxEndX / safeW).clamp(0.05, 0.98).toDouble(),
            charCount: line.charCount,
            runs: line.buildTrimmedRuns(),
            backgroundColorArgb: line.backgroundColorArgb,
          ),
      ],
      isClearOnly: false,
      clearAfterSeconds: clearAfterSeconds,
      startsWithClear: startsWithClear,
      builtinSoundId: builtinSoundId,
      sequence: sequence,
      receivedAt: receivedAt,
      isSuperimpose: isSuperimpose,
    );
  }

  static int? _aribClutBackgroundColorArgb(int palette, int index) {
    final idx = index & 0x0F;
    if (idx == 8) return null; // Fully transparent in ARIB CLUT.
    const rgbPalette = <int>[
      0x000000, // 0: black
      0xFF0000, // 1: red
      0x00FF00, // 2: green
      0xFFFF00, // 3: yellow
      0x0000FF, // 4: blue
      0xFF00FF, // 5: magenta
      0x00FFFF, // 6: cyan
      0xFFFFFF, // 7: white
      0x000000, // 8: transparent (handled above)
      0xAA0000, // 9: dark red
      0x00AA00, // 10: dark green
      0xAAAA00, // 11: dark yellow
      0x0D1B4A, // 12: dark blue (news flash banner)
      0xAA00AA, // 13: dark magenta
      0x00AAAA, // 14: dark cyan
      0x333333, // 15: dark gray
    ];
    final alpha = (palette & 0x07) >= 4 ? 0xCC : 0xEB;
    return (alpha << 24) | rgbPalette[idx];
  }

  static Map<String, int>? _kanjiReverseCache;

  static Map<String, int> _ensureKanjiReverseCache() {
    final existing = _kanjiReverseCache;
    if (existing != null) return existing;
    final map = <String, int>{};
    for (var row = 0x21; row <= 0x74; row++) {
      for (var cell = 0x21; cell <= 0x7E; cell++) {
        final code = (row << 8) | cell;
        final ch = decodeAribB24TwoByteCell(code, 0x42);
        if (ch.isNotEmpty && ch != '□') {
          map.putIfAbsent(ch, () => code);
        }
      }
    }
    _kanjiReverseCache = map;
    return map;
  }

  /// Builds valid 188-byte MPEG-TS packets (PAT + PMT with `ctag=0x38` +
  /// `stream_id=0xBF` / `data_identifier=0x81` superimpose PES) for unit tests
  /// and 16:9 settings preview verification.
  static Uint8List buildSyntheticSuperimposeTsPacket({
    required String text,
    int bgColorIndex = 1,
    int fgColorIndex = 7,
    int builtinSoundId = 4,
    double clearAfterSeconds = 6.0,
    int yPos = 70,
    int xPos = 340,
    int superimposePid = 0x0138,
    int pmtPid = 0x01F0,
    bool includePtsAv = true,
  }) {
    final reverse = _ensureKanjiReverseCache();
    final stmt = <int>[];

    void addCsi(List<int> params, int finalByte) {
      stmt.add(0x9B);
      for (var p = 0; p < params.length; p++) {
        if (p > 0) stmt.add(0x3B);
        for (final unit in '${params[p]}'.codeUnits) {
          stmt.add(unit);
        }
      }
      stmt.add(0x20);
      stmt.add(finalByte);
    }

    // Clear previous -> SWF 960x540 (7) -> SSM 36x36 -> ACPS (xPos, yPos)
    stmt.add(0x0C);
    addCsi([7], 0x53); // SWF 960x540
    addCsi([36, 36], 0x57); // SSM 36x36
    addCsi([xPos, yPos], 0x61); // ACPS
    if (builtinSoundId >= 0) {
      addCsi([builtinSoundId], 0x68); // PRA
    }
    // Foreground & Background color via COL
    stmt.addAll([0x90, 0x40 | (fgColorIndex & 0x0F)]);
    stmt.addAll([0x90, 0x50 | (bgColorIndex & 0x0F)]);

    // Encode text using G0 (2B Kanji)
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      if (ch == ' ') {
        stmt.addAll([0x21, 0x21]);
        continue;
      }
      final code = reverse[ch];
      if (code != null) {
        stmt.add((code >> 8) & 0xFF);
        stmt.add(code & 0xFF);
      } else {
        stmt.addAll([0x21, 0x21]);
      }
    }

    // Timed clear at end: TIME WAIT(t) + CS
    final tenths = (clearAfterSeconds * 10.0).round().clamp(1, 63);
    stmt.addAll([0x9D, 0x20, 0x40 | tenths, 0x0C]);

    // Data unit 0x20 (caption statement)
    final unitLen = stmt.length;
    final unit = <int>[
      0x1F,
      0x20,
      (unitLen >> 16) & 0xFF,
      (unitLen >> 8) & 0xFF,
      unitLen & 0xFF,
      ...stmt,
    ];

    // Data group (groupType=1 statement): TMD(0), loop_len(3) + unit
    final dgBody = <int>[
      0x00, // TMD = 00
      (unit.length >> 16) & 0xFF,
      (unit.length >> 8) & 0xFF,
      unit.length & 0xFF,
      ...unit,
    ];
    final dg = <int>[
      0x80 | (0x01 << 2), // data_group_id = 1
      0x00,
      0x00,
      (dgBody.length >> 8) & 0xFF,
      dgBody.length & 0xFF,
      ...dgBody,
    ];

    // Synchronized/superimpose PES payload: data_id=0x81, private=0xFF, hdrLen=0
    final pesPayload = <int>[0x81, 0xFF, 0xF0, ...dg];
    final pesPacket = <int>[
      0x00,
      0x00,
      0x01,
      0xBF, // private_stream_2
      (pesPayload.length >> 8) & 0xFF,
      pesPayload.length & 0xFF,
      ...pesPayload,
    ];

    final out = BytesBuilder(copy: false);

    List<int> wrapTsPackets(int pid, List<int> payload, {bool psi = false}) {
      final result = <int>[];
      var off = 0;
      var first = true;
      var cc = 0;
      while (off < payload.length || first) {
        final pkt = Uint8List(188)..fillRange(0, 188, 0xFF);
        pkt[0] = 0x47;
        pkt[1] = (first ? 0x40 : 0x00) | ((pid >> 8) & 0x1F);
        pkt[2] = pid & 0xFF;
        pkt[3] = 0x10 | (cc & 0x0F);
        cc = (cc + 1) & 0x0F;
        var pos = 4;
        if (first && psi) {
          pkt[pos++] = 0x00; // pointer_field
        }
        final take = math.min(188 - pos, payload.length - off);
        for (var k = 0; k < take; k++) {
          pkt[pos + k] = payload[off + k];
        }
        off += take;
        first = false;
        result.addAll(pkt);
        if (off >= payload.length) break;
      }
      return result;
    }

    // PAT (PID 0): program 1 -> pmtPid
    final patSec = <int>[
      0x00,
      0xB0,
      13, // section_length = 9 + 4 CRC
      0x00,
      0x01,
      0xC1,
      0x00,
      0x00,
      0x00,
      0x01,
      0xE0 | ((pmtPid >> 8) & 0x1F),
      pmtPid & 0xFF,
      0x00,
      0x00,
      0x00,
      0x00,
    ];
    out.add(wrapTsPackets(0x0000, patSec, psi: true));

    // PMT (pmtPid): stream_type 0x06 -> superimposePid with dcid=0x0008 + ctag=0x38
    final esDesc = <int>[
      0xFD,
      0x02,
      0x00,
      0x08, // data_component_descriptor
      0x52,
      0x01,
      0x38, // stream_identifier_descriptor ctag=0x38
    ];
    final pmtSecLen = 9 + 5 + esDesc.length + 4;
    final pmtSec = <int>[
      0x02,
      0xB0 | ((pmtSecLen >> 8) & 0x0F),
      pmtSecLen & 0xFF,
      0x00,
      0x01,
      0xC1,
      0x00,
      0x00,
      0xE1,
      0x00,
      0xF0,
      0x00, // program_info_length = 0
      0x06,
      0xE0 | ((superimposePid >> 8) & 0x1F),
      superimposePid & 0xFF,
      (esDesc.length >> 8) & 0x0F,
      esDesc.length & 0xFF,
      ...esDesc,
      0x00,
      0x00,
      0x00,
      0x00,
    ];
    out.add(wrapTsPackets(pmtPid, pmtSec, psi: true));

    if (includePtsAv) {
      // One minimal A/V PES packet with PTS = 10.0s (900000) so anchor is set.
      const pts90k = 900000;
      final avPes = <int>[
        0x00,
        0x00,
        0x01,
        0xE0,
        0x00,
        0x0A,
        0x80,
        0x80,
        0x05,
        0x21 | (((pts90k >> 30) & 0x07) << 1),
        (pts90k >> 22) & 0xFF,
        0x01 | (((pts90k >> 15) & 0x7F) << 1),
        (pts90k >> 7) & 0xFF,
        0x01 | ((pts90k & 0x7F) << 1),
        0x00,
        0x00,
      ];
      out.add(wrapTsPackets(0x0100, avPes));
    }

    // Superimpose PES packets
    out.add(wrapTsPackets(superimposePid, pesPacket));
    // Emit 2nd packet repeat of PAT/PMT? Not needed; single TS is 188B aligned.
    // Re-add PAT+PMT+AV if less than 3 packets? Feed handles 188B when 3 syncs exist;
    // ensure >= 3 TS packets total (we already have PAT + PMT + AV + Superimpose >= 4).
    return out.takeBytes();
  }

  static int _aribClutColorArgb(int index) {
    const clut = <int>[
      0xFFFFFFFF, // 0: BKF guarded to white for contrast on dark pills
      0xFFFF0000, // 1: RDF
      0xFF00FF00, // 2: GRF
      0xFFFFFF00, // 3: YLF
      0xFF0000FF, // 4: BLF
      0xFFFF00FF, // 5: MGF
      0xFF00FFFF, // 6: CNF
      0xFFFFFFFF, // 7: WHF
      0xFFFFFFFF, // 8: half black -> white
      0xFFFF6666, // 9: light red
      0xFF80FF80, // 10: light green
      0xFFFFFF80, // 11: light yellow
      0xFF80A0FF, // 12: light blue
      0xFFFF80FF, // 13: light magenta
      0xFF80FFFF, // 14: light cyan
      0xFFCCCCCC, // 15: light gray
    ];
    return clut[index & 0x0F];
  }

  static void _applyAribDefaultMacro(
    int macroByte, {
    required List<int> gBytes,
    required List<int> gFinal,
    required List<bool> gIsMosaic,
    required List<bool> gIsDrcs,
  }) {
    void setSlot(int slot, int bytes, int fin, {bool mosaic = false, bool drcs = false}) {
      gBytes[slot] = bytes;
      gFinal[slot] = fin;
      gIsMosaic[slot] = mosaic;
      gIsDrcs[slot] = drcs;
    }

    setSlot(3, 1, 0x70); // G3 = Macro
    switch (macroByte) {
      case 0x60:
        setSlot(0, 2, 0x42);
        setSlot(1, 1, 0x4A);
        setSlot(2, 1, 0x30);
      case 0x61:
        setSlot(0, 2, 0x42);
        setSlot(1, 1, 0x31);
        setSlot(2, 1, 0x30);
      case 0x62:
        setSlot(0, 2, 0x42);
        setSlot(1, 1, 0x41, drcs: true);
        setSlot(2, 1, 0x30);
      case 0x63:
        setSlot(0, 1, 0x32, mosaic: true);
        setSlot(1, 1, 0x33, mosaic: true);
        setSlot(2, 1, 0x34, mosaic: true);
      case 0x64:
        setSlot(0, 1, 0x32, mosaic: true);
        setSlot(1, 1, 0x35, mosaic: true);
        setSlot(2, 1, 0x34, mosaic: true);
      case 0x65:
        setSlot(0, 1, 0x32, mosaic: true);
        setSlot(1, 1, 0x4A);
        setSlot(2, 1, 0x30);
      case 0x66:
        setSlot(0, 1, 0x33, mosaic: true);
        setSlot(1, 1, 0x31);
        setSlot(2, 1, 0x30);
      case 0x67:
        setSlot(0, 1, 0x35, mosaic: true);
        setSlot(1, 1, 0x30);
        setSlot(2, 2, 0x42);
      case 0x68:
        setSlot(0, 1, 0x36);
        setSlot(1, 1, 0x34, mosaic: true);
        setSlot(2, 1, 0x35, mosaic: true);
      case 0x69:
        setSlot(0, 1, 0x37);
        setSlot(1, 1, 0x4A);
        setSlot(2, 1, 0x30);
      case 0x6A:
        setSlot(0, 1, 0x38);
        setSlot(1, 1, 0x31);
        setSlot(2, 2, 0x42);
      case 0x6B:
        setSlot(0, 2, 0x42);
        setSlot(1, 1, 0x41, drcs: true);
        setSlot(2, 1, 0x31);
      case 0x6C:
        setSlot(0, 2, 0x42);
        setSlot(1, 1, 0x42, drcs: true);
        setSlot(2, 1, 0x43, drcs: true);
      case 0x6D:
        setSlot(0, 2, 0x40, drcs: true);
        setSlot(1, 1, 0x41, drcs: true);
        setSlot(2, 1, 0x42, drcs: true);
      case 0x6E:
        setSlot(0, 2, 0x42);
        setSlot(1, 1, 0x30);
        setSlot(2, 1, 0x31);
      case 0x6F:
        setSlot(0, 1, 0x4A);
        setSlot(1, 1, 0x31);
        setSlot(2, 2, 0x42);
    }
  }

  static bool _isTwoByteFinal(int fin) =>
      fin == 0x42 || fin == 0x39 || fin == 0x3A || fin == 0x3B;
}
