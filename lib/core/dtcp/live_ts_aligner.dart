/// MPEG-TS (`188` B) and MPEG-TTS (`192` B) packet framing and timestamp
/// continuity aligner for live HTTP proxy reconnects.
///
/// When an upstream live stream disconnects and reconnects (especially transcoded
/// mobile quality streams whose encoder resets PCR/PTS back near zero on every
/// HTTP GET), concatenating the raw byte streams directly into one HTTP
/// response causes two fatal demuxer failures in mpv:
/// 1. Mid-packet cuts break `0x47` TS packet sync across the boundary.
/// 2. Large backwards/discontinuous PCR/PTS jumps corrupt `demuxer-seekable-cache`
///    timing and cause choppy/fragmented playback.
///
/// [LiveTsContinuityAligner] emits only complete aligned TS/TTS packets and, on
/// each reconnect segment boundary ([beginNewSegment]), resynchronizes packet
/// boundaries and rebases incoming 33-bit PCR/OPCR/PTS/DTS timestamps (+ 30-bit
/// TTS arrival timestamps) monotonically forward from the last emitted stream
/// timestamp, setting `discontinuity_indicator` once per PID.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Normalizes live MPEG-TS (`188` B) / MPEG-TTS (`192` B) streams across
/// upstream reconnects while auto-passing through non-TS byte fixtures.
class LiveTsContinuityAligner {
  static const int _tsPacketSize = 188;
  static const int _ttsPacketSize = 192;
  static const int _ptsMask33 = 0x1FFFFFFFF;
  static const int _ptsMod33 = 0x200000000;
  static const int _ttsMask30 = 0x3FFFFFFF;
  static const int _probeLimitBytes = 1024;
  static const int _maxRebaseBufferPackets = 2048;
  static const int _maxResyncCarryBytes = 4096;

  /// +100 ms in 90 kHz clock ticks added when stitching a reconnect segment.
  static const int _reconnectGap90k = 9000;

  /// +100 ms in 27 MHz TTS arrival clock ticks.
  static const int _reconnectGap27M = 2700000;

  Uint8List _carry = Uint8List(0);
  int? _packetSize;
  bool _passthrough = false;
  bool _resyncNeeded = false;
  bool _needsRebase = false;
  bool _rebaseSawPcr = false;
  bool _rebaseSawAnyTs = false;
  bool _streamHasPcr = false;
  bool _markDiscontinuityAfterReconnect = false;
  int _packetsSinceReconnect = 0;
  final Set<int> _discontinuityEmittedPids = <int>{};

  int _ptsOffset90k = 0;
  int? _maxEmittedPts90k;
  int _ttsOffset30 = 0;
  int? _lastEmittedTts30;

  final List<Uint8List> _pendingRebasePackets = <Uint8List>[];

  /// Detected packet stride (`188` or `192`), or `null` if undetected yet.
  int? get detectedPacketSize => _packetSize;

  /// Whether input was classified as non-TS bytes and is passed through raw.
  bool get isPassthrough => _passthrough;

  /// Active 90 kHz timestamp offset applied to incoming PCR/PTS/DTS values.
  int get currentPtsOffset90k => _ptsOffset90k;

  /// Clears all state for a brand-new stream (e.g. [DtcpProxy.resetToLiveEdge]).
  void reset() {
    _carry = Uint8List(0);
    _packetSize = null;
    _passthrough = false;
    _resyncNeeded = false;
    _needsRebase = false;
    _rebaseSawPcr = false;
    _rebaseSawAnyTs = false;
    _streamHasPcr = false;
    _markDiscontinuityAfterReconnect = false;
    _packetsSinceReconnect = 0;
    _discontinuityEmittedPids.clear();
    _ptsOffset90k = 0;
    _maxEmittedPts90k = null;
    _ttsOffset30 = 0;
    _lastEmittedTts30 = null;
    _pendingRebasePackets.clear();
  }

