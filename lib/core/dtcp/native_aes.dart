/// Native AES-128-CBC FFI binding backed by `libtmhb_fcntl.so` on Android.
///
/// Replaces per-block pure-Dart `pointycastle` decryption during live/recorded
/// streaming so fast LAN bursts do not pin the Android main/UI isolate.
/// Falls back to `null` on non-Android platforms or if the shared library is
/// unavailable (for example in unit tests or desktop hosts without a bundle).
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

typedef _AllocNative = Pointer<Uint8> Function(Size size);
typedef _AllocDart = Pointer<Uint8> Function(int size);

typedef _FreeNative = Void Function(Pointer<Uint8> ptr);
typedef _FreeDart = void Function(Pointer<Uint8> ptr);

typedef _ExpandKeyNative =
    Void Function(Pointer<Uint8> key, Pointer<Uint32> rk);
typedef _ExpandKeyDart = void Function(Pointer<Uint8> key, Pointer<Uint32> rk);

typedef _CbcDecryptNative =
    Void Function(
      Pointer<Uint32> rk,
      Pointer<Uint8> iv,
      Pointer<Uint8> src,
      Pointer<Uint8> dst,
      Size len,
    );
typedef _CbcDecryptDart =
    void Function(
      Pointer<Uint32> rk,
      Pointer<Uint8> iv,
      Pointer<Uint8> src,
      Pointer<Uint8> dst,
      int len,
    );

/// Thin synchronous FFI wrapper around the C AES-128-CBC primitives.
class NativeAesBackend {
  NativeAesBackend._({
    required _FreeDart freeFn,
    required this._expandKey,
    required this._cbcDecrypt,
    required Pointer<Uint8> keyBuf,
    required Pointer<Uint32> rkBuf,
    required Pointer<Uint8> ivBuf,
    required Pointer<Uint8> dataBuf,
  }) : _free = freeFn,
       _keyBuf = keyBuf,
       _rkBuf = rkBuf,
       _ivBuf = ivBuf,
       _dataBuf = dataBuf,
       _keyList = keyBuf.asTypedList(16),
       _rkList = rkBuf.asTypedList(44),
       _ivList = ivBuf.asTypedList(16),
       _dataList = dataBuf.asTypedList(chunkSize);

  /// Reusable native staging chunk size (must remain a multiple of 16).
  static const int chunkSize = 65536;

  /// Process-wide backend instance; `null` outside Android or if loading fails.
  static final NativeAesBackend? instance = tryLoad();

  final _FreeDart _free;
  final _ExpandKeyDart _expandKey;
  final _CbcDecryptDart _cbcDecrypt;
  final Pointer<Uint8> _keyBuf;
  final Pointer<Uint32> _rkBuf;
  final Pointer<Uint8> _ivBuf;
  final Pointer<Uint8> _dataBuf;
  final Uint8List _keyList;
  final Uint32List _rkList;
  final Uint8List _ivList;
  final Uint8List _dataList;
  bool _disposed = false;

  /// Attempts to open the native AES shared library and allocate scratch
  /// buffers. Returns `null` when unsupported or on load error.
  static NativeAesBackend? tryLoad({String? libraryPath}) {
    if (libraryPath == null && !Platform.isAndroid) {
      return null;
    }
    try {
      final lib = DynamicLibrary.open(libraryPath ?? 'libtmhb_fcntl.so');
      final allocFn = lib.lookupFunction<_AllocNative, _AllocDart>(
        'tmhb_aes_alloc',
      );
      final freeFn = lib.lookupFunction<_FreeNative, _FreeDart>(
        'tmhb_aes_free',
      );
      final expandKey = lib.lookupFunction<_ExpandKeyNative, _ExpandKeyDart>(
        'tmhb_aes128_expand_dec_key',
      );
      final cbcDecrypt = lib.lookupFunction<_CbcDecryptNative, _CbcDecryptDart>(
        'tmhb_aes128_cbc_decrypt',
      );

      Pointer<Uint8> keyBuf = nullptr;
      Pointer<Uint32> rkBuf = nullptr;
      Pointer<Uint8> ivBuf = nullptr;
      Pointer<Uint8> dataBuf = nullptr;
      try {
        keyBuf = allocFn(16);
        rkBuf = allocFn(44 * 4).cast<Uint32>();
        ivBuf = allocFn(16);
        dataBuf = allocFn(chunkSize);
        if (keyBuf.address == 0 ||
            rkBuf.address == 0 ||
            ivBuf.address == 0 ||
            dataBuf.address == 0) {
          throw StateError('native AES buffer allocation failed');
        }
        return NativeAesBackend._(
          freeFn: freeFn,
          expandKey: expandKey,
          cbcDecrypt: cbcDecrypt,
          keyBuf: keyBuf,
          rkBuf: rkBuf,
          ivBuf: ivBuf,
          dataBuf: dataBuf,
        );
      } catch (_) {
        if (keyBuf.address != 0) freeFn(keyBuf);
        if (rkBuf.address != 0) freeFn(rkBuf.cast<Uint8>());
        if (ivBuf.address != 0) freeFn(ivBuf);
        if (dataBuf.address != 0) freeFn(dataBuf);
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// Expands a 16-byte AES-128 key into 44 native-order decryption round keys.
  Uint32List expandDecKey(List<int> key) {
    if (_disposed) {
      throw StateError('NativeAesBackend has been disposed');
    }
    if (key.length != 16) {
      throw ArgumentError.value(key.length, 'key.length', 'must be 16');
    }
    _keyList.setRange(0, 16, key);
    _expandKey(_keyBuf, _rkBuf);
    _keyList.fillRange(0, 16, 0);
    return Uint32List.fromList(_rkList);
  }

  /// Decrypts [length] bytes of [data] starting at [offset] in AES-128-CBC
  /// mode using expanded key [rk] and chaining vector [iv] (updated in-place).
  Uint8List decryptCbc(
    Uint32List rk,
    Uint8List iv,
    Uint8List data,
    int offset,
    int length,
  ) {
    if (_disposed) {
      throw StateError('NativeAesBackend has been disposed');
    }
    if (length == 0) return Uint8List(0);
    if ((length & 0x0f) != 0) {
      throw ArgumentError.value(length, 'length', 'must be a multiple of 16');
    }
    if (iv.length != 16) {
      throw ArgumentError.value(iv.length, 'iv.length', 'must be 16');
    }
    _rkList.setAll(0, rk);
    _ivList.setRange(0, 16, iv);
    final out = Uint8List(length);
    for (var done = 0; done < length;) {
      final take = math.min(chunkSize, length - done);
      _dataList.setRange(0, take, data, offset + done);
      _cbcDecrypt(_rkBuf, _ivBuf, _dataBuf, _dataBuf, take);
      out.setRange(done, done + take, _dataList, 0);
      done += take;
    }
    iv.setRange(0, 16, _ivList);
    return out;
  }

  /// Releases scratch buffers held by this instance (mainly for tests).
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _keyList.fillRange(0, 16, 0);
    _rkList.fillRange(0, 44, 0);
    _ivList.fillRange(0, 16, 0);
    _free(_keyBuf);
    _free(_rkBuf.cast<Uint8>());
    _free(_ivBuf);
    _free(_dataBuf);
  }
}
