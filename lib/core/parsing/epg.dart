/// Parsing of the `chEpg` binary payloads (plan 21).
///
/// Both `EPGGet` responses and `channelLogoDataGet` responses are
/// obfuscated with a single-byte XOR (0x9d) and carry zlib streams:
///
/// - EPG: one zlib stream whose plaintext is a concatenation of
///   EIT sections, each trailed by a CRC-32/MPEG-2 (plan 22). The
///   14-byte section header holds the service triple (serviceId
///   at +3, transportStreamId at +8, originalNetworkId at +10,
///   all big-endian) and the section length; events follow in the
///   usual EIT form: `[eventId u16][start MJD u16][start BCD
///   h/m/s][duration BCD h/m/s][running/freeCA + descriptorsLength
///   (u12)][descriptors]`. Descriptors are standard EIT: 0x4D
///   short event, 0x4E extended event, 0x54 content. Text fields
///   are ARIB STD-B24 (arib_b24.dart).
///   The schedule is split the ARIB way: for each segment the
///   dataset carries a "basic" section (table_id 0x50-0x57, the
///   0x4D/0x54 side) and an "extended" section (table_id
///   0x58-0x5F, the 0x4E side) listing the SAME events, so one
///   broadcast event appears once per section flavour. The parser
///   merges the copies of an event (keyed by eventId + start)
///   into a single guide entry (plan 22).
/// - Logos: a sequence of zlib streams, each decompressing to a
///   20-byte header + PNG. The header holds the decompressed
///   length (u16 BE at +2), the serviceId (u16 BE at +14) and the
///   PNG length (u16 BE at +18; 0 = no logo for that service).
///
/// All formats were determined by measurement against the real
/// device and the official clients (plan 21).
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../arib_b24.dart';
import '../broadcast_text.dart';
import '../models/channel.dart';
import '../models/epg.dart';

/// The XOR key applied to every `chEpg` binary payload.
const int epgXorKey = 0x9d;

/// Removes the XOR obfuscation from a `chEpg` payload.
Uint8List deobfuscateEpgPayload(List<int> raw) {
  final out = Uint8List(raw.length);
  for (var i = 0; i < raw.length; i++) {
    out[i] = raw[i] ^ epgXorKey;
  }
  return out;
}

/// Inflates the (single) zlib stream of an EPG response body.
Uint8List inflateEpgResponse(List<int> rawResponse) {
  return Uint8List.fromList(
      ZLibDecoder().convert(deobfuscateEpgPayload(rawResponse)));
}

int _u16be(List<int> b, int off) => (b[off] << 8) | b[off + 1];

int _bcd(int b) => ((b >> 4) * 10) + (b & 0x0f);

/// MJD (Modified Julian Date) epoch: 1858-11-17.
final DateTime _mjdEpoch = DateTime.utc(1858, 11, 17);

/// Converts an EIT start (MJD + BCD time, JST wall clock) to an
/// absolute instant.
DateTime _eitStart(int mjd, int h, int m, int s) {
  final day = _mjdEpoch.add(Duration(days: mjd));
  return DateTime.utc(day.year, day.month, day.day, h, m, s)
      .subtract(const Duration(hours: 9));
}

Uint32List _buildCrc32MpegTable() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var crc = i << 24;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 0x80000000) != 0
          ? ((crc << 1) ^ 0x04c11db7) & 0xffffffff
          : (crc << 1) & 0xffffffff;
    }
    table[i] = crc;
  }
  return table;
}

final Uint32List _crc32MpegTable = _buildCrc32MpegTable();

/// CRC-32/MPEG-2: polynomial 0x04C11DB7, initial value 0xFFFFFFFF,
/// no input/output reflection, no final XOR. Every EIT section is
/// trailed by this checksum computed over the whole section, so a
/// complete section (checksum included) evaluates to zero.
int crc32Mpeg(List<int> data, [int start = 0, int? end]) {
  var crc = 0xffffffff;
  final limit = end ?? data.length;
  for (var i = start; i < limit; i++) {
    crc = ((crc << 8) ^ _crc32MpegTable[((crc >> 24) ^ data[i]) & 0xff]) &
        0xffffffff;
  }
  return crc;
}

