/// System Renewability Message (SRM) parsing and revocation checks.
///
/// Port of pydtcpip's `dtcp/srm.py` (MIT, (c) tsukumijima).
/// Revocations accumulate across generations into a single range
/// list. The SRM is DTLA-signed public data: it carries no secrets
/// and is persisted in the app's regular store (plan 26.4).
library;

import 'dart:typed_data';

import '../errors.dart';
import 'dtcp_crypto.dart';

const int _signatureLength = 40;

class Srm {
  Srm._(this.version, this.generation, this.data, this.revokedRanges);

  /// SRM version (header bytes 2..3).
  final int version;

  /// Last generation present (0 when only the first part exists).
  final int generation;

  /// The raw SRM bytes (kept for forwarding to sources and for the
  /// length tiebreak in [isNewerThan]).
  final Uint8List data;

  /// Cumulative revoked device ID ranges, (first, last) inclusive.
  /// Individual IDs are stored as (id, id).
  final List<(int, int)> revokedRanges;

  bool isRevoked(int deviceId) {
    for (final (first, last) in revokedRanges) {
      if (deviceId >= first && deviceId <= last) return true;
    }
    return false;
  }

  /// Throws when [certificate]'s device ID is revoked.
  void checkDevice(List<int> certificate) {
    if (isRevoked(deviceIdOf(certificate))) {
      throw NasneError.parse(
        'dtcp:srm',
        cause: 'the device certificate is revoked by the SRM',
      );
    }
  }

  /// Newer = higher version, then longer data (more generations),
  /// as in the reference implementation.
  bool isNewerThan(Srm other) =>
      version > other.version ||
      (version == other.version && data.length > other.data.length);

  /// Parses and verifies an SRM blob. Each generation's length must
  /// reach its DTLA signature, which is checked over everything
  /// before it (cumulative). Generation size limits follow the
  /// reference (124 bytes for generation 0, 978 afterwards).
  static Srm parse(List<int> data, {List<Uint8List> authorityKeys = const []}) {
    NasneError parseError(String detail) =>
        NasneError.parse('dtcp:srm', cause: detail);

    if (data.length < 4) throw parseError('SRM is too short');
    final maxGeneration = data[0];
    if (data[1] != 0) throw parseError('invalid SRM header');
    final version = (data[2] << 8) | data[3];

    final ranges = <(int, int)>[];
    var generation = -1;
    var offset = 4;
    while (offset < data.length) {
      generation++;
      if (generation > maxGeneration) {
        throw parseError('SRM generation count exceeds the header');
      }
      if (offset + 2 > data.length) {
        throw parseError('SRM ends inside a generation header');
      }
      final generationLength = (data[offset] << 8) | data[offset + 1];
      final maximumSize = generation == 0 ? 124 : 978;
      if (generationLength < 2 + _signatureLength ||
          generationLength > maximumSize) {
        throw parseError('SRM generation has an invalid length');
      }
      final generationEnd = offset + generationLength;
      if (generationEnd > data.length) {
        throw parseError('SRM generation overruns the data');
      }
      final signatureStart = generationEnd - _signatureLength;
      if (!verifyAuthoritySignature(
        data.sublist(0, signatureStart),
        data.sublist(signatureStart, generationEnd),
        authorityKeys: authorityKeys,
      )) {
        throw parseError('SRM signature verification failed');
      }

      var pos = offset + 2;
      while (pos < signatureStart) {
        final entryHeader = data[pos];
        pos++;
        final entryType = entryHeader >> 5;
        final entryCount = entryHeader & 0x1F;
        if (entryType > 1) throw parseError('unknown SRM entry type');
        for (var i = 0; i < entryCount; i++) {
          if (entryType == 0) {
            if (pos + 5 > signatureStart) {
              throw parseError('SRM entry overruns the generation');
            }
            final id = bytesToBigInt(data.sublist(pos, pos + 5)).toInt();
            ranges.add((id, id));
            pos += 5;
          } else {
            if (pos + 7 > signatureStart) {
              throw parseError('SRM entry overruns the generation');
            }
            final start = bytesToBigInt(data.sublist(pos, pos + 5)).toInt();
            final span = (data[pos + 5] << 8) | data[pos + 6];
            ranges.add((start, start + span));
            pos += 7;
          }
        }
      }
      offset = generationEnd;
    }
    if (generation < 0) {
      throw parseError('SRM contains no signed generation');
    }
    return Srm._(
      version,
      generation,
      Uint8List.fromList(data),
      ranges,
    );
  }
}
