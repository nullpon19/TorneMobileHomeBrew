import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tmhb/core/core.dart';

Uint8List _makeTsPacket({
  required int pid,
  int pcrBase90k = -1,
  int? pts90k,
  int? dts90k,
  bool discontinuity = false,
  int fill = 0xAA,
}) {
  final pkt = Uint8List(188)..fillRange(0, 188, fill);
  final hasPesPts = pts90k != null;
  pkt[0] = 0x47;
  pkt[1] = (hasPesPts ? 0x40 : 0x00) | ((pid >> 8) & 0x1F);
  pkt[2] = pid & 0xFF;

  final hasAf = pcrBase90k >= 0 || discontinuity || hasPesPts;
  if (!hasAf) {
    pkt[3] = 0x10;
    return pkt;
  }

  // Write adaptation field (9 bytes so payload starts cleanly when needed).
  pkt[3] = hasPesPts ? 0x30 : 0x20;
  final afl = pcrBase90k >= 0 ? 7 : 1;
  pkt[4] = afl;
  pkt[5] = (discontinuity ? 0x80 : 0x00) | (pcrBase90k >= 0 ? 0x10 : 0x00);
  if (pcrBase90k >= 0) {
    final v = pcrBase90k & 0x1FFFFFFFF;
    pkt[6] = (v >> 25) & 0xFF;
    pkt[7] = (v >> 17) & 0xFF;
    pkt[8] = (v >> 9) & 0xFF;
    pkt[9] = (v >> 1) & 0xFF;
    pkt[10] = ((v & 0x01) << 7) | 0x7E;
    pkt[11] = 0x00;
  }

  if (hasPesPts) {
    final p = 5 + afl;
    pkt[p] = 0x00;
    pkt[p + 1] = 0x00;
    pkt[p + 2] = 0x01;
    pkt[p + 3] = 0xE0; // video stream
    pkt[p + 4] = 0x00;
    pkt[p + 5] = 0x00;
    pkt[p + 6] = 0x80;
    pkt[p + 7] = dts90k != null ? 0xC0 : 0x80;
    pkt[p + 8] = dts90k != null ? 10 : 5;
    _writePesTs(pkt, p + 9, pts90k, dts90k != null ? 0x30 : 0x20);
    if (dts90k != null) {
      _writePesTs(pkt, p + 14, dts90k, 0x10);
    }
  }
  return pkt;
}

void _writePesTs(Uint8List buf, int off, int ts90k, int prefixNibble) {
  final v = ts90k & 0x1FFFFFFFF;
  buf[off] = prefixNibble | (((v >> 30) & 0x07) << 1) | 0x01;
  buf[off + 1] = (v >> 22) & 0xFF;
  buf[off + 2] = (((v >> 15) & 0x7F) << 1) | 0x01;
  buf[off + 3] = (v >> 7) & 0xFF;
  buf[off + 4] = ((v & 0x7F) << 1) | 0x01;
}

int _readPesTs(Uint8List pkt, int off) {
  return (((pkt[off] >> 1) & 0x07) << 30) |
      (pkt[off + 1] << 22) |
      (((pkt[off + 2] >> 1) & 0x7F) << 15) |
      (pkt[off + 3] << 7) |
      ((pkt[off + 4] >> 1) & 0x7F);
}

int _readPcr(Uint8List pkt, int off) {
  return ((pkt[off] << 25) |
          (pkt[off + 1] << 17) |
          (pkt[off + 2] << 9) |
          (pkt[off + 3] << 1) |
          ((pkt[off + 4] >> 7) & 0x01)) &
      0x1FFFFFFFF;
}

Uint8List _wrapTts(Uint8List ts188, int arrival30) {
  final out = Uint8List(192);
  out[0] = (arrival30 >> 24) & 0x3F;
  out[1] = (arrival30 >> 16) & 0xFF;
  out[2] = (arrival30 >> 8) & 0xFF;
  out[3] = arrival30 & 0xFF;
  out.setRange(4, 192, ts188);
  return out;
}