/// One located EIT section in the EPG plaintext.
class _Section {
  const _Section(this.offset, this.totalLength, this.channel);
  final int offset;
  final int totalLength;
  final Channel channel;
}

/// Finds the EIT sections in [plain] in a single linear pass. A section is
/// anchored on the (transportStreamId, originalNetworkId) byte pair of a
/// known channel in the section header, with the table_id in the EIT
/// range, the serviceId verified at its fixed offset, the section
/// length inside the buffer and the trailing CRC-32/MPEG-2 valid.
/// The checksum makes false anchors inside event data a non-issue
/// (the full live corpus validates section by section, plan 22).
List<_Section> _findSections(Uint8List plain, List<Channel> channels) {
  if (channels.isEmpty || plain.length < 18) return const [];
  final byTsOnid = <int, List<Channel>>{};
  final seenTriples = <(int, int, int, int)>{};
  for (final ch in channels) {
    if (!seenTriples.add((
      ch.broadcastingType,
      ch.networkId,
      ch.transportStreamId,
      ch.serviceId,
    ))) {
      continue;
    }
    final key =
        ((ch.transportStreamId & 0xffff) << 16) | (ch.networkId & 0xffff);
    byTsOnid.putIfAbsent(key, () => <Channel>[]).add(ch);
  }
  final sections = <_Section>[];
  for (var i = 8; i + 4 <= plain.length; i++) {
    final key =
        (plain[i] << 24) |
        (plain[i + 1] << 16) |
        (plain[i + 2] << 8) |
        plain[i + 3];
    final candidates = byTsOnid[key];
    if (candidates == null) continue;
    final s = i - 8;
    final tableId = plain[s];
    final sid = _u16be(plain, s + 3);
    for (final ch in candidates) {
      if (ch.serviceId != sid) continue;
      // ARIB STD-B10: 0x60..0x6f is EIT schedule *other TS*.
      // Preserve the original terrestrial EIT selection; accept the
      // other-TS forms for the BS guide (not terrestrial).
      final isEit = tableId == 0x4e ||
          tableId == 0x4f ||
          (tableId >= 0x50 && tableId <= 0x5f) ||
          (ch.broadcastingType == 3 &&
              tableId >= 0x60 &&
              tableId <= 0x6f);
      if (!isEit) continue;
      final total = (((plain[s + 1] & 0x0f) << 8) | plain[s + 2]) + 3;
      if (total < 18 || s + total > plain.length) continue;
      if (crc32Mpeg(plain, s, s + total) != 0) continue;
      sections.add(_Section(s, total, ch));
      break;
    }
  }
  return sections;
}

/// ARIB BS schedule can provide a title in the extended-event "番組名"
/// item even when there is no short_event_descriptor (0x4d).
/// Keep the event metadata and only fill an otherwise missing title.
EpgEvent bsTitleFromExtended(EpgEvent event) {
  if ((event.title ?? '').trim().isNotEmpty) {
    return event;
  }
  for (final item in event.extendedItems) {
    if (item.label != '番組名' || item.value.trim().isEmpty) {
      continue;
    }
    return EpgEvent(
      eventId: event.eventId,
      start: event.start,
      duration: event.duration,
      title: item.value,
      shortText: event.shortText,
      description: event.description,
      cast: event.cast,
      extendedItems: event.extendedItems,
      extendedText: event.extendedText,
      genreLevel1: event.genreLevel1,
      genreLevel2: event.genreLevel2,
    );
  }
  return event;
}

