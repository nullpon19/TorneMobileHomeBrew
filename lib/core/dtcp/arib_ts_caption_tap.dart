/// Lightweight MPEG-TS/TTS tap that extracts ARIB STD-B24 caption layout
/// coordinates (`SWF`/`SDF`/`SDP`/`ACPS`/`APS`) and clear timing (`CS`/`TIME`)
/// directly from decrypted streams passing through `DtcpProxy`.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Horizontal & vertical bounds of one decoded ARIB caption text line.
class AribCaptionLinePlacement {
  const AribCaptionLinePlacement({
    required this.normalizedX,
    required this.normalizedY,
    required this.endNormalizedX,
    required this.charCount,
  });

  /// Normalized left edge (`0.0..1.0` across [AribCaptionLayoutEvent.planeWidth]).
  final double normalizedX;

  /// Normalized vertical center (`0.0..1.0` across [AribCaptionLayoutEvent.planeHeight]).
  final double normalizedY;

  /// Normalized right edge of the last non-space character on this line.
  final double endNormalizedX;

  /// Number of visible characters measured on this line.
  final int charCount;
}

/// Decoded caption positioning and timing metadata extracted from one ARIB PES.
class AribCaptionLayoutEvent {
  const AribCaptionLayoutEvent({
    required this.ptsSeconds,
    required this.planeWidth,
    required this.planeHeight,
    required this.lines,
    required this.isClearOnly,
    this.clearAfterSeconds,
  });

  final double ptsSeconds;
  final double planeWidth;
  final double planeHeight;
  final List<AribCaptionLinePlacement> lines;
  final bool isClearOnly;
  final double? clearAfterSeconds;
}

class _MutableLineBucket {
  _MutableLineBucket({
    required this.baselineY,
    required this.centerY,
    required this.minX,
    required this.maxEndX,
    required this.charCount,
  });

  double baselineY;
  double centerY;
  double minX;
  double maxEndX;
  int charCount;
}

/// Parses MPEG-TS (`188` B) or MPEG-TTS (`192` B) plaintext byte slices on the
/// fly and retains a rolling ring buffer of recent [AribCaptionLayoutEvent]s.
class AribTsCaptionTap {
  static const int _tsPacketSize = 188;
  static const int _ttsPacketSize = 192;
  static const int _maxCarryBytes = _ttsPacketSize * 3;
  static const int _maxBufferedEvents = 400;
  static const int _maxPesBytes = 64 * 1024;
  static const int _maxPsiBytes = 4096;

  /// Roll-over period for 33-bit 90 kHz MPEG-TS timestamps (~26.5 hours).
  static const double ptsWrapSeconds = 8589934592.0 / 90000.0;

  Uint8List _carry = Uint8List(0);
  int _packetStride = 0; // 0 = unsynced, 188 = TS, 192 = TTS
  int _pmtPid = -1;
  int _captionPid = -1;
  int _captionComponentTag = 0xFF;
  double? _firstStreamPtsSeconds;

  BytesBuilder? _patSection;
  int _patExpectedLen = 0;
  BytesBuilder? _pmtSection;
  int _pmtExpectedLen = 0;

  BytesBuilder? _captionPes;
  double? _captionPesPtsSeconds;
  int _captionExpectedPayloadBytes = 0;

  final List<AribCaptionLayoutEvent> _events = [];

  List<AribCaptionLayoutEvent> get events => List<AribCaptionLayoutEvent>.unmodifiable(_events);
  double? get firstStreamPtsSeconds => _firstStreamPtsSeconds;
  int? get captionPid => _captionPid >= 0 ? _captionPid : null;

  /// Resets framing and partial PES buffers across seek jumps while preserving
  /// discovered PIDs, anchor PTS, and buffered events.
  void resetFraming() {
    _carry = Uint8List(0);
    _patSection = null;
    _patExpectedLen = 0;
    _pmtSection = null;
    _pmtExpectedLen = 0;
    _captionPes = null;
    _captionPesPtsSeconds = null;
    _captionExpectedPayloadBytes = 0;
  }

