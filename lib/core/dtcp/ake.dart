/// DTCP-IP Authentication and Key Exchange (AKE), sink side.
///
/// Port of pydtcpip's `dtcp/ake.py` (MIT, (c) tsukumijima): control
/// frame layout, command set, Full Authentication handshake, RTT
/// measurement and SRM update handling. Deviations from the
/// reference implementation are listed in plan 26.5: the transport
/// is an injectable [AkeConnection] (the IP TTL 3 requirement of the
/// reference cannot be expressed with dart:io), and the SRM is
/// persisted through a callback instead of a database. Plan 28
/// aligned the remaining wire differences with the reference
/// (request status byte 0x0F, role byte, accepted frames copying
/// the received header) after a step-by-step re-comparison, and
/// the app now injects a native transport that sets the TTL.
/// Plan 29 aligned the session lifecycle: the control connection
/// is one-shot for streaming (the source closes it right after
/// authentication; the reference closes it from the sink side),
/// so a post-auth close is a normal end, and a key the ended
/// session never delivered is obtained by re-authenticating.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../diagnostics.dart';
import '../errors.dart';
import 'dtcp_crypto.dart';
import 'srm.dart';

/// AKE command values on the wire (pydtcpip's `AKECommand`).
abstract final class AkeCommands {
  static const int challenge = 0x01;
  static const int response = 0x02;
  static const int exchangeKey = 0x03;
  static const int srmUpdate = 0x04;
  static const int rttSetup = 0x11;
  static const int rttTest = 0x12;
  static const int rttReady = 0x91;
  static const int rttVerify = 0x92;
}

const int _frameControl = 0x0;
const int _frameAccepted = 0x9;
const int _procedureFullAuth = 0x04;
const int _keyTypeAes128 = 0x08;

/// Header byte 8 values (plan 28). pydtcpip's ControlFrame
/// identifies byte 8 as the most significant nibble of the
/// sender's device ID and always sends 0x01 from the sink; its
/// fake source sends 0x00. The first implementation sent 0x02
/// from the sink, diverging from the verified reference.
const int _roleByteSink = 0x01;

/// The AKE connection ended (the source closed it) while an
/// operation was pending.
///
/// For a streaming session this is the NORMAL end of the control
/// channel, not a failure: measured against the real nasne
/// (plan 29), the source closes the AKE connection immediately
/// after authentication completes — before the content GET is
/// even issued — and the reference client closes it from the sink
/// side at the same point for the same reason. A caller that
/// needs a key for a label the ended session never delivered
/// re-authenticates on a fresh connection (the reference's model)
/// instead of waiting on the dead one.
class AkeConnectionClosed implements Exception {
  const AkeConnectionClosed();

  @override
  String toString() => 'the AKE connection closed';
}

/// An 11-byte-header AKE control frame.
class ControlFrame {
  ControlFrame({
    required this.command,
    required this.payload,
    this.isResponse = false,
    this.procedure = _procedureFullAuth,
    this.keyType = _keyTypeAes128,
    this.roleByte = _roleByteSink,
    this.label = 0,
    this.status = 0,
  });

  final int command;
  final Uint8List payload;
  final bool isResponse;
  final int procedure;
  final int keyType;

  /// Header byte 8 (see [_roleByteSink]).
  final int roleByte;
  final int label;
  final int status;

  bool get isAccepted => isResponse && status == 0;

  /// The ACCEPTED response to this frame, per the reference
  /// implementation: the header is inherited verbatim (procedure,
  /// key type, role byte and label), the ctype becomes ACCEPTED
  /// and the status nibble is cleared. [payload] replaces the
  /// payload (echo and response bodies); the default is empty.
  /// The first implementation constructed fresh headers here,
  /// diverging from the verified reference (plan 28).
  ControlFrame accepted({Uint8List? payload}) => ControlFrame(
        command: command,
        payload: payload ?? Uint8List(0),
        isResponse: true,
        procedure: procedure,
        keyType: keyType,
        roleByte: roleByte,
        label: label,
        status: 0,
      );

