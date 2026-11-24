/// ARIB STD-B24 text decoder (plan 21).
///
/// EPG programme text delivered by `chEpg/EPGGet` is ARIB STD-B24
/// ("8-unit code") text: four graphic sets (G0-G3) with locking and
/// single shifts, JIS X 0208 / X 0213 kanji, JIS X 0201 kana, and
/// the ARIB additional characters (rows 85+, the programme marks).
/// This is a Dart port of the decoder in the `@danything/arib`
/// package (MIT License, https://github.com/danything/denpa),
/// validated byte-for-byte against the reference implementation
/// over the full live EPG corpus (plan 21). Table data lives in
/// arib_b24_tables.dart (same provenance).
///
/// The decoder never throws on malformed input: undecodable cells
/// become U+25A1 (□), mirroring the reference behaviour, so one bad
/// descriptor cannot sink a whole programme guide.
///
/// Output is broadcast-faithful: alphanumeric characters at the
/// standard size are fullwidth, and ARIB programme marks come out
/// as their regular Unicode code points. Display normalisation
/// (bracketed mark labels) is applied by the caller through
/// normalizeBroadcastText, as for the JSON paths (plan 16.1).
library;

import 'dart:convert';

import 'arib_b24_tables.dart';

/// Decodes one ARIB STD-B24 string (a descriptor text field).
String decodeAribB24(List<int> data) => _AribB24Decoder().decode(data);

final _sharedCellDecoder = _AribB24Decoder();

/// Decodes a single 1-byte ARIB STD-B24 graphic cell for ESC final byte [finalByte].
String decodeAribB24OneByteCell(
  int code,
  int finalByte, {
  required bool halfWidth,
}) {
  final set = _charsets[finalByte];
  if (set == null || set.bytes != 1 || set.kind == 'blank') return '';
  final masked = code & 0x7F;
  if (masked < 0x21 || masked > 0x7E) return '';
  return _sharedCellDecoder._oneByte(masked, set.kind, halfWidth);
}

/// Decodes a single 2-byte ARIB STD-B24 graphic cell for ESC final byte [finalByte].
String decodeAribB24TwoByteCell(int code, int finalByte) {
  final set = _charsets[finalByte];
  if (set == null || set.bytes != 2 || set.kind == 'blank') return '';
  final high = (code >> 8) & 0x7F;
  final low = code & 0x7F;
  if (high < 0x21 || high > 0x7E || low < 0x21 || low > 0x7E) return '';
  return _sharedCellDecoder._twoByte((high << 8) | low, set.kind);
}

class _Charset {
  const _Charset(this.bytes, this.kind);
  final int bytes;
  final String kind;
}

const _kanji = _Charset(2, 'kanji');
const _plane1 = _Charset(2, 'plane1');
const _plane2 = _Charset(2, 'plane2');
const _alnum = _Charset(1, 'alnum');
const _hiragana = _Charset(1, 'hiragana');
const _katakana = _Charset(1, 'katakana');
const _ank = _Charset(1, 'ank');
const _mosaic = _Charset(1, 'blank');
const _blank2 = _Charset(2, 'blank');

/// ESC designation final byte -> graphic set (reference table).
const Map<int, _Charset> _charsets = {
  0x42: _kanji, // JIS X 0208 kanji
  0x39: _plane1, // JIS compatible kanji plane 1 (X 0213)
  0x3a: _plane2, // JIS compatible kanji plane 2
  0x3b: _kanji, // ARIB additional symbols (kanji table + gaiji rows)
  0x4a: _alnum,
  0x30: _hiragana,
  0x31: _katakana,
  0x49: _ank, // JIS X 0201 katakana (halfwidth)
  0x36: _alnum, // proportional alnum
  0x37: _hiragana,
  0x38: _katakana,
  0x32: _mosaic,
  0x33: _mosaic,
  0x34: _mosaic,
  0x35: _mosaic,
};

/// C0 controls that carry parameter bytes (reference table).
const Map<int, int> _c0Params = {0x16: 1, 0x1c: 2};

/// C1 controls that carry parameter bytes (reference table).
const Map<int, int> _c1Params = {
  0x8b: 1, // SZX
  0x90: 1, // COL
  0x91: 1, // FLC
  0x92: 1, // CDC
  0x93: 1, // POL
  0x94: 1, // WMM
  0x97: 1, // HLC
  0x98: 1, // RPC
  0x9d: 2, // TIME
};

