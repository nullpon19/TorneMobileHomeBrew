/// DTCP-IP cryptography: the DTCP elliptic curve, ECDSA (RFC 6979
/// deterministic, SHA-1), ECDH, device-certificate verification and
/// content-key derivation, plus AES-128 primitives.
///
/// This is a Dart port of pydtcpip's `dtcp/crypto.py` (pydtcpip is
/// MIT-licensed, (c) tsukumijima; see https://github.com/tsukumijima/pydtcpip).
/// The curve parameters, DTLA authority public keys, E-EMI constants
/// and the derivation construction are taken from that implementation,
/// which is verified against real devices; the port is anchored to it
/// by known-answer tests (test/dtcp_crypto_test.dart).
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart' as pc;

import '../errors.dart';
import 'native_aes.dart';

// ---------------------------------------------------------------------------
// Byte / BigInt helpers
// ---------------------------------------------------------------------------

BigInt bytesToBigInt(List<int> bytes) {
  var value = BigInt.zero;
  for (final b in bytes) {
    value = (value << 8) | BigInt.from(b & 0xFF);
  }
  return value;
}

/// Big-endian encoding of [value] in exactly [length] bytes.
Uint8List bigIntToBytes(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xFF)).toInt();
    v = v >> 8;
  }
  if (v != BigInt.zero) {
    throw ArgumentError('value does not fit in $length bytes');
  }
  return out;
}

Uint8List hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List sha1Bytes(List<int> data) =>
    Uint8List.fromList(crypto.sha1.convert(data).bytes);

Uint8List _hmacSha1(List<int> key, List<int> data) =>
    Uint8List.fromList(crypto.Hmac(crypto.sha1, key).convert(data).bytes);

// ---------------------------------------------------------------------------
// The DTCP curve (160-bit class; NOT SECP160R1, plan 26.5)
// ---------------------------------------------------------------------------

/// Domain parameters of the DTCP elliptic curve over Fp.
abstract final class DtcpCurve {
  static final BigInt p = BigInt.parse(
    '94A8E16AAD4F50EFE29B9D5C0C0B6D481B27DE53',
    radix: 16,
  );
  static final BigInt a = BigInt.parse(
    '94A8E16AAD4F50EFE29B9D5C0C0B6D481B27DE50',
    radix: 16,
  );
  static final BigInt b = BigInt.parse(
    '04FD918E5B0C4513FA3EF3033FE08F07C3B08C76D',
    radix: 16,
  );
  static final BigInt order = BigInt.parse(
    '02278C8AD247A46B5C53DE4CC9A0072488F028A3',
    radix: 16,
  );
  static final EcPoint generator = EcPoint(
    BigInt.parse('078668913DEAB22759E587EB393D7DA46CE24B196', radix: 16),
    BigInt.parse('4D2BA996A7E3D9AF4D266AFE00443B95D6870606', radix: 16),
  );

  /// Coordinate / scalar size in bytes.
  static const int size = 20;
}

/// A point on [DtcpCurve]; the point at infinity has null coordinates.
class EcPoint {
  const EcPoint(this.x, this.y) : isInfinity = false;
  const EcPoint.infinity() : x = null, y = null, isInfinity = true;

  final BigInt? x;
  final BigInt? y;
  final bool isInfinity;

  bool get isOnCurve {
    if (isInfinity) return true;
    final lhs = (y! * y!) % DtcpCurve.p;
    final rhs = (x! * x! * x! + DtcpCurve.a * x! + DtcpCurve.b) % DtcpCurve.p;
    return lhs == rhs;
  }

  /// The 40-byte X||Y encoding used by certificates and AKE payloads.
  Uint8List toBytes() {
    if (isInfinity) throw StateError('cannot encode the point at infinity');
    return Uint8List.fromList([
      ...bigIntToBytes(x!, DtcpCurve.size),
      ...bigIntToBytes(y!, DtcpCurve.size),
    ]);
  }