/// Parses the EPG plaintext into a guide. Services appear in
/// channel-list order; events in broadcast order. The copies of
/// one event carried by several sections (the basic / extended
/// split) are merged into a single event (plan 22).
EpgGuide parseEpgGuide(
  Uint8List plain,
  List<Channel> channels, {
  required int broadcastingType,
}) {
  final sections = _findSections(plain, channels);
  final byService = <int, Map<(int, DateTime), EpgEvent>>{};
  for (final section in sections) {
    final events = _parseSectionEvents(plain, section.offset + 14,
        section.offset + section.totalLength - 4);
    if (events.isEmpty) continue;
    final merged = byService.putIfAbsent(
        section.channel.serviceId, () => <(int, DateTime), EpgEvent>{});
    for (final event in events) {
      final key = (event.eventId, event.start);
      final existing = merged[key];
      merged[key] = existing == null ? event : _mergeCopies(existing, event);
    }
  }
  final services = <EpgServiceGuide>[];
  for (final ch in channels) {
    final merged = byService[ch.serviceId];
    if (merged == null || merged.isEmpty) continue;
    final events = merged.values
        .map((event) => broadcastingType == 3
            ? bsTitleFromExtended(event)
            : event)
        .toList()
      ..sort((a, b) {
        final byStart = a.start.compareTo(b.start);
        return byStart != 0 ? byStart : a.eventId.compareTo(b.eventId);
      });
    services.add(EpgServiceGuide(channel: ch, events: events));
  }
  return EpgGuide(broadcastingType: broadcastingType, services: services);
}

/// Combines two section copies of one broadcast event. The field
/// sets are disjoint by construction (titles live in the basic
/// sections, extended items in the extended sections), so each
/// field is taken from whichever copy carries it.
EpgEvent _mergeCopies(EpgEvent a, EpgEvent b) => EpgEvent(
      eventId: a.eventId,
      start: a.start,
      duration: a.duration,
      title: a.title ?? b.title,
      shortText: a.shortText ?? b.shortText,
      description: a.description ?? b.description,
      cast: a.cast ?? b.cast,
      extendedItems:
          a.extendedItems.isNotEmpty ? a.extendedItems : b.extendedItems,
      extendedText: a.extendedText ?? b.extendedText,
      genreLevel1: a.genreLevel1 ?? b.genreLevel1,
      genreLevel2: a.genreLevel2 ?? b.genreLevel2,
    );

List<EpgEvent> _parseSectionEvents(Uint8List plain, int start, int end) {
  final events = <EpgEvent>[];
  var p = start;
  while (p + 12 <= end) {
    final eventId = _u16be(plain, p);
    final mjd = _u16be(plain, p + 2);
    final hh = _bcd(plain[p + 4]);
    final mm = _bcd(plain[p + 5]);
    final ss = _bcd(plain[p + 6]);
    final dh = _bcd(plain[p + 7]);
    final dm = _bcd(plain[p + 8]);
    final ds = _bcd(plain[p + 9]);
    // The descriptors length is the low 12 bits; the high nibble
    // is running_status / free_CA_mode (zero in the measured data).
    final dlen = _u16be(plain, p + 10) & 0x0fff;
    if (p + 12 + dlen > end) break; // truncated tail: stop this section
    final fields = _parseDescriptors(plain, p + 12, p + 12 + dlen);
    events.add(EpgEvent(
      eventId: eventId,
      start: _eitStart(mjd, hh, mm, ss),
      duration: Duration(hours: dh, minutes: dm, seconds: ds),
      title: fields.title,
      shortText: fields.shortText,
      description: fields.description,
      cast: fields.cast,
      extendedItems: fields.items,
      extendedText: fields.extendedText,
      genreLevel1: fields.genreLevel1,
      genreLevel2: fields.genreLevel2,
    ));
    p += 12 + dlen;
  }
  return events;
}

class _EventFields {
  String? title;
  String? shortText;
  String? description;
  String? cast;
  String? extendedText;
  int? genreLevel1;
  int? genreLevel2;
  final items = <EpgExtendedItem>[];
}

String _text(List<int> bytes) =>
    normalizeBroadcastText(decodeAribB24(bytes));