  /// Marks the start of a fresh upstream HTTP response after a live drop.
  ///
  /// Drops any truncated trailing bytes buffered before the socket died and
  /// arms timestamp rebasing so the next segment continues monotonically past
  /// the last emitted timestamp.
  void beginNewSegment() {
    _carry = Uint8List(0);
    _pendingRebasePackets.clear();
    _rebaseSawPcr = false;
    _rebaseSawAnyTs = false;
    _packetsSinceReconnect = 0;
    if (_passthrough) return;
    _resyncNeeded = true;
    if (_maxEmittedPts90k != null) {
      _needsRebase = true;
      _markDiscontinuityAfterReconnect = true;
      _discontinuityEmittedPids.clear();
    }
  }

  /// Feeds a decrypted plaintext chunk and returns a contiguous aligned
  /// plaintext slice (or empty [Uint8List] while waiting for a full packet /
  /// initial rebase timestamp).
  Uint8List process(Uint8List chunk) {
    if (chunk.isEmpty) return Uint8List(0);
    if (_passthrough) return chunk;

    final Uint8List combined;
    if (_carry.isEmpty) {
      combined = chunk;
    } else {
      combined = Uint8List(_carry.length + chunk.length)
        ..setRange(0, _carry.length, _carry)
        ..setRange(_carry.length, _carry.length + chunk.length, chunk);
      _carry = Uint8List(0);
    }

    var offset = 0;
    if (_packetSize == null || _resyncNeeded) {
      final detected = _detectSyncOffset(
        combined,
        forcedSize: _packetSize,
      );
      if (detected == null) {
        if (_packetSize == null && combined.length >= _probeLimitBytes) {
          _passthrough = true;
          return combined;
        }
        _carry = _capCarry(combined);
        return Uint8List(0);
      }
      _packetSize = detected.$1;
      offset = detected.$2;
      _resyncNeeded = false;
    }

    final pktSize = _packetSize!;
    final tsOffsetInPacket = pktSize == _ttsPacketSize ? 4 : 0;
    final out = BytesBuilder(copy: false);
    Uint8List? singleChunkResult;

    void emitRun(int runStart, int runEnd) {
      if (runEnd <= runStart) return;
      final needsWrite =
          _ptsOffset90k != 0 ||
          _ttsOffset30 != 0 ||
          _markDiscontinuityAfterReconnect;
      final Uint8List slice;
      if (!needsWrite) {
        for (var p = runStart; p < runEnd; p += pktSize) {
          _observeRawPacketInPlace(combined, p, tsOffsetInPacket);
        }
        slice = (runStart == 0 && runEnd == combined.length)
            ? combined
            : Uint8List.sublistView(combined, runStart, runEnd);
      } else {
        final copy = Uint8List.fromList(
          Uint8List.sublistView(combined, runStart, runEnd),
        );
        for (var p = 0; p < copy.length; p += pktSize) {
          _rewriteAndTrackPacketAt(copy, p, tsOffsetInPacket);
        }
        slice = copy;
      }
      if (out.isEmpty && singleChunkResult == null) {
        singleChunkResult = slice;
      } else {
        if (singleChunkResult != null) {
          out.add(singleChunkResult!);
          singleChunkResult = null;
        }
        out.add(slice);
      }
    }

    var runStart = -1;
    while (offset + pktSize <= combined.length) {
      if (combined[offset + tsOffsetInPacket] != 0x47) {
        if (runStart >= 0) {
          emitRun(runStart, offset);
          runStart = -1;
        }
        // Sync lost inside stream: re-scan for next packet boundary.
        final resync = _detectSyncOffset(
          combined,
          start: offset + 1,
          forcedSize: pktSize,
        );
        if (resync == null) break;
        offset = resync.$2;
        continue;
      }
      final pktStart = offset;
      offset += pktSize;

      if (_needsRebase) {
        _pendingRebasePackets.add(
          Uint8List.fromList(Uint8List.sublistView(combined, pktStart, offset)),
        );
        final ts = _extractPacketTimestamps90k(
          combined,
          pktStart,
          tsOffsetInPacket,
        );
        if (ts.pcr != null) {
          _rebaseSawPcr = true;
          _rebaseSawAnyTs = true;
        } else if (ts.dts != null || ts.pts != null) {
          _rebaseSawAnyTs = true;
        }
        if (_rebaseSawPcr ||
            _pendingRebasePackets.length >= _maxRebaseBufferPackets) {
          _flushPendingRebase(tsOffsetInPacket, pktSize, (flushed) {
            if (out.isEmpty && singleChunkResult == null) {
              singleChunkResult = flushed;
            } else {
              if (singleChunkResult != null) {
                out.add(singleChunkResult!);
                singleChunkResult = null;
              }
              out.add(flushed);
            }
          });
        }
        continue;
      }

      if (runStart < 0) runStart = pktStart;
    }

    if (runStart >= 0) {
      emitRun(runStart, offset);
    }

    if (_needsRebase &&
        !_streamHasPcr &&
        _rebaseSawAnyTs &&
        _pendingRebasePackets.isNotEmpty) {
      _flushPendingRebase(tsOffsetInPacket, pktSize, (flushed) {
        if (out.isEmpty && singleChunkResult == null) {
          singleChunkResult = flushed;
        } else {
          if (singleChunkResult != null) {
            out.add(singleChunkResult!);
            singleChunkResult = null;
          }
          out.add(flushed);
        }
      });
    }

    if (offset < combined.length) {
      _carry = _capCarry(Uint8List.sublistView(combined, offset));
    }
    if (singleChunkResult != null) return singleChunkResult!;
    return out.isEmpty ? Uint8List(0) : out.takeBytes();
  }