  /// Decodes a 40-byte X||Y encoding; null when the point is invalid.
  static EcPoint? fromBytes(List<int> bytes) {
    if (bytes.length != DtcpCurve.size * 2) return null;
    final point = EcPoint(
      bytesToBigInt(bytes.sublist(0, DtcpCurve.size)),
      bytesToBigInt(bytes.sublist(DtcpCurve.size)),
    );
    if (point.x! >= DtcpCurve.p || point.y! >= DtcpCurve.p) return null;
    return point.isOnCurve ? point : null;
  }

  EcPoint operator +(EcPoint other) {
    if (isInfinity) return other;
    if (other.isInfinity) return this;
    final p = DtcpCurve.p;
    BigInt slope;
    if (x == other.x) {
      if ((y! + other.y!) % p == BigInt.zero) {
        return const EcPoint.infinity();
      }
      // Point doubling.
      slope =
          ((BigInt.from(3) * x! * x! + DtcpCurve.a) *
              ((BigInt.two * y!) % p).modInverse(p)) %
          p;
    } else {
      slope = ((other.y! - y!) % p) * ((other.x! - x!) % p).modInverse(p) % p;
    }
    final rx = (slope * slope - x! - other.x!) % p;
    final ry = (slope * (x! - rx) - y!) % p;
    return EcPoint(rx, ry);
  }

  /// Scalar multiplication (double-and-add).
  EcPoint operator *(BigInt scalar) {
    var k = scalar % DtcpCurve.order;
    var result = const EcPoint.infinity();
    var addend = this;
    while (k > BigInt.zero) {
      if (k.isOdd) result = result + addend;
      addend = addend + addend;
      k = k >> 1;
    }
    return result;
  }

  @override
  bool operator ==(Object other) =>
      other is EcPoint &&
      other.isInfinity == isInfinity &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(x, y, isInfinity);
}

/// A uniformly random scalar in [1, order) for ephemeral AKE keys.
BigInt generateEphemeralScalar() {
  final random = Random.secure();
  while (true) {
    final bytes = Uint8List(DtcpCurve.size);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    final value = bytesToBigInt(bytes);
    if (value > BigInt.zero && value < DtcpCurve.order) return value;
  }
}

// ---------------------------------------------------------------------------
// ECDSA with SHA-1 (verification) and RFC 6979 deterministic signing,
// mirroring python-ecdsa as used by pydtcpip.
// ---------------------------------------------------------------------------

int get _qlen => DtcpCurve.order.bitLength;

/// bits2int with truncation to the order bit length (FIPS 186 style,
/// as python-ecdsa's _truncate_and_convert_digest with allow_truncate).
BigInt _hashToInt(Uint8List digest) {
  var value = bytesToBigInt(digest);
  final excess = digest.length * 8 - _qlen;
  if (excess > 0) value = value >> excess;
  return value;
}

/// Verifies a 40-byte (r||s) ECDSA-SHA1 signature over [data].
bool ecdsaVerify(EcPoint publicKey, List<int> data, List<int> signature) {
  if (signature.length != DtcpCurve.size * 2) return false;
  final n = DtcpCurve.order;
  final r = bytesToBigInt(signature.sublist(0, DtcpCurve.size));
  final s = bytesToBigInt(signature.sublist(DtcpCurve.size));
  if (r <= BigInt.zero || r >= n || s <= BigInt.zero || s >= n) return false;
  final z = _hashToInt(sha1Bytes(data));
  final w = s.modInverse(n);
  final u1 = (z * w) % n;
  final u2 = (r * w) % n;
  final point = DtcpCurve.generator * u1 + publicKey * u2;
  if (point.isInfinity) return false;
  return point.x! % n == r;
}