  Uint8List encode() {
    final totalLength = payload.length + 8;
    final out = Uint8List(11 + payload.length);
    out[0] = 0x01;
    out[1] = (totalLength >> 8) & 0xFF;
    out[2] = totalLength & 0xFF;
    out[3] = isResponse ? _frameAccepted : _frameControl;
    out[4] = 0;
    out[5] = command;
    out[6] = procedure;
    out[7] = keyType;
    out[8] = roleByte;
    out[9] = label;
    // Requests carry status byte 0x0F in the reference
    // implementation; responses carry the status nibble.
    out[10] = isResponse ? status & 0x0F : 0x0F;
    out.setRange(11, out.length, payload);
    return out;
  }

  /// Parses one frame from the front of [data]; returns the frame
  /// and the number of bytes consumed, or null when more bytes are
  /// needed. Throws on a malformed header.
  static (ControlFrame, int)? tryParse(Uint8List data) {
    if (data.length < 11) return null;
    if (data[0] != 0x01 || data[4] != 0) {
      throw NasneError.parse('dtcp:ake', cause: 'invalid AKE frame header');
    }
    final totalLength = (data[1] << 8) | data[2];
    if (totalLength < 8) {
      throw NasneError.parse(
        'dtcp:ake',
        cause: 'invalid AKE frame length $totalLength',
      );
    }
    final frameLength = totalLength + 3;
    if (data.length < frameLength) return null;
    final frameType = data[3] & 0x0F;
    if (frameType != _frameControl && frameType != _frameAccepted) {
      throw NasneError.parse(
        'dtcp:ake',
        cause: 'unknown AKE frame type 0x${frameType.toRadixString(16)}',
      );
    }
    return (
      ControlFrame(
        command: data[5],
        payload: Uint8List.fromList(data.sublist(11, frameLength)),
        isResponse: frameType == _frameAccepted,
        procedure: data[6],
        keyType: data[7],
        roleByte: data[8],
        label: data[9],
        status: data[10] & 0x0F,
      ),
      frameLength,
    );
  }
}

/// Transport for AKE frames. The default factory opens a TCP socket;
/// the IP TTL of 3 that the reference implementation sets cannot be
/// expressed with dart:io, so the factory is kept replaceable
/// (plan 26.5).
abstract interface class AkeConnection {
  Stream<Uint8List> get incoming;
  void send(Uint8List bytes);
  Future<void> close();
}

typedef AkeConnectionFactory = Future<AkeConnection> Function(
  String host,
  int port,
);

class _SocketAkeConnection implements AkeConnection {
  _SocketAkeConnection(this._socket) {
    _socket.done.then<void>((_) {}, onError: (_) {});
  }
  final Socket _socket;

  @override
  Stream<Uint8List> get incoming => _socket;

  @override
  void send(Uint8List bytes) => _socket.add(bytes);

  @override
  Future<void> close() async {
    await _socket
        .flush()
        .timeout(const Duration(seconds: 1), onTimeout: () {})
        .catchError((_) {});
    _socket.destroy();
  }
}

Future<AkeConnection> socketAkeConnectionFactory(String host, int port) async {
  final socket = await Socket.connect(
    host,
    port,
    timeout: const Duration(seconds: 10),
  );
  // TCP_NODELAY matches the reference client. The IP TTL of 3
  // cannot be set from dart:io; the app injects the native
  // transport (app/ake_socket.dart) which sets it (plan 28).
  socket.setOption(SocketOption.tcpNoDelay, true);
  return _SocketAkeConnection(socket);
}

/// Supplies and persists the current SRM (plan 26.4: signed public
/// data, kept in the regular store).
abstract interface class SrmStore {
  Future<Srm?> load();
  Future<void> save(Uint8List raw, Srm srm);
  Future<Uint8List?> loadRaw();
}