  static Uint8List _capCarry(Uint8List tail) {
    if (tail.length <= _maxResyncCarryBytes) {
      return Uint8List.fromList(tail);
    }
    return Uint8List.fromList(
      Uint8List.sublistView(tail, tail.length - _maxResyncCarryBytes),
    );
  }

  void _flushPendingRebase(
    int tsOffsetInPacket,
    int pktSize,
    void Function(Uint8List bytes) emit,
  ) {
    if (_pendingRebasePackets.isEmpty) {
      _needsRebase = false;
      return;
    }
    int? earliestTs;
    for (final pkt in _pendingRebasePackets) {
      final ts = _extractPacketTimestamps90k(pkt, 0, tsOffsetInPacket);
      for (final candidate in [ts.pcr, ts.dts, ts.pts]) {
        if (candidate == null) continue;
        if (earliestTs == null) {
          earliestTs = candidate;
        } else {
          final signedDiff =
              ((candidate - earliestTs + 0x100000000) & _ptsMask33) -
              0x100000000;
          if (signedDiff < 0) {
            earliestTs = candidate;
          }
        }
      }
    }
    if (earliestTs == null) {
      // No timestamp arrived within this buffer window yet; emit the buffered
      // packets cleanly but keep rebase armed for the first timestamped packet.
      final out = Uint8List(_pendingRebasePackets.length * pktSize);
      var writePos = 0;
      for (final buffered in _pendingRebasePackets) {
        out.setRange(writePos, writePos + pktSize, buffered);
        if (tsOffsetInPacket == 4) {
          _lastEmittedTts30 = _readTts30At(out, writePos);
        }
        writePos += pktSize;
      }
      _pendingRebasePackets.clear();
      _rebaseSawPcr = false;
      _rebaseSawAnyTs = false;
      emit(out);
      return;
    }
    if (_maxEmittedPts90k != null) {
      final targetPts = (_maxEmittedPts90k! + _reconnectGap90k) & _ptsMask33;
      _ptsOffset90k = (targetPts - earliestTs) & _ptsMask33;
    }
    if (pktSize == _ttsPacketSize && _lastEmittedTts30 != null) {
      final firstTts = _findFirstTts30(_pendingRebasePackets);
      if (firstTts != null) {
        final targetTts = (_lastEmittedTts30! + _reconnectGap27M) & _ttsMask30;
        _ttsOffset30 = (targetTts - firstTts) & _ttsMask30;
      }
    }
    _needsRebase = false;
    _rebaseSawPcr = false;
    _rebaseSawAnyTs = false;
    final out = Uint8List(_pendingRebasePackets.length * pktSize);
    var writePos = 0;
    for (final buffered in _pendingRebasePackets) {
      out.setRange(writePos, writePos + pktSize, buffered);
      _rewriteAndTrackPacketAt(out, writePos, tsOffsetInPacket);
      writePos += pktSize;
    }
    _pendingRebasePackets.clear();
    emit(out);
  }