/// RFC 6979 deterministic nonce generation (HMAC-SHA1), following
/// python-ecdsa's rfc6979.generate_k. [retryGen] skips that many valid
/// candidates (used only after an r == 0 / s == 0 retry).
BigInt _rfc6979GenerateK(BigInt priv, Uint8List digest, int retryGen) {
  final n = DtcpCurve.order;
  const holen = 20; // SHA-1 size
  final rolen = (_qlen + 7) ~/ 8;

  // bits2octets(digest)
  var z = _hashToInt(digest);
  if (z >= n) z -= n;
  final bx = Uint8List.fromList([
    ...bigIntToBytes(priv, rolen),
    ...bigIntToBytes(z, rolen),
  ]);

  var v = Uint8List.fromList(List.filled(holen, 0x01));
  var k = Uint8List.fromList(List.filled(holen, 0x00));
  k = _hmacSha1(k, [...v, 0x00, ...bx]);
  v = _hmacSha1(k, v);
  k = _hmacSha1(k, [...v, 0x01, ...bx]);
  v = _hmacSha1(k, v);

  var skip = retryGen;
  while (true) {
    v = _hmacSha1(k, v);
    final candidate = _hashToInt(v);
    if (candidate >= BigInt.one && candidate < n) {
      if (skip == 0) return candidate;
      skip--;
    }
    k = _hmacSha1(k, [...v, 0x00]);
    v = _hmacSha1(k, v);
  }
}

/// Signs [data] with ECDSA-SHA1 and an RFC 6979 deterministic nonce,
/// returning the 40-byte (r||s) encoding. Byte-identical to
/// python-ecdsa's sign_deterministic for the same key and data.
Uint8List ecdsaSignDeterministic(BigInt priv, List<int> data) {
  final n = DtcpCurve.order;
  final digest = sha1Bytes(data);
  final z = _hashToInt(digest);
  var retryGen = 0;
  while (true) {
    final k = _rfc6979GenerateK(priv, digest, retryGen);
    final r = (DtcpCurve.generator * k).x! % n;
    if (r == BigInt.zero) {
      retryGen++;
      continue;
    }
    final s = (k.modInverse(n) * (z + priv * r % n)) % n;
    if (s == BigInt.zero) {
      retryGen++;
      continue;
    }
    return Uint8List.fromList([
      ...bigIntToBytes(r, DtcpCurve.size),
      ...bigIntToBytes(s, DtcpCurve.size),
    ]);
  }
}

/// ECDH: the shared point's x coordinate as 20 big-endian bytes
/// (python-ecdsa's generate_sharedsecret_bytes).
Uint8List ecdhSharedSecret(BigInt priv, EcPoint peerPublic) {
  final shared = peerPublic * priv;
  if (shared.isInfinity) {
    throw NasneError.validation('dtcp:crypto', 'ECDH failed');
  }
  return bigIntToBytes(shared.x!, DtcpCurve.size);
}

// ---------------------------------------------------------------------------
// AES-128 (via pointycastle; ECB block op + manual CBC chaining)
// ---------------------------------------------------------------------------

pc.AESEngine _aesEngine(List<int> key, bool encrypt) =>
    pc.AESEngine()..init(encrypt, pc.KeyParameter(Uint8List.fromList(key)));

/// One AES-128 block (ECB primitive).
Uint8List aesBlock(List<int> key, List<int> block16, {required bool encrypt}) {
  final engine = _aesEngine(key, encrypt);
  final out = Uint8List(16);
  engine.processBlock(Uint8List.fromList(block16), 0, out, 0);
  return out;
}

/// Streaming AES-128-CBC decryptor (plan 30): the CBC chain is
/// carried across calls, so ciphertext can be decrypted block by
/// block as it arrives instead of after a whole PCP packet has
/// been buffered. CBC decryption only ever needs the previous
/// ciphertext block, which is what makes this possible; the
/// whole-buffer [aesCbcDecrypt] below is a thin wrapper over it.
class AesCbcDecryptor {
  AesCbcDecryptor(List<int> key, List<int> iv, {NativeAesBackend? nativeBackend})
    : _chain = Uint8List.fromList(iv),
      _native = _resolveNative(key, iv, nativeBackend) {
    final native = _native;
    if (native != null) {
      _nativeRk = native.expandDecKey(key);
      _engine = null;
    } else {
      _nativeRk = null;
      _engine = _aesEngine(key, false);
    }
  }

  static NativeAesBackend? _resolveNative(
    List<int> key,
    List<int> iv,
    NativeAesBackend? explicit,
  ) {
    if (key.length != 16 || iv.length != 16) return null;
    return explicit ?? NativeAesBackend.instance;
  }

  final NativeAesBackend? _native;
  late final Uint32List? _nativeRk;
  late final pc.AESEngine? _engine;
  final Uint8List _chain;
  final Uint8List _block = Uint8List(16);