_EventFields _parseDescriptors(Uint8List plain, int start, int end) {
  final fields = _EventFields();
  final extParts = <int, _ExtPart>{};
  var p = start;
  while (p + 2 <= end) {
    final tag = plain[p];
    final len = plain[p + 1];
    if (p + 2 + len > end) break;
    final body = plain.sublist(p + 2, p + 2 + len);
    switch (tag) {
      case 0x4d: // short_event_descriptor
        if (body.length >= 5 && _isJpn(body, 0)) {
          final nameLen = body[3];
          if (4 + nameLen <= body.length) {
            fields.title = _text(body.sublist(4, 4 + nameLen));
            final rest = body.sublist(4 + nameLen);
            if (rest.isNotEmpty) {
              final tl = rest[0];
              if (1 + tl <= rest.length) {
                fields.shortText = _text(rest.sublist(1, 1 + tl));
              }
            }
          }
        }
      case 0x4e: // extended_event_descriptor
        if (body.length >= 5 && _isJpn(body, 1)) {
          final number = body[0] >> 4;
          final part = _ExtPart();
          final loi = body[4];
          var ip = 5;
          final iend = 5 + loi;
          while (ip + 2 <= iend && ip + 2 <= body.length) {
            final dl = body[ip];
            if (ip + 1 + dl > body.length) break;
            final label = _text(body.sublist(ip + 1, ip + 1 + dl));
            ip += 1 + dl;
            if (ip >= body.length) break;
            final il = body[ip];
            if (ip + 1 + il > body.length) break;
            final value = _text(body.sublist(ip + 1, ip + 1 + il));
            ip += 1 + il;
            part.items.add(EpgExtendedItem(label: label, value: value));
          }
          if (ip < body.length) {
            final tl = body[ip];
            if (ip + 1 + tl <= body.length) {
              part.text = _text(body.sublist(ip + 1, ip + 1 + tl));
            }
          }
          extParts[number] = part;
        }
      case 0x54: // content_descriptor
        if (body.isNotEmpty) {
          fields.genreLevel1 = body[0] >> 4;
          fields.genreLevel2 = body[0] & 0x0f;
        }
    }
    p += 2 + len;
  }
  // Merge the extended parts in descriptor_number order; items
  // with the same label continue each other (split across parts).
  final numbers = extParts.keys.toList()..sort();
  final texts = <String>[];
  for (final n in numbers) {
    final part = extParts[n]!;
    for (final item in part.items) {
      if (fields.items.isNotEmpty && fields.items.last.label == item.label) {
        final last = fields.items.removeLast();
        fields.items.add(EpgExtendedItem(
            label: last.label, value: last.value + item.value));
      } else {
        fields.items.add(item);
      }
    }
    if (part.text != null && part.text!.isNotEmpty) texts.add(part.text!);
  }
  if (texts.isNotEmpty) fields.extendedText = texts.join();
  for (final item in fields.items) {
    if (item.label == '番組内容') {
      fields.description = item.value;
    } else if (item.label == '出演者') {
      fields.cast = item.value;
    }
  }
  fields.items.removeWhere(
      (i) => i.label == '番組内容' || i.label == '出演者');
  return fields;
}

bool _isJpn(List<int> body, int off) =>
    body.length >= off + 3 &&
    body[off] == 0x6a && // 'j'
    body[off + 1] == 0x70 && // 'p'
    body[off + 2] == 0x6e; // 'n'

class _ExtPart {
  final items = <EpgExtendedItem>[];
  String? text;
}