/// Locking shifts after ESC: byte -> [new GL, new GR] (null = keep).
const Map<int, List<int?>> _locking = {
  0x6e: [2, null], // LS2
  0x6f: [3, null], // LS3
  0x7e: [null, 1], // LS1R
  0x7d: [null, 2], // LS2R
  0x7c: [null, 3], // LS3R
};

const String _unknown = '□'; // U+25A1
const String _wideSpace = '　'; // U+3000

/// Lazily decoded character tables (arib_b24_tables.dart).
class _Tables {
  _Tables._(this._json);

  final Map<String, dynamic> _json;
  static _Tables? _instance;
  static _Tables get instance =>
      _instance ??= _Tables._(jsonDecode(aribB24TablesJson) as Map<String, dynamic>);

  late final List<int> hiragana = (_json['hiragana'] as String).runes.toList();
  late final List<int> katakana = (_json['katakana'] as String).runes.toList();
  late final List<int> ank = (_json['ank'] as String).runes.toList();
  late final List<int> plane1High =
      (_json['plane1High'] as String).runes.toList();
  late final List<int> kanjiBase =
      (_json['kanjiBase'] as List).cast<int>();
  late final Map<int, String> x0213 = {
    for (final e in (_json['x0213'] as Map<String, dynamic>).entries)
      int.parse(e.key): e.value as String,
  };
  late final Map<int, String> gaiji = {
    for (final e in (_json['gaiji'] as Map<String, dynamic>).entries)
      int.parse(e.key): e.value as String,
  };
  late final Map<int, List<int>> plane2 = {
    for (final e in (_json['plane2'] as Map<String, dynamic>).entries)
      int.parse(e.key): (e.value as String).runes.toList(),
  };
}

class _AribB24Decoder {
  final _Tables _t = _Tables.instance;
  final Map<int, String> _cache = {};

  String decode(List<int> data) {
    final g = <_Charset>[_kanji, _alnum, _hiragana, _katakana];
    var gl = 0;
    var gr = 2;
    int? single;
    var half = false;
    final out = StringBuffer();
    var at = 0;

    void designate(int target, _Charset? set) {
      if (set != null && target >= 0 && target <= 3) g[target] = set;
    }

    while (at < data.length) {
      final byte = data[at];
      // --- C0 controls -------------------------------------------------
      if (byte <= 0x20 || byte == 0x7f || byte == 0xa0 || byte == 0xff) {
        at++;
        switch (byte) {
          case 0x0d: // APR (line break; a following LF is the same break)
            out.write('\n');
            if (at < data.length && data[at] == 0x0a) at++;
          case 0x0a: // APD
            out.write('\n');
          case 0x20: // SP (width follows the current character size)
          case 0xa0:
            out.write(half ? ' ' : _wideSpace);
          case 0x0e: // LS1
            gl = 1;
          case 0x0f: // LS0
            gl = 0;
          case 0x19: // SS2
            single = 2;
          case 0x1d: // SS3
            single = 3;
          case 0x1b: // ESC
            at = _afterEscape(data, at, designate, (l, r) {
              if (l != null) gl = l;
              if (r != null) gr = r;
            });
          default:
            at += _c0Params[byte] ?? 0;
        }
        continue;
      }
      // --- C1 controls -------------------------------------------------
      if (byte >= 0x80 && byte <= 0x9f) {
        at++;
        if (byte == 0x9b) {
          // CSI: skip until the final byte (>= 0x40).
          while (at < data.length && data[at] < 0x40) {
            at++;
          }
          at++;
          continue;
        }
        if (byte == 0x95) {
          // MACRO: terminated by 0x4f.
          while (at < data.length && data[at] != 0x4f) {
            at++;
          }
          at++;
          continue;
        }
        if (byte == 0x88 || byte == 0x89) {
          half = true; // SSZ / MSZ
        } else if (byte == 0x8a) {
          half = false; // NSZ
        } else if (byte == 0x8b) {
          half = at < data.length && data[at] == 0x60; // SZX (tiny only)
        }
        var params = _c1Params[byte] ?? 0;
        if ((byte == 0x90 || byte == 0x92) &&
            at < data.length &&
            data[at] == 0x20) {
          params = 2;
        }
        at += params;
        continue;
      }
      // --- graphic characters ------------------------------------------
      final area = single ?? (byte >= 0xa1 ? gr : gl);
      single = null;
      final set = g[area];
      final first = byte & 0x7f;
      if (set.bytes == 2) {
        final second = (at + 1 < data.length ? data[at + 1] : 0) & 0x7f;
        at += 2;
        if (second < 0x21) continue;
        if (set.kind != 'blank') {
          out.write(_twoByte((first << 8) | second, set.kind));
        }
        continue;
      }
      at += 1;
      out.write(_oneByte(first, set.kind, half));
    }
    return out.toString();
  }