/// The exchange-key surface of an established AKE session, as
/// consumed by the playback key source (plan 29). [AkeSession] is
/// the real implementation; tests substitute fakes.
abstract interface class ExchangeKeySession {
  /// The key for [label] when already received, else null.
  Uint8List? keyOrNull(int label);

  /// Waits for the key with [label]; throws [AkeConnectionClosed]
  /// when the session ended without delivering it.
  Future<Uint8List> waitExchangeKey(int label, {Duration? timeout});

  /// Waits for the session's first exchange key and returns its
  /// label.
  Future<int> waitFirstExchangeKey({Duration timeout});

  /// Closes the session's connection.
  Future<void> close();
}

/// An established AKE session: holds the exchange keys in memory
/// only. Keys are never persisted (plan 26.4).
class AkeSession implements ExchangeKeySession {
  AkeSession._(this._connection, this._client);

  final AkeConnection _connection;
  final AkeClient _client;

  /// The currently active exchange key label, if any.
  int? get exchangeKeyLabel => _client.exchangeKeyLabel;

  /// The key for [label] when it has already been received, else
  /// null (never waits).
  @override
  Uint8List? keyOrNull(int label) => _client.keyOrNull(label);

  /// Waits for a key with [label] to arrive via EXCHANGE_KEY.
  /// Throws [AkeConnectionClosed] when the session's connection
  /// has already ended and the key was never delivered.
  @override
  Future<Uint8List> waitExchangeKey(int label, {Duration? timeout}) =>
      _client.waitExchangeKey(label, timeout: timeout);

  /// Waits for the FIRST exchange key of this session and returns
  /// its label (plan 28: playback start waits for it, like the
  /// reference client, instead of starting the proxy optimistically
  /// and failing later inside the player).
  @override
  Future<int> waitFirstExchangeKey({
    Duration timeout = const Duration(seconds: 20),
  }) => _client.waitFirstExchangeKey(timeout: timeout);

  @override
  Future<void> close() => _connection.close();
}

/// Sink-side AKE client implementing Full Authentication against a
/// DTCP-IP source (the nasne).
class AkeClient {
  AkeClient({
    required this.credentials,
    required this.srmStore,
    this.connectionFactory = socketAkeConnectionFactory,
    this.authorityKeys = const [],
    this.diag = const DiagLog.none(),
    Uint8List Function(int length)? randomBytes,
    BigInt Function()? ephemeralScalar,
  }) : _randomBytes = randomBytes ?? _secureRandomBytes,
       _ephemeralScalar = ephemeralScalar ?? generateEphemeralScalar;

  final DeviceCredentials credentials;
  final SrmStore srmStore;
  final AkeConnectionFactory connectionFactory;
  final Uint8List Function(int length) _randomBytes;
  final BigInt Function() _ephemeralScalar;

  /// Diagnostics sink (plan 28). Stage transitions and frame
  /// headers only — never key material (see core/diagnostics.dart).
  final DiagLog diag;

  /// DTLA authority keys for certificate / SRM verification;
  /// empty = the real DTLA keys. Non-empty only in tests.
  final List<Uint8List> authorityKeys;

