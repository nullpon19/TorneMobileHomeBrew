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
  static const int _maxRebaseBufferPackets = 128;

  /// +100 ms in 90 kHz clock ticks added when stitching a reconnect segment.
  static const int _reconnectGap90k = 9000;

  /// +100 ms in 27 MHz TTS arrival clock ticks.
  static const int _reconnectGap27M = 2700000;

  Uint8List _carry = Uint8List(0);
  int? _packetSize;
  bool _passthrough = false;
  bool _resyncNeeded = false;
  bool _needsRebase = false;
  bool _markDiscontinuityAfterReconnect = false;
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
    _markDiscontinuityAfterReconnect = false;
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
        _carry = Uint8List.fromList(combined);
        return Uint8List(0);
      }
      _packetSize = detected.$1;
      offset = detected.$2;
      _resyncNeeded = false;
    }

    final pktSize = _packetSize!;
    final tsOffsetInPacket = pktSize == _ttsPacketSize ? 4 : 0;
    final out = BytesBuilder(copy: false);

    while (offset + pktSize <= combined.length) {
      if (combined[offset + tsOffsetInPacket] != 0x47) {
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
      final rawPkt = Uint8List.sublistView(combined, offset, offset + pktSize);
      offset += pktSize;

      if (_needsRebase) {
        _pendingRebasePackets.add(Uint8List.fromList(rawPkt));
        final firstPts = _extractFirstPts90k(rawPkt, tsOffsetInPacket);
        if (firstPts != null ||
            _pendingRebasePackets.length >= _maxRebaseBufferPackets) {
          if (firstPts != null && _maxEmittedPts90k != null) {
            final targetPts = (_maxEmittedPts90k! + _reconnectGap90k) & _ptsMask33;
            _ptsOffset90k = (targetPts - firstPts) & _ptsMask33;
          }
          if (pktSize == _ttsPacketSize && _lastEmittedTts30 != null) {
            final firstTts = _findFirstTts30(_pendingRebasePackets);
            if (firstTts != null) {
              final targetTts =
                  (_lastEmittedTts30! + _reconnectGap27M) & _ttsMask30;
              _ttsOffset30 = (targetTts - firstTts) & _ttsMask30;
            }
          }
          _needsRebase = false;
          for (final buffered in _pendingRebasePackets) {
            out.add(_rewriteAndTrackPacket(buffered, tsOffsetInPacket));
          }
          _pendingRebasePackets.clear();
        }
        continue;
      }

      out.add(_rewriteAndTrackPacket(Uint8List.fromList(rawPkt), tsOffsetInPacket));
    }

    if (offset < combined.length) {
      _carry = Uint8List.fromList(Uint8List.sublistView(combined, offset));
    }
    return out.takeBytes();
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
    return _readTts30(packets.first);
  }

  static int _readTts30(Uint8List pkt) {
    return (((pkt[0] & 0x3F) << 24) |
            (pkt[1] << 16) |
            (pkt[2] << 8) |
            pkt[3]) &
        _ttsMask30;
  }

  static void _writeTts30(Uint8List pkt, int tts30) {
    final masked = tts30 & _ttsMask30;
    pkt[0] = (pkt[0] & 0xC0) | ((masked >> 24) & 0x3F);
    pkt[1] = (masked >> 16) & 0xFF;
    pkt[2] = (masked >> 8) & 0xFF;
    pkt[3] = masked & 0xFF;
  }

  static int? _extractFirstPts90k(Uint8List pkt, int tsOff) {
    if (tsOff + _tsPacketSize > pkt.length || pkt[tsOff] != 0x47) return null;
    final pusi = (pkt[tsOff + 1] & 0x40) != 0;
    final afc = (pkt[tsOff + 3] >> 4) & 0x03;

    if (afc == 2 || afc == 3) {
      final afl = pkt[tsOff + 4];
      if (afl >= 7 && tsOff + 5 + afl <= tsOff + _tsPacketSize) {
        final flags = pkt[tsOff + 5];
        if ((flags & 0x10) != 0) {
          return _readPcrBase33(pkt, tsOff + 6);
        }
      }
    }

    if (pusi && (afc == 1 || afc == 3)) {
      final payloadStart = afc == 1 ? tsOff + 4 : tsOff + 5 + pkt[tsOff + 4];
      if (payloadStart + 14 <= tsOff + _tsPacketSize &&
          pkt[payloadStart] == 0x00 &&
          pkt[payloadStart + 1] == 0x00 &&
          pkt[payloadStart + 2] == 0x01 &&
          _streamHasOptionalPesHeader(pkt[payloadStart + 3])) {
        final ptsDtsFlags = (pkt[payloadStart + 7] >> 6) & 0x03;
        final pesHeaderDataLen = pkt[payloadStart + 8];
        if ((ptsDtsFlags == 2 || ptsDtsFlags == 3) &&
            pesHeaderDataLen >= 5 &&
            payloadStart + 14 <= tsOff + _tsPacketSize) {
          return _readPesTimestamp33(pkt, payloadStart + 9);
        }
      }
    }
    return null;
  }

  Uint8List _rewriteAndTrackPacket(Uint8List pkt, int tsOff) {
    if (tsOff == 4) {
      final rawTts = _readTts30(pkt);
      final shiftedTts = (rawTts + _ttsOffset30) & _ttsMask30;
      if (_ptsOffset90k != 0 || _ttsOffset30 != 0) {
        _writeTts30(pkt, shiftedTts);
      }
      _lastEmittedTts30 = shiftedTts;
    }

    final pid = ((pkt[tsOff + 1] & 0x1F) << 8) | pkt[tsOff + 2];
    final pusi = (pkt[tsOff + 1] & 0x40) != 0;
    final afc = (pkt[tsOff + 3] >> 4) & 0x03;

    if (afc == 2 || afc == 3) {
      final afl = pkt[tsOff + 4];
      final afEnd = tsOff + 5 + afl;
      if (afl >= 1 && afEnd <= tsOff + _tsPacketSize) {
        if (_markDiscontinuityAfterReconnect &&
            _discontinuityEmittedPids.add(pid)) {
          pkt[tsOff + 5] |= 0x80; // discontinuity_indicator
          if (_discontinuityEmittedPids.length > 64) {
            _markDiscontinuityAfterReconnect = false;
          }
        }
        final flags = pkt[tsOff + 5];
        var cursor = tsOff + 6;
        if ((flags & 0x10) != 0 && cursor + 6 <= afEnd) {
          final pcrBase = _readPcrBase33(pkt, cursor);
          final nextPcr = (pcrBase + _ptsOffset90k) & _ptsMask33;
          if (_ptsOffset90k != 0) {
            _writePcrBase33(pkt, cursor, nextPcr);
          }
          _observeEmittedPts90k(nextPcr);
          cursor += 6;
        }
        if ((flags & 0x08) != 0 && cursor + 6 <= afEnd) {
          if (_ptsOffset90k != 0) {
            final opcrBase = _readPcrBase33(pkt, cursor);
            _writePcrBase33(pkt, cursor, (opcrBase + _ptsOffset90k) & _ptsMask33);
          }
        }
      }
    }

    if (pusi && (afc == 1 || afc == 3)) {
      final payloadStart = afc == 1 ? tsOff + 4 : tsOff + 5 + pkt[tsOff + 4];
      if (payloadStart + 14 <= tsOff + _tsPacketSize &&
          pkt[payloadStart] == 0x00 &&
          pkt[payloadStart + 1] == 0x00 &&
          pkt[payloadStart + 2] == 0x01 &&
          _streamHasOptionalPesHeader(pkt[payloadStart + 3])) {
        final ptsDtsFlags = (pkt[payloadStart + 7] >> 6) & 0x03;
        final pesHeaderDataLen = pkt[payloadStart + 8];
        if ((ptsDtsFlags == 2 || ptsDtsFlags == 3) &&
            pesHeaderDataLen >= 5 &&
            payloadStart + 14 <= tsOff + _tsPacketSize) {
          final pts = _readPesTimestamp33(pkt, payloadStart + 9);
          if (pts != null) {
            final nextPts = (pts + _ptsOffset90k) & _ptsMask33;
            if (_ptsOffset90k != 0) {
              _writePesTimestamp33(pkt, payloadStart + 9, nextPts);
            }
            _observeEmittedPts90k(nextPts);
          }
        }
        if (ptsDtsFlags == 3 &&
            pesHeaderDataLen >= 10 &&
            payloadStart + 19 <= tsOff + _tsPacketSize) {
          final dts = _readPesTimestamp33(pkt, payloadStart + 14);
          if (dts != null && _ptsOffset90k != 0) {
            _writePesTimestamp33(
              pkt,
              payloadStart + 14,
              (dts + _ptsOffset90k) & _ptsMask33,
            );
          }
        }
      }
    }

    return pkt;
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