  int _afterEscape(
    List<int> data,
    int at,
    void Function(int, _Charset?) designate,
    void Function(int?, int?) invoke,
  ) {
    if (at >= data.length) return at + 1;
    final byte = data[at];
    final shift = _locking[byte];
    if (shift != null) {
      invoke(shift[0], shift[1]);
      return at + 1;
    }
    if (byte == 0x24) {
      // Two-byte set designation; ESC $ F is the G0 shorthand.
      if (at + 1 >= data.length) return at + 2;
      final next = data[at + 1];
      if (next >= 0x28 && next <= 0x2b) {
        if (at + 2 < data.length && data[at + 2] == 0x20) {
          designate(next - 0x28, _blank2); // two-byte DRCS: unreadable
          return at + 4;
        }
        designate(
            next - 0x28, at + 2 < data.length ? _charsets[data[at + 2]] : null);
        return at + 3;
      }
      designate(0, _charsets[next]);
      return at + 2;
    }
    if (byte >= 0x28 && byte <= 0x2b) {
      // One-byte set designation.
      final target = byte - 0x28;
      if (at + 1 < data.length && data[at + 1] == 0x20) {
        designate(target, _mosaic); // one-byte DRCS
        return at + 3;
      }
      designate(target, at + 1 < data.length ? _charsets[data[at + 1]] : null);
      return at + 2;
    }
    // Unknown escape: skip one byte and keep reading.
    return at + 1;
  }

  String _oneByte(int code, String kind, bool half) {
    switch (kind) {
      case 'alnum':
        // ASCII layout; fullwidth at the standard size.
        return String.fromCharCode(half ? code : code + 0xfee0);
      case 'hiragana':
        if (code >= 0x74 && code <= 0x76) return ''; // reserved cells
        final i = code - 0x21;
        return i >= 0 && i < _t.hiragana.length
            ? String.fromCharCode(_t.hiragana[i])
            : '';
      case 'katakana':
        final i = code - 0x21;
        return i >= 0 && i < _t.katakana.length
            ? String.fromCharCode(_t.katakana[i])
            : '';
      case 'ank':
        final i = code - 0x21;
        if (i < 0 || i >= _t.ank.length) return '';
        final c = _t.ank[i];
        return c == 0xfffd ? '' : String.fromCharCode(c);
      default: // mosaic / DRCS: figures, no text
        return '';
    }
  }

  String _twoByte(int code, String kind) {
    final key = kind == 'plane2'
        ? code | 0x10000
        : kind == 'plane1' && (code >> 8) >= 0x75
            ? code | 0x20000
            : code;
    final cached = _cache[key];
    if (cached != null) return cached;
    final high = code >> 8;
    final low = code & 0xff;
    final ku = high - 0x20;
    final cell = (ku - 1) * 94 + low - 0x21;
    final String decoded;
    if (low > 0x7e) {
      decoded = '';
    } else if (kind == 'plane2') {
      final row = _t.plane2[ku];
      decoded = row != null && low - 0x21 < row.length
          ? String.fromCharCode(row[low - 0x21])
          : '';
    } else if (ku >= 85) {
      // ARIB additional characters: own tables only.
      if (kind == 'plane1') {
        final i = cell - 84 * 94;
        decoded = i >= 0 && i < _t.plane1High.length
            ? String.fromCharCode(_t.plane1High[i])
            : '';
      } else {
        decoded = _t.gaiji[code] ?? '';
      }
    } else {
      final base = cell >= 0 && cell < _t.kanjiBase.length
          ? _t.kanjiBase[cell]
          : 0;
      decoded = base != 0
          ? String.fromCharCode(base)
          : (_t.x0213[cell] ?? '');
    }
    final text = decoded.isEmpty || decoded.contains('�') ? _unknown : decoded;
    _cache[key] = text;
    return text;
  }
}