  static Uint8List _secureRandomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }

  int? _exchangeKeyLabel;
  final Map<int, Completer<Uint8List>> _keyWaiters = {};
  final Map<int, Uint8List> _exchangeKeys = {};
  final Completer<int> _firstKey = Completer<int>();

  /// Whether the post-authentication message loop has finished
  /// (plan 29). Once it has, no further keys can arrive on this
  /// session: a wait for an undelivered label fails fast with
  /// [AkeConnectionClosed] (or the loop's error) so the caller can
  /// re-authenticate instead of stalling.
  bool _loopEnded = false;
  Object? _loopError;

  /// The handshake stage currently in progress, named in the
  /// timeout error so a stall is attributable (plan 28).
  String _authStage = 'connect';

  int? get exchangeKeyLabel => _exchangeKeyLabel;

  /// The key for [label] when it has already been received, else
  /// null (never waits).
  Uint8List? keyOrNull(int label) => _exchangeKeys[label];

  Future<Uint8List> waitExchangeKey(int label, {Duration? timeout}) {
    final existing = _exchangeKeys[label];
    if (existing != null) return Future.value(existing);
    if (_loopEnded) {
      return Future.error(_loopError ?? const AkeConnectionClosed());
    }
    final completer = _keyWaiters.putIfAbsent(
      label,
      () => Completer<Uint8List>(),
    );
    final future = completer.future;
    return timeout == null ? future : future.timeout(timeout);
  }

  /// Settles every pending key wait when the message loop ends
  /// (plan 29). A clean end (the source closed the connection, the
  /// normal case for streaming) fails undelivered waits with
  /// [AkeConnectionClosed]; a loop error propagates as-is. The
  /// first-key wait is special: ending before ANY key arrived is a
  /// start failure, so it gets a classified error instead.
  void _onLoopEnd(Object? error) {
    if (_loopEnded) return;
    _loopEnded = true;
    _loopError = error;
    final waiters = _keyWaiters.values.toList();
    _keyWaiters.clear();
    for (final completer in waiters) {
      if (!completer.isCompleted) {
        completer.completeError(error ?? const AkeConnectionClosed());
      }
    }
    if (!_firstKey.isCompleted) {
      _firstKey.completeError(
        error ??
            NasneError.unreachable(
              'dtcp:ake',
              cause:
                  'the source closed the AKE connection before '
                  'sending an exchange key',
            ),
      );
    }
  }

  /// Completes with the label of the first exchange key received.
  Future<int> waitFirstExchangeKey({
    Duration timeout = const Duration(seconds: 20),
  }) => _firstKey.future.timeout(
    timeout,
    onTimeout: () => throw NasneError.unreachable(
      'dtcp:ake',
      cause:
          'the source sent no exchange key within '
          '${timeout.inSeconds} seconds of authentication',
    ),
  );

  /// Runs the full handshake and returns the live session. The
  /// session's message loop keeps running until [AkeSession.close].
  Future<AkeSession> connect(String host, int port) async {
    final stopwatch = Stopwatch()..start();
    diag(DiagCategory.ake, 'connecting to $host:$port');
    _authStage = 'connect';
    final connection = await connectionFactory(host, port);
    final reader = _FrameReader(connection, diag: diag);
    try {
      // The reference client bounds the WHOLE authentication —
      // exchange-key receipt included — by its timeout (plan 28).
      // The exchange key itself is awaited by the caller through
      // [AkeSession.waitFirstExchangeKey]; the handshake is
      // bounded here so a stall names its stage.
      final authFuture = _authenticate(reader);
      // A timed-out handshake must not surface a second, orphaned
      // error later.
      unawaited(authFuture.then((_) {}, onError: (_) {}));
      final Uint8List authKey;
      try {
        authKey = await authFuture.timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw NasneError.unreachable(
            'dtcp:ake',
            cause: 'AKE timed out during stage: $_authStage',
          ),
        );
      } on AkeConnectionClosed {
        // The source hung up mid-handshake: a reachability failure
        // naming the stage, not a bare close (plan 29).
        throw NasneError.unreachable(
          'dtcp:ake',
          cause:
              'the source closed the AKE connection during '
              'stage: $_authStage',
        );
      }
      final session = AkeSession._(connection, this);
      diag(
        DiagCategory.ake,
        'authenticated in ${stopwatch.elapsedMilliseconds} ms; '
        'post-auth message loop running',
      );
      // The first-key future may be settled by the loop before the
      // caller awaits it; keep its error from going unhandled.
      unawaited(_firstKey.future.then((_) {}, onError: (_) {}));
      // The post-authentication loop (RTT / EXCHANGE_KEY /
      // SRM_UPDATE) runs in the background. Its end settles every
      // pending key wait (plan 29): the source closing the
      // connection here is the normal streaming lifecycle (the
      // reference client closes it from its own side), while a
      // real protocol error still surfaces to the waiters.
      unawaited(
        _messageLoop(reader, authKey).then(
          (_) => _onLoopEnd(null),
          onError: (Object e) {
            if (e is AkeConnectionClosed) {
              diag(
                DiagCategory.ake,
                'ake session ended: the source closed the '
                'connection (normal after authentication)',
              );
              _onLoopEnd(null);
            } else {
              diag(DiagCategory.ake, 'message loop ended: $e');
              _onLoopEnd(e);
            }
          },
        ),
      );
      return session;
    } catch (_) {
      await connection.close();
      rethrow;
    }
  }

  Future<Uint8List> _authenticate(_FrameReader reader) async {
    var srm = await srmStore.load();
    final myNonce = _randomBytes(16);

    // CHALLENGE: nonce || my certificate.
    _authStage = 'challenge';
    await reader.send(
      ControlFrame(
        command: AkeCommands.challenge,
        payload: Uint8List.fromList([...myNonce, ...credentials.certificate]),
      ),
    );
    var frame = await reader.next();
    _expectAccepted(frame, AkeCommands.challenge);
    diag(DiagCategory.ake, 'stage: challenge accepted by source');

    // The source's CHALLENGE.
    _authStage = 'source challenge';
    frame = await reader.next();
    if (frame.isResponse ||
        frame.command != AkeCommands.challenge ||
        frame.payload.length != 104) {
      throw NasneError.parse(
        'dtcp:ake',
        cause: 'expected the source CHALLENGE frame',
      );
    }
    final sourceNonce = frame.payload.sublist(0, 16);
    final sourceCert = frame.payload.sublist(16);
    final sourcePublicKey = verifyCertificate(
      sourceCert,
      authorityKeys: authorityKeys,
    );
    _peerCertificate = Uint8List.fromList(sourceCert);
    diag(DiagCategory.ake, 'stage: source certificate verified');
    if (srm != null) {
      if (srm.isRevoked(deviceIdOf(sourceCert))) {
        throw NasneError.parse(
          'dtcp:ake',
          cause: 'the source device is revoked by the SRM',
        );
      }
      if (srm.isRevoked(credentials.deviceId)) {
        throw NasneError.parse(
          'dtcp:ake',
          cause: 'this device is revoked by the SRM',
        );
      }
    }

    // ACCEPTED for the source's CHALLENGE: the header is copied
    // from the received frame (reference behaviour, plan 28).
    await reader.send(frame.accepted());

    // The source's RESPONSE.
    _authStage = 'source response';
    frame = await reader.next();
    if (frame.isResponse ||
        frame.command != AkeCommands.response ||
        frame.payload.length != 83) {
      throw NasneError.parse(
        'dtcp:ake',
        cause: 'expected the source RESPONSE frame',
      );
    }
    final sourceEphemeral = frame.payload.sublist(0, 40);
    final sourceEphemeralPoint = EcPoint.fromBytes(sourceEphemeral);
    if (sourceEphemeralPoint == null) {
      throw NasneError.parse(
        'dtcp:ake',
        cause: 'the source ephemeral key is invalid',
      );
    }
    _peerSrmVersion = (frame.payload[40] << 8) | frame.payload[41];
    _peerSrmGeneration = frame.payload[42] & 0x0F;
    _peerMaxSrmGeneration = _peerCertificate![1] >> 4;
    if (_peerSrmGeneration > _peerMaxSrmGeneration) {
      throw NasneError.parse(
        'dtcp:ake',
        cause: 'the source SRM generation exceeds its maximum',
      );
    }
    final sourceSignature = frame.payload.sublist(43);
    final signedData = Uint8List.fromList([
      ...myNonce,
      ...frame.payload.sublist(0, 43),
    ]);
    if (!ecdsaVerify(sourcePublicKey, signedData, sourceSignature)) {
      throw NasneError.parse(
        'dtcp:ake',
        cause: 'the source signature verification failed',
      );
    }
    diag(DiagCategory.ake, 'stage: source response signature verified');

    // ECDH: the authentication key is the last 12 bytes of the
    // shared point's x coordinate.
    final ephemeral = _ephemeralScalar();
    final ephemeralPublic = DtcpCurve.generator * ephemeral;
    final shared = ecdhSharedSecret(ephemeral, sourceEphemeralPoint);
    final authKey = Uint8List.fromList(shared.sublist(8));

    // ACCEPTED for the source's RESPONSE (header copied).
    await reader.send(frame.accepted());

    // My RESPONSE: ephemeral public key || SRM version/generation
    // || deterministic signature over (source nonce || payload).
    _authStage = 'response';
    final mySrm = await srmStore.load();
    final responseData = Uint8List.fromList([
      ...ephemeralPublic.toBytes(),
      ((mySrm?.version ?? 0) >> 8) & 0xFF,
      (mySrm?.version ?? 0) & 0xFF,
      mySrm?.generation ?? 0,
    ]);
    final signature = ecdsaSignDeterministic(
      credentials.privateScalar,
      Uint8List.fromList([...sourceNonce, ...responseData]),
    );
    await reader.send(
      ControlFrame(
        command: AkeCommands.response,
        payload: Uint8List.fromList([...responseData, ...signature]),
      ),
    );
    _authStage = 'response acceptance';
    frame = await reader.next();
    _expectAccepted(frame, AkeCommands.response);
    diag(DiagCategory.ake, 'stage: response accepted by source');
    return authKey;
  }

  /// The source's certificate and SRM coordinates, retained from
  /// the handshake for SRM_UPDATE checks and SRM forwarding.
  Uint8List? _peerCertificate;
  int _peerSrmVersion = 0;
  int _peerSrmGeneration = 0;
  int _peerMaxSrmGeneration = 0;

  void _expectAccepted(ControlFrame frame, int command) {
    if (!frame.isResponse || frame.command != command || frame.status != 0) {
      throw NasneError.parse(
        'dtcp:ake',
        cause:
            'the source rejected the AKE step '
            '(command 0x${command.toRadixString(16)})',
      );
    }
  }

  Future<void> _messageLoop(_FrameReader reader, Uint8List authKey) async {
    // RTT MACs are precomputed at RTT_SETUP time because the
    // source bounds the measurement round trip (7 ms in the
    // reference implementation's notes).
    final rttBase = bytesToBigInt(sha1Bytes([...authKey, ...authKey]));
    Uint8List? rttExpectedTest;
    Uint8List? rttTestResponse;
    Uint8List? rttVerifyResponse;
    Uint8List? receivedRttTest;

    while (true) {
      final frame = await reader.next();
      switch (frame.command) {
        case AkeCommands.rttReady:
          if (frame.isResponse) {
            // The source accepted our RTT_READY; wait for the next
            // request (reference behaviour).
            continue;
          }
          diag(DiagCategory.ake, 'rtt: ready round trip');
          await reader.send(frame.accepted());
          await reader.send(
            ControlFrame(command: AkeCommands.rttReady, payload: Uint8List(0)),
          );
        case AkeCommands.rttSetup:
          if (frame.isResponse || frame.payload.length != 2) {
            throw NasneError.parse(
              'dtcp:ake',
              cause: 'invalid RTT_SETUP frame',
            );
          }
          final counter = (frame.payload[0] << 8) | frame.payload[1];
          final digest = sha1Bytes(
            bigIntToBytes((rttBase + BigInt.from(counter)) % _twoPow160, 20),
          );
          rttExpectedTest = Uint8List.fromList(digest.sublist(0, 10));
          rttTestResponse = Uint8List.fromList(digest.sublist(10));
          final verifyDigest = sha1Bytes(
            bigIntToBytes(
              (rttBase + BigInt.from(counter) + BigInt.one) % _twoPow160,
              20,
            ),
          );
          rttVerifyResponse = Uint8List.fromList(verifyDigest.sublist(0, 10));
          diag(DiagCategory.ake, 'rtt: setup received, MACs precomputed');
          // The reference echoes the counter as the acceptance
          // (an ACCEPTED copy of the received frame).
          await reader.send(frame.accepted(payload: frame.payload));
        case AkeCommands.rttTest:
          if (frame.isResponse ||
              rttExpectedTest == null ||
              frame.payload.length != 10) {
            throw NasneError.parse('dtcp:ake', cause: 'invalid RTT_TEST frame');
          }
          receivedRttTest = frame.payload;
          await reader.send(frame.accepted(payload: rttTestResponse!));
          diag(DiagCategory.ake, 'rtt: test received');
        case AkeCommands.rttVerify:
          if (frame.isResponse ||
              rttExpectedTest == null ||
              receivedRttTest == null ||
              !_bytesEqual(receivedRttTest, rttExpectedTest)) {
            throw NasneError.parse(
              'dtcp:ake',
              cause: 'RTT verification failed',
            );
          }
          diag(DiagCategory.ake, 'rtt: verified');
          await reader.send(frame.accepted(payload: rttVerifyResponse!));
        case AkeCommands.exchangeKey:
          if (frame.isResponse || frame.payload.length != 14) {
            throw NasneError.parse(
              'dtcp:ake',
              cause: 'invalid EXCHANGE_KEY frame',
            );
          }
          final label = frame.payload[0];
          final masked = frame.payload.sublist(2);
          final key = Uint8List(12);
          for (var i = 0; i < 12; i++) {
            key[i] = masked[i] ^ authKey[i];
          }
          _exchangeKeys[label] = key;
          _exchangeKeyLabel = label;
          _keyWaiters.remove(label)?.complete(key);
          if (!_firstKey.isCompleted) _firstKey.complete(label);
          diag(DiagCategory.ake, 'exchange key received, label $label');
          await reader.send(frame.accepted());
          await _forwardSrmIfNewer(reader);
        case AkeCommands.srmUpdate:
          if (frame.isResponse) {
            throw NasneError.parse(
              'dtcp:ake',
              cause: 'unexpected SRM_UPDATE response frame',
            );
          }
          await _handleSrmUpdate(reader, frame);
        default:
          throw NasneError.parse(
            'dtcp:ake',
            cause:
                'unsupported AKE command '
                '0x${frame.command.toRadixString(16)}',
          );
      }
    }
  }

  Future<void> _handleSrmUpdate(_FrameReader reader, ControlFrame frame) async {
    final payload = frame.payload;
    final newSrm = Srm.parse(payload, authorityKeys: authorityKeys);
    diag(
      DiagCategory.ake,
      'srm update received (version ${newSrm.version}, '
      'generation ${newSrm.generation})',
    );
    final current = await srmStore.load();
    final Srm effective;
    if (current == null || newSrm.isNewerThan(current)) {
      // A newer SRM is retained even if it revokes a party (the
      // reference behaviour); the checks below then apply it.
      await srmStore.save(payload, newSrm);
      effective = newSrm;
    } else {
      effective = current;
    }
    final peer = _peerCertificate;
    if (peer != null && effective.isRevoked(deviceIdOf(peer))) {
      throw NasneError.parse(
        'dtcp:ake',
        cause: 'the source device is revoked by the SRM',
      );
    }
    if (effective.isRevoked(credentials.deviceId)) {
      throw NasneError.parse(
        'dtcp:ake',
        cause: 'this device is revoked by the SRM',
      );
    }
    await reader.send(frame.accepted());
  }

  /// After an EXCHANGE_KEY, a newer local SRM is forwarded to the
  /// source (reference behaviour). The update frame carries key
  /// type 0: the source rejects a specified key type here.
  Future<void> _forwardSrmIfNewer(_FrameReader reader) async {
    final localSrm = await srmStore.load();
    if (localSrm == null || _peerCertificate == null) return;
    final isLocalNewer =
        localSrm.version > _peerSrmVersion ||
        (localSrm.version == _peerSrmVersion &&
            _peerSrmGeneration < _peerMaxSrmGeneration &&
            localSrm.generation > _peerSrmGeneration);
    if (!isLocalNewer) return;
    diag(
      DiagCategory.ake,
      'forwarding newer local SRM (version ${localSrm.version}, '
      'generation ${localSrm.generation})',
    );
    var sendData = localSrm.data;
    if (localSrm.generation > _peerMaxSrmGeneration) {
      // Send only the first generation part, retaining the signed
      // header, to a peer limited to generation 0.
      final firstLength = (sendData[4] << 8) | sendData[5];
      sendData = Uint8List.fromList(sendData.sublist(0, 4 + firstLength));
    }
    await reader.send(
      ControlFrame(
        command: AkeCommands.srmUpdate,
        payload: sendData,
        keyType: 0,
      ),
    );
    final accepted = await reader.next();
    if (!accepted.isResponse ||
        accepted.command != AkeCommands.srmUpdate ||
        accepted.status != 0) {
      throw NasneError.parse(
        'dtcp:ake',
        cause: 'the source did not accept the SRM update',
      );
    }
  }

  static final BigInt _twoPow160 = BigInt.one << 160;

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Buffers a connection's byte stream into control frames.
class _FrameReader {
  _FrameReader(this._connection, {this.diag = const DiagLog.none()}) {
    _connection.incoming.listen(
      (chunk) {
        _buffer.addAll(chunk);
        _drain();
      },
      onError: (Object e) => _fail(e),
      // A clean EOF is reported as AkeConnectionClosed, NOT as a
      // reachability failure: for streaming, the source closes the
      // AKE connection as soon as authentication completes
      // (plan 29). Mid-handshake closes are reclassified by the
      // caller, which knows the stage.
      onDone: () => _handleClosed(),
    );
  }