/// Adler-32 of [data] (the zlib stream trailer checksum).
int _adler32(List<int> data) {
  var a = 1;
  var b = 0;
  for (final byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Inflates the first zlib stream in [bytes] starting at [start],
/// returning its decompressed bytes and compressed length.
///
/// The length cannot be found by trial conversion: dart:io's
/// ZLibDecoder silently returns partial output for truncated
/// input instead of throwing. Instead the stream end is located
/// through its Adler-32 trailer — the end position is where the
/// four trailer bytes equal the Adler-32 of the decompressed
/// content (verified by an exact re-decode of that prefix).
(List<int>, int) _inflateFirstStream(List<int> bytes, int start) {
  final decoder = ZLibDecoder();
  final full = decoder.convert(bytes.sublist(start));
  final adler = _adler32(full);
  final trailer = [
    (adler >> 24) & 0xff,
    (adler >> 16) & 0xff,
    (adler >> 8) & 0xff,
    adler & 0xff,
  ];
  for (var end = start + 6; end <= bytes.length; end++) {
    if (bytes[end - 4] == trailer[0] &&
        bytes[end - 3] == trailer[1] &&
        bytes[end - 2] == trailer[2] &&
        bytes[end - 1] == trailer[3]) {
      final check = decoder.convert(bytes.sublist(start, end));
      if (_listEquals(check, full)) {
        return (full, end - start);
      }
    }
  }
  throw const FormatException('zlib stream trailer not found');
}

/// Standard PNG IEEE CRC-32 (reflected polynomial 0xEDB88320). Kept separate
/// from MPEG-2 [crc32Mpeg].
Uint32List _buildCrc32PngTable() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var bit = 0; bit < 8; bit++) {
      c = (c & 1) != 0 ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[i] = c;
  }
  return table;
}

final Uint32List _crc32PngTable = _buildCrc32PngTable();