  /// Decrypts [length] bytes of [data] starting at [offset];
  /// [length] must be a multiple of 16. Returns a fresh buffer.
  Uint8List decryptBlocks(Uint8List data, int offset, int length) {
    if (length == 0) return Uint8List(0);
    final native = _native;
    final rk = _nativeRk;
    if (native != null && rk != null) {
      return native.decryptCbc(rk, _chain, data, offset, length);
    }
    final engine = _engine!;
    final out = Uint8List(length);
    final scratch = Uint8List(16);
    for (var done = 0; done < length; done += 16) {
      scratch.setRange(0, 16, data, offset + done);
      engine.processBlock(data, offset + done, _block, 0);
      for (var i = 0; i < 16; i++) {
        out[done + i] = _block[i] ^ _chain[i];
      }
      _chain.setRange(0, 16, scratch);
    }
    return out;
  }
}

/// AES-128-CBC over a multiple-of-16 input, no padding (PCP contents
/// are padded by the sender; padding is stripped by length, as in
/// pydtcpip's decrypt_packet).
///
/// The input is converted to a [Uint8List] ONCE and the block engine
/// is driven by offsets. The first implementation converted the
/// whole input inside the per-block loop, which made decrypting one
/// real 1 MiB PCP packet an O(n^2) copy loop (plan 29).
Uint8List aesCbcDecrypt(List<int> key, List<int> iv, List<int> data) {
  final input = data is Uint8List ? data : Uint8List.fromList(data);
  return AesCbcDecryptor(key, iv).decryptBlocks(input, 0, input.length);
}