  final AkeConnection _connection;

  /// Frame-level diagnostics (plan 28): command, ctype, status
  /// and payload length only — never payload contents.
  final DiagLog diag;
  final List<int> _buffer = [];
  final List<Completer<ControlFrame>> _waiters = [];
  final List<ControlFrame> _frames = [];
  Object? _error;
  bool _failLogged = false;

  static String _hexByte(int value) =>
      '0x${value.toRadixString(16).padLeft(2, '0')}';

  void _drain() {
    while (true) {
      final (ControlFrame, int)? parsed;
      try {
        parsed = ControlFrame.tryParse(Uint8List.fromList(_buffer));
      } catch (e) {
        _fail(e);
        return;
      }
      if (parsed == null) return;
      final (frame, consumed) = parsed;
      diag(
        DiagCategory.ake,
        'rx cmd=${_hexByte(frame.command)} ctype=${_hexByte(_buffer[3])} '
        'status=${frame.status} payload=${frame.payload.length}B',
      );
      _buffer.removeRange(0, consumed);
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(frame);
      } else {
        _frames.add(frame);
      }
    }
  }

  void _fail(Object error) {
    if (!_failLogged) {
      _failLogged = true;
      diag(DiagCategory.ake, 'ake connection failed: $error');
    }
    _error ??= error;
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _waiters.clear();
  }

  bool _closed = false;

  /// Clean EOF from the source. Pending readers get
  /// [AkeConnectionClosed]; whether that is an error depends on
  /// how far the session got (the session layer decides).
  void _handleClosed() {
    if (_closed || _error != null) return;
    _closed = true;
    diag(DiagCategory.ake, 'ake connection closed by the source');
    const error = AkeConnectionClosed();
    _error = error;
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _waiters.clear();
  }

  Future<void> send(ControlFrame frame) async {
    diag(
      DiagCategory.ake,
      'tx cmd=${_hexByte(frame.command)} '
      'ctype=${frame.isResponse ? 'accepted' : 'control'} '
      'payload=${frame.payload.length}B',
    );
    _connection.send(frame.encode());
  }

  Future<ControlFrame> next() {
    if (_frames.isNotEmpty) return Future.value(_frames.removeAt(0));
    if (_error != null) return Future.error(_error!);
    final completer = Completer<ControlFrame>();
    _waiters.add(completer);
    return completer.future;
  }
}