int _crc32Png(List<int> data, [int start = 0, int? end]) {
  var c = 0xffffffff;
  final limit = end ?? data.length;
  for (var i = start; i < limit; i++) {
    c = _crc32PngTable[(c ^ data[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) & 0xffffffff;
}

/// ARIB STD-B24 / TR-B14 default 129-color CDT station logo palette (R, G, B, A).
List<({int r, int g, int b, int a})> _buildAribLogoClut() {
  final clut = <({int r, int g, int b, int a})>[];
  for (var i = 0; i < 8; i++) {
    clut.add((
      r: (i & 1) != 0 ? 0xff : 0x00,
      g: (i & 2) != 0 ? 0xff : 0x00,
      b: (i & 4) != 0 ? 0xff : 0x00,
      a: 0xff,
    ));
  }
  clut.add((r: 0x00, g: 0x00, b: 0x00, a: 0x00));
  for (var i = 1; i < 8; i++) {
    clut.add((
      r: (i & 1) != 0 ? 0xaa : 0x00,
      g: (i & 2) != 0 ? 0xaa : 0x00,
      b: (i & 4) != 0 ? 0xaa : 0x00,
      a: 0xff,
    ));
  }
  const levels = [0x00, 0x55, 0xaa, 0xff];
  for (final r in levels) {
    for (final g in levels) {
      for (final b in levels) {
        final allFull =
            (r == 0x00 || r == 0xff) &&
            (g == 0x00 || g == 0xff) &&
            (b == 0x00 || b == 0xff);
        final allHalf =
            (r == 0x00 || r == 0xaa) &&
            (g == 0x00 || g == 0xaa) &&
            (b == 0x00 || b == 0xaa);
        if (allFull || allHalf) continue;
        clut.add((r: r, g: g, b: b, a: 0xff));
      }
    }
  }
  final opaqueCount = clut.length;
  for (var i = 0; i < opaqueCount; i++) {
    if (i == 8) continue;
    final c = clut[i];
    clut.add((r: c.r, g: c.g, b: c.b, a: 0x80));
  }
  return clut;
}

final List<({int r, int g, int b, int a})> _aribLogoClut =
    _buildAribLogoClut();

final Map<int, Uint8List> _aribLogoPaletteChunksByCount = {};

Uint8List _buildPngChunk(String type, Uint8List body) {
  final out = Uint8List(12 + body.length);
  final view = ByteData.sublistView(out);
  view.setUint32(0, body.length);
  for (var i = 0; i < 4; i++) {
    out[4 + i] = type.codeUnitAt(i);
  }
  out.setRange(8, 8 + body.length, body);
  view.setUint32(8 + body.length, _crc32Png(out, 4, 8 + body.length));
  return out;
}

Uint8List _aribPaletteChunksForCount(int entryCount) {
  return _aribLogoPaletteChunksByCount.putIfAbsent(entryCount, () {
    final rgb = Uint8List(entryCount * 3);
    final alpha = Uint8List(entryCount);
    for (var i = 0; i < entryCount; i++) {
      final entry = _aribLogoClut[i];
      rgb[i * 3] = entry.r;
      rgb[i * 3 + 1] = entry.g;
      rgb[i * 3 + 2] = entry.b;
      alpha[i] = entry.a;
    }
    final plte = _buildPngChunk('PLTE', rgb);
    final trns = _buildPngChunk('tRNS', alpha);
    final combined = Uint8List(plte.length + trns.length);
    combined.setRange(0, plte.length, plte);
    combined.setRange(plte.length, combined.length, trns);
    return combined;
  });
}

/// Injects standard `PLTE` and `tRNS` chunks derived from the fixed ARIB CDT
/// CLUT immediately after `IHDR` when an indexed-color PNG lacks `PLTE`.
/// Standard PNGs (or non-indexed / already-paletted PNGs) are returned as-is.
Uint8List normalizeAribLogoPng(Uint8List png) {
  const afterIhdr = 33;
  if (png.length < afterIhdr + 12) return png;
  const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  for (var i = 0; i < 8; i++) {
    if (png[i] != sig[i]) return png;
  }
  if (png[8] != 0 ||
      png[9] != 0 ||
      png[10] != 0 ||
      png[11] != 13 ||
      png[12] != 0x49 ||
      png[13] != 0x48 ||
      png[14] != 0x44 ||
      png[15] != 0x52) {
    return png;
  }
  final bitDepth = png[24];
  final colorType = png[25];
  if (colorType != 3 ||
      (bitDepth != 1 && bitDepth != 2 && bitDepth != 4 && bitDepth != 8)) {
    return png;
  }
  var offset = afterIhdr;
  while (offset + 12 <= png.length) {
    final chunkLen =
        (png[offset] << 24) |
        (png[offset + 1] << 16) |
        (png[offset + 2] << 8) |
        png[offset + 3];
    if (chunkLen < 0 || chunkLen > png.length - offset - 12) break;
    final t0 = png[offset + 4];
    final t1 = png[offset + 5];
    final t2 = png[offset + 6];
    final t3 = png[offset + 7];
    if (t0 == 0x50 && t1 == 0x4c && t2 == 0x54 && t3 == 0x45) {
      return png;
    }
    if (t0 == 0x49 && t1 == 0x45 && t2 == 0x4e && t3 == 0x44) {
      break;
    }
    offset += 12 + chunkLen;
  }
  final entryCount = math.min(_aribLogoClut.length, 1 << bitDepth);
  final paletteChunks = _aribPaletteChunksForCount(entryCount);
  final out = Uint8List(png.length + paletteChunks.length);
  out.setRange(0, afterIhdr, png, 0);
  out.setRange(afterIhdr, afterIhdr + paletteChunks.length, paletteChunks);
  out.setRange(afterIhdr + paletteChunks.length, out.length, png, afterIhdr);
  return out;
}

/// Parses a `channelLogoDataGet` response into serviceId -> PNG
/// bytes. Records without a PNG (length field 0) are omitted, as
/// is the 8-byte file-header record.
Map<int, Uint8List> parseChannelLogos(List<int> rawResponse) {
  final data = deobfuscateEpgPayload(rawResponse);
  final logos = <int, Uint8List>{};
  var pos = 0;
  while (pos + 2 <= data.length) {
    if (data[pos] != 0x78) break; // not a zlib stream start
    final (List<int>, int) inflated;
    try {
      inflated = _inflateFirstStream(data, pos);
    } catch (_) {
      break; // truncated or corrupt tail: keep what we have
    }
    final (out, used) = inflated;
    if (used <= 0) break;
    pos += used;
    if (out.length < 20) continue; // file header record
    final declaredLen = _u16be(out, 2);
    if (declaredLen != out.length) continue;
    final serviceId = _u16be(out, 14);
    final pngLen = _u16be(out, 18);
    if (pngLen == 0 || 20 + pngLen > out.length) continue;
    final png = Uint8List.fromList(out.sublist(20, 20 + pngLen));
    if (png.length >= 4 && png[0] == 0x89 && png[1] == 0x50) {
      logos[serviceId] = normalizeAribLogoPng(png);
    }
  }
  return logos;
}

// ---------------------------------------------------------------------------
// EPG version table / EPGGet request format (plan 24)
// ---------------------------------------------------------------------------

/// One service of the binary EPG version table: the
/// (networkId, transportStreamId, serviceId) triple that keys the
/// unit-side EPG database.
class EpgServiceRef {
  const EpgServiceRef(
      this.networkId, this.transportStreamId, this.serviceId);

  final int networkId;
  final int transportStreamId;
  final int serviceId;

  @override
  bool operator ==(Object other) =>
      other is EpgServiceRef &&
      other.networkId == networkId &&
      other.transportStreamId == transportStreamId &&
      other.serviceId == serviceId;

  @override
  int get hashCode => Object.hash(networkId, transportStreamId, serviceId);

  @override
  String toString() =>
      'EpgServiceRef($networkId, $transportStreamId, $serviceId)';
}

/// Header size of the `EPGVersionInfoGet` binary version table.
const int epgVersionTableHeaderSize = 12;

/// Record size of the version table. Each record is the service
/// triple (three u16 BE), a flags u16 (0xc000 on every measured
/// record) and two 68-byte version blocks; the table is trailed by
/// an 8-byte footer that does not form a record.
const int epgVersionTableRecordSize = 144;

/// Enumerates the services of a version table, in table order.
///
/// Records are read from the end of the header while a whole record
/// fits and carries the measured flags value; anything else (the
/// footer, a truncated tail) ends the enumeration. The header's own
/// count field is NOT the record count (it reads 21 for the 20
/// measured terrestrial records), so it is deliberately not used.
List<EpgServiceRef> parseEpgVersionServices(List<int> versionTable) {
  final services = <EpgServiceRef>[];
  var offset = epgVersionTableHeaderSize;
  while (offset + epgVersionTableRecordSize <= versionTable.length) {
    if (_u16be(versionTable, offset + 6) != 0xc000) break;
    services.add(EpgServiceRef(
      _u16be(versionTable, offset),
      _u16be(versionTable, offset + 2),
      _u16be(versionTable, offset + 4),
    ));
    offset += epgVersionTableRecordSize;
  }
  return services;
}

/// BS EPG version-table scanner for satellite services.
///
/// The terrestrial table has contiguous 0xc000 records, whereas actual
/// satellite tables can have gaps and non-0xc000 flag values. Match the
/// complete service triple to an actual VIDEO channel on this nasne and
/// keep scanning to the end; do not mistake a gap for end-of-table.
/// Satellite flags are not yet decoded; no flag is used to infer reception.
List<EpgServiceRef> parseSatelliteEpgVersionServices(
    List<int> versionTable, List<Channel> channels) {
  final known = <(int, int, int)>{
    for (final ch in channels)
      if (ch.serviceType == 1)
        (ch.networkId, ch.transportStreamId, ch.serviceId),
  };
  final seen = <(int, int, int)>{};
  final out = <EpgServiceRef>[];
  for (var p = epgVersionTableHeaderSize;
      p + epgVersionTableRecordSize <= versionTable.length;
      p += epgVersionTableRecordSize) {
    final key = (
      _u16be(versionTable, p),
      _u16be(versionTable, p + 2),
      _u16be(versionTable, p + 4),
    );
    if (known.contains(key) && seen.add(key)) {
      out.add(EpgServiceRef(key.$1, key.$2, key.$3));
    }
  }
  return out;
}

/// BS channel columns include channels without an EIT section. The original
/// parser only lists services with an event; that hides channels entirely
/// and makes 'missing EPG' indistinguishable from 'missing channel'.
/// Only applies to BS; terrestrial behaviour and data are not changed.
EpgGuide completeBsEpgGuide(EpgGuide parsed, List<Channel> channels) {
  if (parsed.broadcastingType != 3) return parsed;
  final existing = <(int, int, int), EpgServiceGuide>{
    for (final service in parsed.services)
      (
        service.channel.networkId,
        service.channel.transportStreamId,
        service.channel.serviceId,
      ): service,
  };
  return EpgGuide(
    broadcastingType: parsed.broadcastingType,
    services: [
      for (final ch in channels)
        if (ch.serviceType == 1)
          existing[(ch.networkId, ch.transportStreamId, ch.serviceId)] ??
              EpgServiceGuide(channel: ch, events: const []),
    ],
  );
}

/// Header size of an `EPGGet` request body.
const int epgGetHeaderSize = 8;

/// Record size of an `EPGGet` request body.
const int epgGetRecordSize = 24;

/// Builds the binary body of an `chEpg/EPGGet` request (plan 24;
/// the format was recovered from the unit-side EPG job and verified
/// against the real unit):
///
/// - Header (8 bytes): bytes 0-3 unused by the job (byte 2 is
///   echoed into the response header), the record count as u16 BE
///   at +4, bytes 6-7 unused. The job accepts the file only when
///   its size is at least (count * 3 + 1) * 8 — exactly the size of
///   a well-formed body, 8 + 24 * count.
/// - One 24-byte record per service: the service triple (u16 BE
///   each), a linked-description flag byte at +6 (nonzero also
///   appends the service's LDT sections; none were stored on the
///   measured unit, so the flag changed nothing there), a pad byte
///   at +7, then two 8-byte segment bitmaps: basic (table_id
///   0x50/0x51 side) at +8 and extended (0x58/0x59 side) at +16.
///   Bit i of a bitmap (MSB first) requests segment i + 1 of the
///   64 segments (8 per day, 3 hours each, 8 days).
///
/// With both bitmaps all-ones the job returns every section the
/// unit's EPG database holds for the service — the complete
/// dataset. The job answers with an error (HTTP 500 at the WebAPI
/// surface) when a request selects no section at all.
Uint8List buildEpgGetBody(
  List<EpgServiceRef> services, {
  bool basic = true,
  bool extended = true,
  bool includeLinkedDescriptions = false,
}) {
  final out = Uint8List(epgGetHeaderSize + epgGetRecordSize * services.length);
  out[4] = (services.length >> 8) & 0xff;
  out[5] = services.length & 0xff;
  var offset = epgGetHeaderSize;
  for (final service in services) {
    _putU16be(out, offset, service.networkId);
    _putU16be(out, offset + 2, service.transportStreamId);
    _putU16be(out, offset + 4, service.serviceId);
    out[offset + 6] = includeLinkedDescriptions ? 1 : 0;
    if (basic) out.fillRange(offset + 8, offset + 16, 0xff);
    if (extended) out.fillRange(offset + 16, offset + 24, 0xff);
    offset += epgGetRecordSize;
  }
  return out;
}

void _putU16be(Uint8List out, int offset, int value) {
  out[offset] = (value >> 8) & 0xff;
  out[offset + 1] = value & 0xff;
}

/// Deobfuscates, inflates, and parses a binary `chEpg/EPGGet` response
/// payload into a normalized [EpgGuide]. Designed to be pure and safe to run on
/// a background isolate via `Isolate.run`.
EpgGuide parseEpgResponsePayload({
  required Uint8List rawResponse,
  required List<Channel> channels,
  required int broadcastingType,
}) {
  final plain = inflateEpgResponse(rawResponse);
  final parsed = parseEpgGuide(
    plain,
    channels,
    broadcastingType: broadcastingType,
  );
  return broadcastingType == 3
      ? completeBsEpgGuide(parsed, channels)
      : parsed;
}