  (int packetSize, int offset)? _detectSyncOffset(
    Uint8List data, {
    int start = 0,
    int? forcedSize,
  }) {
    final limit = data.length;
    bool matchesAt(int off, int size, int tsOff) {
      if (off + tsOff >= limit) return false;
      if (data[off + tsOff] != 0x47) return false;
      if (off + size + tsOff >= limit) return false;
      if (data[off + size + tsOff] != 0x47) return false;
      if (off + size * 2 + tsOff < limit &&
          data[off + size * 2 + tsOff] != 0x47) {
        return false;
      }
      return true;
    }

    for (var i = start; i < limit; i++) {
      if (forcedSize == null || forcedSize == _tsPacketSize) {
        if (matchesAt(i, _tsPacketSize, 0)) return (_tsPacketSize, i);
      }
      if (forcedSize == null || forcedSize == _ttsPacketSize) {
        if (matchesAt(i, _ttsPacketSize, 4)) return (_ttsPacketSize, i);
      }
    }
    return null;
  }

  static int? _findFirstTts30(List<Uint8List> packets) {
    if (packets.isEmpty) return null;
    return _readTts30At(packets.first, 0);
  }

  static int _readTts30At(Uint8List buf, int base) {
    return (((buf[base] & 0x3F) << 24) |
            (buf[base + 1] << 16) |
            (buf[base + 2] << 8) |
            buf[base + 3]) &
        _ttsMask30;
  }

  static void _writeTts30At(Uint8List buf, int base, int tts30) {
    final masked = tts30 & _ttsMask30;
    buf[base] = (buf[base] & 0xC0) | ((masked >> 24) & 0x3F);
    buf[base + 1] = (masked >> 16) & 0xFF;
    buf[base + 2] = (masked >> 8) & 0xFF;
    buf[base + 3] = masked & 0xFF;
  }

  static ({int? pcr, int? dts, int? pts}) _extractPacketTimestamps90k(
    Uint8List buf,
    int pktOffset,
    int tsOff,
  ) {
    final tsStart = pktOffset + tsOff;
    if (tsStart + _tsPacketSize > buf.length || buf[tsStart] != 0x47) {
      return (pcr: null, dts: null, pts: null);
    }
    int? pcr;
    int? pts;
    int? dts;
    final pusi = (buf[tsStart + 1] & 0x40) != 0;
    final afc = (buf[tsStart + 3] >> 4) & 0x03;

    if (afc == 2 || afc == 3) {
      final afl = buf[tsStart + 4];
      if (afl >= 7 && 5 + afl <= _tsPacketSize) {
        final flags = buf[tsStart + 5];
        if ((flags & 0x10) != 0) {
          pcr = _readPcrBase33(buf, tsStart + 6);
        }
      }
    }

    if (pusi && (afc == 1 || afc == 3)) {
      final payloadRel = afc == 1 ? 4 : 5 + buf[tsStart + 4];
      final payloadStart = tsStart + payloadRel;
      if (payloadRel + 14 <= _tsPacketSize &&
          buf[payloadStart] == 0x00 &&
          buf[payloadStart + 1] == 0x00 &&
          buf[payloadStart + 2] == 0x01 &&
          _streamHasOptionalPesHeader(buf[payloadStart + 3])) {
        final ptsDtsFlags = (buf[payloadStart + 7] >> 6) & 0x03;
        final pesHeaderDataLen = buf[payloadStart + 8];
        if ((ptsDtsFlags == 2 || ptsDtsFlags == 3) && pesHeaderDataLen >= 5) {
          pts = _readPesTimestamp33(buf, payloadStart + 9);
        }
        if (ptsDtsFlags == 3 &&
            pesHeaderDataLen >= 10 &&
            payloadRel + 19 <= _tsPacketSize) {
          dts = _readPesTimestamp33(buf, payloadStart + 14);
        }
      }
    }
    return (pcr: pcr, dts: dts, pts: pts);
  }