  /// Clears all framing, PIDs, stream PTS origin, and cached layout events.
  void resetAll() {
    resetFraming();
    _packetStride = 0;
    _pmtPid = -1;
    _captionPid = -1;
    _captionComponentTag = 0xFF;
    _firstStreamPtsSeconds = null;
    _events.clear();
  }

  /// Feeds decrypted plaintext TS/TTS bytes into the tap.
  void feed(List<int> chunk) {
    if (chunk.isEmpty) return;

    final Uint8List buf;
    if (_carry.isEmpty) {
      buf = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    } else {
      final combined = Uint8List(_carry.length + chunk.length);
      combined.setAll(0, _carry);
      combined.setAll(_carry.length, chunk);
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
        _carry = Uint8List.fromList(buf.sublist(pos));
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

    // Fast path: skip all irrelevant video/audio packets once origin PTS is set.
    if (pid != 0 &&
        pid != _pmtPid &&
        pid != _captionPid &&
        (_firstStreamPtsSeconds != null || !pusi)) {
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

    // Record initial A/V stream PTS as fallback reference for relative offsets.
    if (_firstStreamPtsSeconds == null && pusi && payloadLen >= 14) {
      if (buf[pStart] == 0x00 &&
          buf[pStart + 1] == 0x00 &&
          buf[pStart + 2] == 0x01) {
        final streamId = buf[pStart + 3];
        if (streamId >= 0xC0 && streamId <= 0xEF && (buf[pStart + 7] & 0x80) != 0) {
          _firstStreamPtsSeconds = _decodePtsSeconds(buf, pStart + 9);
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
        var componentTag = 0xFE;
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
            // ARIB TR-B14 caption component tags: 0x30..0x37 (0x87 = 1seg).
            if ((cTag >= 0x30 && cTag <= 0x37) || cTag == 0x87) {
              isAribCaption = true;
              componentTag = cTag;
            }
          }
          d = dData + dLen;
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
      if (ptsSeconds == null || pesPayloadOff > pEnd) return;
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
    if (pes == null || pts == null) return;
    var payload = pes.takeBytes();
    if (expectedLen > 0 && payload.length > expectedLen) {
      payload = Uint8List.sublistView(payload, 0, expectedLen);
    }
    final event = _parseCaptionPesPayload(payload, ptsSeconds: pts);
    if (event != null) {
      _events.add(event);
      if (_events.length > _maxBufferedEvents) {
        _events.removeRange(0, _events.length - _maxBufferedEvents);
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

  static AribCaptionLayoutEvent? _parseCaptionPesPayload(
    Uint8List payload, {
    required double ptsSeconds,
  }) {
    if (payload.length < 10) return null;
    final dataIdentifier = payload[0];
    final privateStreamId = payload[1];
    // 0x80 = synchronized closed caption PES, 0xFF = private stream marker.
    if (dataIdentifier != 0x80 || privateStreamId != 0xFF) return null;
    final pesPrivateLen = payload[2] & 0x0F;
    var off = 3 + pesPrivateLen;
    if (off + 6 > payload.length) return null;

    final dataGroupId = (payload[off] >> 2) & 0x3F;
    // Skip caption management groups (0x00 / 0x20) & secondary languages (!= 1).
    if ((dataGroupId & 0x1F) != 1) return null;

    off += 5; // data_group_id+version(1), link(1), last_link(1), size(2)
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
      if (unitParam == 0x20 && unitSize > 0) {
        statementBytes.add(Uint8List.sublistView(payload, u, u + unitSize));
      }
      u += unitSize;
    }

    final body = statementBytes.takeBytes();
    if (body.isEmpty) return null;
    return parseAribStatementBody(body, ptsSeconds: ptsSeconds);
  }

  /// Parses an ARIB STD-B24 caption statement body (`data_unit_parameter == 0x20`)
  /// into positioned character line bounds and timed clear markers.
  static AribCaptionLayoutEvent? parseAribStatementBody(
    Uint8List body, {
    required double ptsSeconds,
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
    final gIsMosaic = [false, false, false, false];
    var g3IsMacro = true;
    var gl = 0;
    var gr = 2;
    int? singleShift;
    var repeatCount = 1;

    var hasClear = false;
    var timeWaitSeconds = 0.0;
    double? clearAfterSeconds;
    final lines = <_MutableLineBucket>[];

    void recordVisibleGlyph(double width) {
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
        if ((bucket.baselineY - baselineY).abs() <= threshold) {
          target = bucket;
          break;
        }
      }
      if (target == null) {
        lines.add(
          _MutableLineBucket(
            baselineY: baselineY,
            centerY: centerY,
            minX: glyphStartX,
            maxEndX: glyphEndX,
            charCount: 1,
          ),
        );
      } else {
        if (glyphStartX < target.minX) target.minX = glyphStartX;
        if (glyphEndX > target.maxEndX) target.maxEndX = glyphEndX;
        target.charCount += 1;
      }
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
                    if (i < body.length) i++;
                    gIsMosaic[target] = false; // 2-byte DRCS glyph
                  } else if (i < body.length) {
                    final fin = body[i++];
                    gIsMosaic[target] = fin >= 0x32 && fin <= 0x35;
                  }
                } else {
                  gBytes[0] = 2;
                  gIsMosaic[0] = e2 >= 0x32 && e2 <= 0x35;
                }
              default:
                if (e1 >= 0x28 && e1 <= 0x2B) {
                  final target = e1 - 0x28;
                  if (i < body.length && body[i] == 0x20) {
                    // 1-byte DRCS
                    i++;
                    if (i < body.length) i++;
                    gBytes[target] = 1;
                    gIsMosaic[target] = false;
                    if (target == 3) g3IsMacro = false;
                  } else if (i < body.length) {
                    final fin = body[i++];
                    gBytes[target] = _isTwoByteFinal(fin) ? 2 : 1;
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
      final isMosaic = gIsMosaic[area];
      final first = b & 0x7F;
      var second = 0;
      i++;
      if (area == 3 && g3IsMacro && first >= 0x60 && first <= 0x6F) {
        if (first == 0x60) {
          // ARIB default macro 0x60: reset G0..G3, GL=0, GR=2.
          gBytes[0] = 2;
          gBytes[1] = 1;
          gBytes[2] = 1;
          gBytes[3] = 1;
          for (var k = 0; k < 4; k++) {
            gIsMosaic[k] = false;
          }
          g3IsMacro = true;
          gl = 0;
          gr = 2;
        }
        repeatCount = 1;
        continue;
      }
      if (byteCount == 2) {
        if (i >= body.length) break;
        second = body[i++] & 0x7F;
        if (second < 0x21) continue;
      }

      final isSpaceCell =
          (byteCount == 2 && first == 0x21 && second == 0x21) ||
          (byteCount == 1 && first == 0x20);
      final count = repeatCount;
      repeatCount = 1;
      for (var r = 0; r < count; r++) {
        if (isSpaceCell || isMosaic) {
          curX += charStepX();
        } else {
          recordVisibleGlyph(charStepX());
        }
      }
    }

    if (lines.isEmpty) {
      if (!hasClear) return null;
      return AribCaptionLayoutEvent(
        ptsSeconds: ptsSeconds,
        planeWidth: planeW,
        planeHeight: planeH,
        lines: const [],
        isClearOnly: true,
      );
    }

    lines.sort((a, b) => a.baselineY.compareTo(b.baselineY));
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
          ),
      ],
      isClearOnly: false,
      clearAfterSeconds: clearAfterSeconds,
    );
  }

  static bool _isTwoByteFinal(int fin) =>
      fin == 0x42 || fin == 0x39 || fin == 0x3A || fin == 0x3B;
}