Uint8List aesCbcEncrypt(List<int> key, List<int> iv, List<int> data) {
  final engine = _aesEngine(key, true);
  final input = data is Uint8List ? data : Uint8List.fromList(data);
  final out = Uint8List(input.length);
  var chain = Uint8List.fromList(iv);
  final block = Uint8List(16);
  for (var offset = 0; offset < input.length; offset += 16) {
    for (var i = 0; i < 16; i++) {
      block[i] = input[offset + i] ^ chain[i];
    }
    engine.processBlock(block, 0, out, offset);
    chain = Uint8List.fromList(out.sublist(offset, offset + 16));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Certificates and credentials (pydtcpip crypto.py port)
// ---------------------------------------------------------------------------

/// DTLA authority public keys (certificate / SRM signature
/// verification). Either key may verify a given signature.
final List<Uint8List> dtlaAuthorityKeys = [
  hexToBytes(
    '6e6e94c45dbedd467e42b789cce95cd19abcc2cc35d26bc0dff1dfeb2857088e052c5d9b2b339ad5',
  ),
  hexToBytes(
    '23b8461648aa748babae9d9bd905c7ab40ea8efa743f1b3bb1fc17fbb952ad4f84f1f39a886a59b7',
  ),
];

/// Verifies a DTLA signature (40-byte r||s ECDSA-SHA1) over [data]
/// against any of [authorityKeys].
bool verifyAuthoritySignature(
  List<int> data,
  List<int> signature, {
  List<Uint8List> authorityKeys = const [],
}) {
  final keys = authorityKeys.isEmpty ? dtlaAuthorityKeys : authorityKeys;
  for (final keyBytes in keys) {
    final key = EcPoint.fromBytes(keyBytes);
    if (key == null) continue;
    if (ecdsaVerify(key, data, signature)) return true;
  }
  return false;
}

/// Verifies an 88-byte baseline device certificate and returns its
/// public key. Throws a validation NasneError on any failure.
EcPoint verifyCertificate(
  List<int> certificate, {
  List<Uint8List> authorityKeys = const [],
}) {
  if (certificate.length != 88 ||
      certificate[0] != 1 ||
      (certificate[1] >> 4) > 1) {
    throw NasneError.validation(
      'dtcp:certificate',
      'not an 88-byte DTCP baseline certificate',
    );
  }
  if (!verifyAuthoritySignature(
    certificate.sublist(0, 48),
    certificate.sublist(48),
    authorityKeys: authorityKeys,
  )) {
    throw NasneError.validation(
      'dtcp:certificate',
      'DTLA signature verification failed',
    );
  }
  final publicKey = EcPoint.fromBytes(certificate.sublist(8, 48));
  if (publicKey == null) {
    throw NasneError.validation(
      'dtcp:certificate',
      'certificate contains an invalid public key',
    );
  }
  return publicKey;
}

/// The 5-byte device ID used for SRM revocation checks.
int deviceIdOf(List<int> certificate) =>
    bytesToBigInt(certificate.sublist(3, 8)).toInt();

/// A device certificate + private key pair for DTCP-IP mutual
/// authentication. Construction verifies the certificate's DTLA
/// signature and that the private key matches its public key (the
/// same gates as pydtcpip's DeviceCredentials). The byte values are
/// never logged or displayed by this class.
class DeviceCredentials {
  DeviceCredentials({
    required List<int> certificate,
    required List<int> privateKey,
    List<Uint8List> authorityKeys = const [],
  }) : certificate = Uint8List.fromList(certificate),
       privateKey = Uint8List.fromList(privateKey) {
    final verifier = verifyCertificate(
      this.certificate,
      authorityKeys: authorityKeys,
    );
    if (this.privateKey.length != DtcpCurve.size) {
      throw NasneError.validation(
        'dtcp:credentials',
        'the device private key must be 20 bytes',
      );
    }
    final scalar = bytesToBigInt(this.privateKey);
    if (scalar <= BigInt.zero || scalar >= DtcpCurve.order) {
      throw NasneError.validation(
        'dtcp:credentials',
        'the device private key is outside the DTCP key range',
      );
    }
    if (DtcpCurve.generator * scalar != verifier) {
      throw NasneError.validation(
        'dtcp:credentials',
        'the device private key does not match the certificate',
      );
    }
  }

  final Uint8List certificate;
  final Uint8List privateKey;

  int get deviceId => deviceIdOf(certificate);

  /// The maximum SRM generation this device can store.
  int get maxSrmGeneration => certificate[1] >> 4;

  BigInt get privateScalar => bytesToBigInt(privateKey);
}

// ---------------------------------------------------------------------------
// Content key derivation (pydtcpip derive_content_key port)
// ---------------------------------------------------------------------------

/// Constants appended to the exchange key, indexed by E-EMI.
const Map<int, String> _contentConstantHex = {
  0x2: 'de665adec0156112cf2628eb',
  0x4: '45b146a0611a501ac32bfad4',
  0x6: 'e6ed3e3078ff0e5b3a273ccb',
  0x8: '7c0d87c76c195662f98c14e6',
  0xA: '28b522c7cdb22d490ef8e3d4',
  0xC: 'a3806f971635c1796deaed24',
};

final Uint8List _ivConstant = hexToBytes('95dc3a449028eb3c');

class ContentKeyAndIv {
  const ContentKeyAndIv(this.key, this.iv);
  final Uint8List key;
  final Uint8List iv;
}

/// Derives the AES content key and CBC IV from the 12-byte exchange
/// key, the PCP E-EMI and the 8-byte PCP nonce.
ContentKeyAndIv deriveContentKey(
  List<int> exchangeKey,
  int encryptionMode,
  List<int> nonce,
) {
  if (exchangeKey.length != 12 || nonce.length != 8) {
    throw NasneError.validation(
      'dtcp:contentKey',
      'the exchange key must be 12 bytes and the nonce 8 bytes',
    );
  }
  final constantHex = _contentConstantHex[encryptionMode];
  if (constantHex == null) {
    throw NasneError.validation(
      'dtcp:contentKey',
      'unsupported content encryption mode (E-EMI 0x'
          '${encryptionMode.toRadixString(16)})',
    );
  }
  final material = Uint8List.fromList([
    ...exchangeKey,
    ...hexToBytes(constantHex),
    ...nonce,
  ]);
  final block = aesBlock(
    material.sublist(0, 16),
    material.sublist(16),
    encrypt: true,
  );
  final contentKey = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    contentKey[i] = block[i] ^ material[16 + i];
  }
  final iv = aesBlock(contentKey, [..._ivConstant, ...nonce], encrypt: true);
  return ContentKeyAndIv(contentKey, iv);
}