  void _observeRawPacketInPlace(Uint8List buf, int pktOffset, int tsOff) {
    if (tsOff == 4) {
      _lastEmittedTts30 = _readTts30At(buf, pktOffset);
    }
    final ts = _extractPacketTimestamps90k(buf, pktOffset, tsOff);
    if (ts.pcr != null) {
      _streamHasPcr = true;
      _observeEmittedPts90k(ts.pcr!);
    }
    if (ts.pts != null) _observeEmittedPts90k(ts.pts!);
  }

  void _rewriteAndTrackPacketAt(Uint8List buf, int pktOffset, int tsOff) {
    if (tsOff == 4) {
      final rawTts = _readTts30At(buf, pktOffset);
      final shiftedTts = (rawTts + _ttsOffset30) & _ttsMask30;
      if (_ptsOffset90k != 0 || _ttsOffset30 != 0) {
        _writeTts30At(buf, pktOffset, shiftedTts);
      }
      _lastEmittedTts30 = shiftedTts;
    }

    if (_markDiscontinuityAfterReconnect) {
      _packetsSinceReconnect++;
    }

    final tsStart = pktOffset + tsOff;
    final pid = ((buf[tsStart + 1] & 0x1F) << 8) | buf[tsStart + 2];
    final pusi = (buf[tsStart + 1] & 0x40) != 0;
    final afc = (buf[tsStart + 3] >> 4) & 0x03;

    if (afc == 2 || afc == 3) {
      final afl = buf[tsStart + 4];
      final afEnd = tsStart + 5 + afl;
      if (afl >= 1 && 5 + afl <= _tsPacketSize) {
        if (_markDiscontinuityAfterReconnect &&
            _discontinuityEmittedPids.add(pid)) {
          buf[tsStart + 5] |= 0x80; // discontinuity_indicator
        }
        final flags = buf[tsStart + 5];
        var cursor = tsStart + 6;
        if ((flags & 0x10) != 0 && cursor + 6 <= afEnd) {
          _streamHasPcr = true;
          final pcrBase = _readPcrBase33(buf, cursor);
          final nextPcr = (pcrBase + _ptsOffset90k) & _ptsMask33;
          if (_ptsOffset90k != 0) {
            _writePcrBase33(buf, cursor, nextPcr);
          }
          _observeEmittedPts90k(nextPcr);
          cursor += 6;
        }
        if ((flags & 0x08) != 0 && cursor + 6 <= afEnd) {
          if (_ptsOffset90k != 0) {
            final opcrBase = _readPcrBase33(buf, cursor);
            _writePcrBase33(
              buf,
              cursor,
              (opcrBase + _ptsOffset90k) & _ptsMask33,
            );
          }
        }
      }
    }

    if (pusi && (afc == 1 || afc == 3)) {
      final payloadRel = afc == 1 ? 4 : 5 + buf[tsStart + 4];
      final payloadStart = tsStart + payloadRel;
      if (payloadRel + 14 <= _tsPacketSize &&
          buf[payloadStart] == 0x00 &&
          buf[payloadStart + 1] == 0x00 &&
          buf[payloadStart + 2] == 0x01 &&
          _streamHasOptionalPesHeader(buf[payloadStart + 3])) {
        final ptsDtsFlags = (buf[payloadStart + 7] >> 6) & 0x03;
        final pesHeaderDataLen = buf[payloadStart + 8];
        if ((ptsDtsFlags == 2 || ptsDtsFlags == 3) && pesHeaderDataLen >= 5) {
          final pts = _readPesTimestamp33(buf, payloadStart + 9);
          if (pts != null) {
            final nextPts = (pts + _ptsOffset90k) & _ptsMask33;
            if (_ptsOffset90k != 0) {
              _writePesTimestamp33(buf, payloadStart + 9, nextPts);
            }
            _observeEmittedPts90k(nextPts);
          }
        }
        if (ptsDtsFlags == 3 &&
            pesHeaderDataLen >= 10 &&
            payloadRel + 19 <= _tsPacketSize) {
          final dts = _readPesTimestamp33(buf, payloadStart + 14);
          if (dts != null && _ptsOffset90k != 0) {
            _writePesTimestamp33(
              buf,
              payloadStart + 14,
              (dts + _ptsOffset90k) & _ptsMask33,
            );
          }
        }
      }
    }
    if (_markDiscontinuityAfterReconnect &&
        (_packetsSinceReconnect >= 256 ||
            _discontinuityEmittedPids.length > 64)) {
      _markDiscontinuityAfterReconnect = false;
    }
  }