void main() {
  group('LiveTsContinuityAligner', () {
    test('frames partial TS chunks, drops truncated tail on drop, and rebases 0-reset PTS/PCR monotonically', () {
      final aligner = LiveTsContinuityAligner();

      // Segment 1: PCR=900000 (10.0s), PTS=903000, + truncated trailing half-packet.
      final p1 = _makeTsPacket(pid: 0x0100, pcrBase90k: 900000, pts90k: 903000);
      final p2 = _makeTsPacket(pid: 0x0100, pcrBase90k: 909000, pts90k: 912000);
      final truncTail = Uint8List.fromList(List.filled(73, 0x47));
      final seg1 = Uint8List.fromList([...p1, ...p2, ...truncTail]);

      final out1 = aligner.process(seg1);
      expect(aligner.detectedPacketSize, 188);
      expect(aligner.isPassthrough, isFalse);
      // Truncated tail held back; only 2 complete packets (376 B) emitted.
      expect(out1.length, 376);

      // Simulate reconnect + encoder reset back near zero on segment 2,
      // preceded by 19 bytes of broken leftover garbage before clean 0x47 sync.
      aligner.beginNewSegment();
      final p3 = _makeTsPacket(pid: 0x0100, pcrBase90k: 1000, pts90k: 4000, dts90k: 1000);
      final p4 = _makeTsPacket(pid: 0x0100, pcrBase90k: 10000, pts90k: 13000, dts90k: 10000);
      final garbagePrefix = Uint8List.fromList(List.filled(19, 0xFF));
      final out2 = aligner.process(Uint8List.fromList([...garbagePrefix, ...p3, ...p4]));

      expect(out2.length, 376);
      expect(out2[0], 0x47);
      expect(out2[188], 0x47);
      // Discontinuity indicator set on first packet of segment 2.
      expect((out2[5] & 0x80) != 0, isTrue);

      // Rebased PCR continues +9000 ticks (+100ms) past seg1's max (912000 -> 921000).
      final pkt3 = Uint8List.sublistView(out2, 0, 188);
      final newPcr3 = _readPcr(pkt3, 6);
      final newPts3 = _readPesTs(pkt3, 12 + 9);
      final newDts3 = _readPesTs(pkt3, 12 + 14);
      expect(newPcr3, 921000);
      expect(newPts3 - newPcr3, 3000);
      expect(newDts3, newPcr3);

      final pkt4 = Uint8List.sublistView(out2, 188, 376);
      expect(_readPcr(pkt4, 6), 930000);
      expect(_readPesTs(pkt4, 12 + 9), 933000);
    });

    test('detects and rebases 192-byte MPEG-TTS streams cleanly', () {
      final aligner = LiveTsContinuityAligner();
      final seg1 = Uint8List.fromList([
        ..._wrapTts(_makeTsPacket(pid: 0x101, pts90k: 450000), 1000000),
        ..._wrapTts(_makeTsPacket(pid: 0x101, pts90k: 459000), 1270000),
      ]);
      final out1 = aligner.process(seg1);
      expect(aligner.detectedPacketSize, 192);
      expect(out1.length, 384);

      aligner.beginNewSegment();
      final seg2 = Uint8List.fromList([
        ..._wrapTts(_makeTsPacket(pid: 0x101, pts90k: 9000), 5000),
        ..._wrapTts(_makeTsPacket(pid: 0x101, pts90k: 18000), 275000),
      ]);
      final out2 = aligner.process(seg2);
      expect(out2.length, 384);
      expect(out2[4], 0x47);
      expect(out2[196], 0x47);
      // TTS arrival timestamps advance monotonically past seg1's 1270000.
      final tts3 = ((out2[0] & 0x3F) << 24) | (out2[1] << 16) | (out2[2] << 8) | out2[3];
      expect(tts3, 1270000 + 2700000);
    });

    test('passes through non-TS synthetic byte streams verbatim after 1 KiB probe', () {
      final aligner = LiveTsContinuityAligner();
      final raw = Uint8List.fromList(List.generate(2048, (i) => (i + 1) & 0x7F));
      final out = aligner.process(raw);
      expect(aligner.isPassthrough, isTrue);
      expect(out, raw);
    });

    test('uses earlier PCR/DTS across B-frame PTS ahead of PCR so PCR never jumps backwards', () {
      final aligner = LiveTsContinuityAligner();
      final seg1 = Uint8List.fromList([
        ..._makeTsPacket(pid: 0x0100, pcrBase90k: 900000, pts90k: 903000),
        ..._makeTsPacket(pid: 0x0100, pcrBase90k: 909000, pts90k: 912000),
      ]);
      final out1 = aligner.process(seg1);
      expect(out1.length, 376);

      aligner.beginNewSegment();
      // First packet has a B-frame PTS=7000 ahead of the second packet's PCR=1000.
      final pBFrame = _makeTsPacket(pid: 0x0100, pts90k: 7000);
      final pPcrAnchor = _makeTsPacket(
        pid: 0x0100,
        pcrBase90k: 1000,
        pts90k: 4000,
        dts90k: 1000,
      );
      final out2 = aligner.process(Uint8List.fromList([...pBFrame, ...pPcrAnchor]));
      expect(out2.length, 376);

      final rebasedPcr = _readPcr(Uint8List.sublistView(out2, 188, 376), 6);
      // 912000 + 9000 = 921000; PCR must be 921000 (not skewed backwards by B-frame PTS).
      expect(rebasedPcr, 921000);
      final rebasedBFramePts = _readPesTs(Uint8List.sublistView(out2, 0, 188), 6 + 9);
      expect(rebasedBFramePts, 921000 + 6000);
    });

    test('streams multi-chunk TS fast path cleanly without corrupting packets', () {
      final aligner = LiveTsContinuityAligner();
      final p1 = _makeTsPacket(pid: 0x0100, pcrBase90k: 10000, pts90k: 13000);
      final p2 = _makeTsPacket(pid: 0x0100, pcrBase90k: 19000, pts90k: 22000);
      final p3 = _makeTsPacket(pid: 0x0100, pcrBase90k: 28000, pts90k: 31000);
      // Split across odd byte boundaries.
      final full = Uint8List.fromList([...p1, ...p2, ...p3]);
      final c1 = aligner.process(Uint8List.sublistView(full, 0, 250));
      final c2 = aligner.process(Uint8List.sublistView(full, 250, 564));
      expect([...c1, ...c2], full);
    });

    test('caps _carry under prolonged sync loss and still resyncs cleanly', () {
      final aligner = LiveTsContinuityAligner();
      final p0 = _makeTsPacket(pid: 0x0100, pcrBase90k: 10000, pts90k: 12000);
      final p1 = _makeTsPacket(pid: 0x0100, pcrBase90k: 19000, pts90k: 21000);
      expect(aligner.process(Uint8List.fromList([...p0, ...p1])).length, 376);

      // Simulate reconnect followed by 32 KiB of non-sync garbage bytes.
      aligner.beginNewSegment();
      final garbage = Uint8List.fromList(List.filled(32768, 0xAA));
      expect(aligner.process(garbage), isEmpty);

      // Valid TS packets after sync loss should resync and rebase without OOM.
      final p2 = _makeTsPacket(pid: 0x0100, pcrBase90k: 500, pts90k: 1500);
      final p3 = _makeTsPacket(pid: 0x0100, pcrBase90k: 9500, pts90k: 10500);
      final resynced = aligner.process(Uint8List.fromList([...p2, ...p3]));
      expect(resynced.length, 376);
      final rebasedPcr = _readPcr(Uint8List.sublistView(resynced, 0, 188), 6);
      expect(rebasedPcr, 21000 + 9000);
    });

    test('waits beyond 128 packets for PCR anchor on PCR-bearing streams', () {
      final aligner = LiveTsContinuityAligner();
      final initialPcr = _makeTsPacket(
        pid: 0x0100,
        pcrBase90k: 900000,
        pts90k: 909000,
      );
      final initialP2 = _makeTsPacket(pid: 0x0100, pcrBase90k: 909000);
      expect(
        aligner.process(Uint8List.fromList([...initialPcr, ...initialP2])).length,
        376,
      );

      aligner.beginNewSegment();
      // Feed 200 packets without PCR (video PTS earlier in segment would skew offset),
      // then deliver the true PCR packet at index 200.
      final noPcrPackets = <int>[];
      for (var i = 0; i < 200; i++) {
        noPcrPackets.addAll(_makeTsPacket(pid: 0x0101, pts90k: 8000 + i * 100));
      }
      final midOut = aligner.process(Uint8List.fromList(noPcrPackets));
      expect(midOut, isEmpty);

      final pcrPacket = _makeTsPacket(
        pid: 0x0100,
        pcrBase90k: 1000,
        pts90k: 4000,
        dts90k: 1000,
      );
      final flushed = aligner.process(pcrPacket);
      expect(flushed.length, 201 * 188);
      final anchoredPcr = _readPcr(
        Uint8List.sublistView(flushed, 200 * 188, 201 * 188),
        6,
      );
      expect(anchoredPcr, 909000 + 9000);
    });
  });
}