  void _observeEmittedPts90k(int pts90k) {
    final curMax = _maxEmittedPts90k;
    if (curMax == null) {
      _maxEmittedPts90k = pts90k;
      return;
    }
    final forwardDelta = (pts90k - curMax) & _ptsMask33;
    // Accept normal forward progression (including B-frame jumps up to 200s
    // without letting wrap/corruption jump backwards).
    if (forwardDelta > 0 && forwardDelta < 18000000) {
      _maxEmittedPts90k = math.max(0, pts90k) & _ptsMask33;
    }
  }

  static bool _streamHasOptionalPesHeader(int streamId) {
    // program_stream_map (0xBC), padding_stream (0xBE), private_stream_2 (0xBF),
    // ECM (0xF0), EMM (0xF1), DSMCC (0xF2), H.222.1 E (0xF8), directory (0xFF).
    switch (streamId) {
      case 0xBC:
      case 0xBE:
      case 0xBF:
      case 0xF0:
      case 0xF1:
      case 0xF2:
      case 0xF8:
      case 0xFF:
        return false;
      default:
        return streamId >= 0xBD;
    }
  }

  static int _readPcrBase33(Uint8List pkt, int offset) {
    return ((pkt[offset] << 25) |
            (pkt[offset + 1] << 17) |
            (pkt[offset + 2] << 9) |
            (pkt[offset + 3] << 1) |
            ((pkt[offset + 4] >> 7) & 0x01)) &
        _ptsMask33;
  }

  static void _writePcrBase33(Uint8List pkt, int offset, int base33) {
    final v = base33 & _ptsMask33;
    pkt[offset] = (v >> 25) & 0xFF;
    pkt[offset + 1] = (v >> 17) & 0xFF;
    pkt[offset + 2] = (v >> 9) & 0xFF;
    pkt[offset + 3] = (v >> 1) & 0xFF;
    pkt[offset + 4] = ((v & 0x01) << 7) | (pkt[offset + 4] & 0x7F);
  }

  static int? _readPesTimestamp33(Uint8List pkt, int offset) {
    final b0 = pkt[offset];
    final b1 = pkt[offset + 1];
    final b2 = pkt[offset + 2];
    final b3 = pkt[offset + 3];
    final b4 = pkt[offset + 4];
    // Validate MPEG-2 PES marker bits (`...1`, `...1`, `...1`).
    if ((b0 & 0x01) != 0x01 || (b2 & 0x01) != 0x01 || (b4 & 0x01) != 0x01) {
      return null;
    }
    return (((b0 >> 1) & 0x07) << 30) |
        (b1 << 22) |
        (((b2 >> 1) & 0x7F) << 15) |
        (b3 << 7) |
        ((b4 >> 1) & 0x7F);
  }

  static void _writePesTimestamp33(Uint8List pkt, int offset, int ts33) {
    final v = (ts33 % _ptsMod33) & _ptsMask33;
    final prefixNibble = pkt[offset] & 0xF0;
    pkt[offset] = prefixNibble | (((v >> 30) & 0x07) << 1) | 0x01;
    pkt[offset + 1] = (v >> 22) & 0xFF;
    pkt[offset + 2] = (((v >> 15) & 0x7F) << 1) | 0x01;
    pkt[offset + 3] = (v >> 7) & 0xFF;
    pkt[offset + 4] = ((v & 0x7F) << 1) | 0x01;
  }
}
