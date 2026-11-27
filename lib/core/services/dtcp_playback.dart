/// DTCP-IP playback engine (Phase 5, plan 26): HEAD -> AKE ->
/// loopback proxy -> player. Enabled only when the user has
/// imported their own credential pair; without a pair, starting
/// playback throws a validation error whose detail the UI turns
/// into import guidance.
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import '../diagnostics.dart';
import '../dtcp/ake.dart';
import '../dtcp/arib_ts_caption_tap.dart';
import '../dtcp/credential_store.dart';
import '../dtcp/dtcp_crypto.dart';
import '../dtcp/dtcp_proxy.dart';
import '../errors.dart';
import '../models/live_channel.dart';
import '../models/title.dart';
import 'interfaces.dart';

/// Supplies exchange keys to the proxy's decryptor (plan 29).
///
/// The AKE connection is one-shot for streaming: the source
/// closes it right after authentication, so when a packet arrives
/// with a label the current session never delivered (key
/// rotation), the key is obtained by RE-AUTHENTICATING on a fresh
/// connection — the reference client's model — rather than by
/// waiting on the ended session. Concurrent requests share one
/// in-flight re-authentication.
class PlaybackKeySource {
  // The public parameter names (session / reauthenticate) are the
  // call-site vocabulary while the fields stay private, hence no
  // initializing formals here.
  PlaybackKeySource({
    required ExchangeKeySession session,
    required Future<ExchangeKeySession> Function() reauthenticate,
    this.diag = const DiagLog.none(),
  }) : _session = session, // ignore: prefer_initializing_formals
       _reauthenticate = reauthenticate; // ignore: prefer_initializing_formals

  ExchangeKeySession _session;
  final Future<ExchangeKeySession> Function() _reauthenticate;

  /// Diagnostics sink, category playback.
  final DiagLog diag;
  Future<ExchangeKeySession>? _reauthInFlight;
  bool _closed = false;

  /// The session currently supplying keys (the latest after any
  /// re-authentication); the playback session stops this one.
  ExchangeKeySession get currentSession => _session;

  /// Permanently closes this key source and aborts any late re-authentication
  /// result so orphaned AKE sockets cannot survive session stop.
  Future<void> close() async {
    _closed = true;
    await _session.close();
  }

  /// The key for [label]: immediate when already delivered, a
  /// bounded wait while the session is alive, and a
  /// re-authentication when the session has ended without it.
  Future<Uint8List> keyForLabel(int label) async {
    if (_closed) throw AkeConnectionClosed();
    final known = _session.keyOrNull(label);
    if (known != null) return known;
    diag(DiagCategory.playback, 'waiting for exchange key, label $label');
    try {
      return await _session.waitExchangeKey(
        label,
        timeout: const Duration(seconds: 15),
      );
    } on AkeConnectionClosed catch (_) {
      return _reauthForLabel(label);
    } on TimeoutException catch (_) {
      diag(
        DiagCategory.playback,
        'waiting for exchange key label $label timed out; re-authenticating',
      );
      unawaited(_session.close());
      return _reauthForLabel(label);
    }
  }

  Future<Uint8List> _reauthForLabel(int label) async {
    diag(
      DiagCategory.playback,
      'the AKE session ended without label $label; re-authenticating',
    );
    final fresh = await _reauthenticateOnce();
    final firstLabel = await fresh.waitFirstExchangeKey(
      timeout: const Duration(seconds: 20),
    );
    final key = fresh.keyOrNull(label);
    if (key == null) {
      throw NasneError.parse(
        'dtcp:ake',
        cause:
            'the exchange key label still does not match after '
            're-authentication (wanted $label, got $firstLabel)',
      );
    }
    diag(
      DiagCategory.playback,
      're-authenticated; exchange key label $firstLabel in hand',
    );
    return key;
  }

  /// Forces a fresh AKE authentication even when the local key cache is
  /// populated (used after prolonged cellular outages).
  Future<void> forceReauthenticate() async {
    final future = () async {
      final fresh = await _reauthenticateOnce();
      try {
        await fresh.waitFirstExchangeKey(timeout: const Duration(seconds: 10));
      } catch (_) {
        unawaited(fresh.close());
        rethrow;
      }
    }();
    unawaited(future.then((_) {}, onError: (_) {}));
    await future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw NasneError.unreachable(
        'dtcp:ake',
        cause: 're-authentication timed out after 15s',
      ),
    );
  }

  Future<ExchangeKeySession> _reauthenticateOnce() async {
    if (_closed) throw AkeConnectionClosed();
    final inFlight = _reauthInFlight;
    if (inFlight != null) return inFlight;
    final future = _reauthenticate();
    _reauthInFlight = future;
    try {
      final fresh = await future;
      if (_closed) {
        unawaited(fresh.close());
        throw AkeConnectionClosed();
      }
      final old = _session;
      _session = fresh;
      if (!identical(old, fresh)) unawaited(old.close());
      return fresh;
    } finally {
      if (identical(_reauthInFlight, future)) _reauthInFlight = null;
    }
  }
}

/// Plaintext proxy window cap used on Android / Fire TV (reduced from 32 MiB
/// to 8 MiB to curb initial LAN burst pressure on 1 GB RAM Fire TV sticks).
const int androidProxyWindowCapBytes = 8 * 1024 * 1024;

class DtcpPlaybackEngine implements PlaybackEngine {
  DtcpPlaybackEngine({
    required this.credentialStore,
    required SrmStore srmStore,
    this.diag = const DiagLog.none(),
    this.autoReconnect = false,
    AkeConnectionFactory? akeConnectionFactory,
    AkeClient Function(DeviceCredentials credentials)? clientFactory,
    DtcpMediaFetcher Function()? fetcherFactory,
  }) : _clientFactory =
           clientFactory ??
           ((credentials) => akeConnectionFactory == null
               ? AkeClient(
                   credentials: credentials,
                   srmStore: srmStore,
                   diag: diag,
                 )
               : AkeClient(
                   credentials: credentials,
                   srmStore: srmStore,
                   diag: diag,
                   connectionFactory: akeConnectionFactory,
                 )),
       _fetcherFactory = fetcherFactory ?? (() => DtcpMediaFetcher(diag: diag));

  final CredentialStore credentialStore;

  /// Diagnostics sink (plan 28), categories playback/network/ake.
  final DiagLog diag;

  /// Enables unlimited background reconnects inside the loopback proxy.
  final bool autoReconnect;
  final AkeClient Function(DeviceCredentials credentials) _clientFactory;
  final DtcpMediaFetcher Function() _fetcherFactory;

  /// The engine itself is implemented; whether a credential pair
  /// has been imported is checked asynchronously in [startPlayback].
  @override
  bool get isSupported => true;

  Future<bool> get hasCredentials => credentialStore.hasCredentials;

  @override
  Future<PlaybackSession> startPlayback(RecordedTitle title, TitleRes res) {
    diag(
      DiagCategory.playback,
      'start: title=${title.title}; '
      'res quality=${res.quality ?? '(none)'}; '
      'credentials -> HEAD -> AKE -> proxy',
    );
    // Recorded content is seekable when the res carries both the
    // plaintext size and the duration (plan 61); the proxy falls
    // back to the unseekable stream when either is missing.
    return _start(
      res,
      seekTotalBytes: res.cleartextSize,
      seekTotalDuration: res.duration,
    );
  }

  /// Live viewing (plan 39): the identical path against the
  /// channel's stream resource. The stream is endless, which the
  /// proxy already serves as-is (chunked, no content length);
  /// the session runs until the caller stops it.
  @override
  Future<PlaybackSession> startLivePlayback(LiveChannel channel, TitleRes res) {
    diag(
      DiagCategory.playback,
      'start (live): channel=${channel.channelName ?? '(no name)'}; '
      'program=${channel.programTitle}; '
      'res quality=${res.quality ?? '(none)'}; '
      'credentials -> HEAD -> AKE -> proxy',
    );
    return _start(res, isLive: true);
  }

  static bool _isEncryptedProtocol(String protocolInfo) {
    final lower = protocolInfo.trim().toLowerCase();
    if (lower.isEmpty) return true;
    return lower.contains('application/x-dtcp1');
  }

  static bool _supportsDlnaTimeSeek(String protocolInfo) {
    return RegExp(
      r'DLNA\.ORG_OP=1[01]',
      caseSensitive: false,
    ).hasMatch(protocolInfo);
  }

  Future<PlaybackSession> _start(
    TitleRes res, {
    int? seekTotalBytes,
    Duration? seekTotalDuration,
    bool isLive = false,
  }) async {
    final stopwatch = Stopwatch()..start();
    var stage = 'credentials';
    AkeSession? session;
    final fetcher = _fetcherFactory();
    final isEncrypted = _isEncryptedProtocol(res.protocolInfo);
    final supportsTimeSeek =
        !isLive &&
        (seekTotalBytes == null || seekTotalBytes <= 0) &&
        seekTotalDuration != null &&
        seekTotalDuration > Duration.zero &&
        _supportsDlnaTimeSeek(res.protocolInfo);
    try {
      final contentUrl = Uri.parse(res.url);
      PlaybackKeySource? keySource;
      if (isEncrypted) {
        final credentials = await credentialStore.load();
        if (credentials == null) {
          throw NasneError.validation(
            'dtcp:playback',
            'DTCP-IP の資格情報がインポートされていません。設定画面の'
                '「DTCP-IP 資格情報」から、ご自身の対応機器のペアをインポートしてください。',
          );
        }
        stage = 'head';
        final (host, port) = await fetcher.akeEndpoint(contentUrl);
        diag(
          DiagCategory.playback,
          'stage head ok (${stopwatch.elapsedMilliseconds} ms)',
        );
        stage = 'ake';
        final client = _clientFactory(credentials);
        session = await client.connect(host, port);
        diag(
          DiagCategory.playback,
          'stage ake ok (${stopwatch.elapsedMilliseconds} ms)',
        );
        // The reference client returns from authenticate() only with
        // the first exchange key in hand (plan 28). Waiting here
        // keeps a missing key a start failure with a named stage,
        // instead of a stall inside the player.
        stage = 'exchange key';
        final label = await session.waitFirstExchangeKey();
        diag(
          DiagCategory.playback,
          'stage exchange key ok, label $label '
          '(${stopwatch.elapsedMilliseconds} ms)',
        );
        stage = 'proxy';
        // Keys for later labels (rotation) come from fresh
        // authentications: each re-authentication builds a NEW
        // client, because an AkeClient carries one session's state
        // (plan 29).
        keySource = PlaybackKeySource(
          session: session,
          reauthenticate: () async {
            final freshClient = _clientFactory(credentials);
            return freshClient.connect(host, port);
          },
          diag: diag,
        );
      } else {
        stage = 'proxy';
        diag(
          DiagCategory.playback,
          'stage head/ake skipped (clear HTTP stream)',
        );
      }
      final proxy = await DtcpProxy.start(
        contentUrl: contentUrl,
        keyForLabel:
            keySource?.keyForLabel ?? (_) async => Uint8List(12),
        fetcher: fetcher,
        diag: diag,
        totalBytes: seekTotalBytes,
        totalDuration: seekTotalDuration,
        windowCapBytesOverride: Platform.isAndroid
            ? androidProxyWindowCapBytes
            : null,
        isLive: isLive,
        isEncrypted: isEncrypted,
        supportsTimeSeek: supportsTimeSeek,
        autoReconnect: autoReconnect,
        onReauthenticate:
            (autoReconnect && keySource != null)
            ? keySource.forceReauthenticate
            : null,
      );
      diag(
        DiagCategory.playback,
        'playback ready at ${proxy.uri} '
        '(${stopwatch.elapsedMilliseconds} ms)',
      );
      return supportsTimeSeek
          ? _TimeSeekableDtcpPlaybackSession(proxy, keySource, fetcher)
          : _DtcpPlaybackSession(proxy, keySource, fetcher);
    } catch (e) {
      diag(DiagCategory.playback, 'failed at stage "$stage": $e');
      if (session != null) await session.close();
      fetcher.close();
      rethrow;
    }
  }
}

class _DtcpPlaybackSession
    implements
        PlaybackSession,
        StreamTransferMetrics,
        StreamDiagnosticMetrics,
        LiveEdgeResettable,
        AribCaptionLayoutSource {
  _DtcpPlaybackSession(this._proxy, this._keySource, this._fetcher);

  final DtcpProxy _proxy;
  final PlaybackKeySource? _keySource;
  final DtcpMediaFetcher _fetcher;
  bool _stopped = false;

  @override
  Uri get mediaUri => _proxy.uri;

  @override
  int get servedBytes => _proxy.servedBytes;

  @override
  DateTime? get firstByteServedAt => _proxy.firstByteServedAt;

  @override
  DateTime? get lastByteServedAt => _proxy.lastByteServedAt;

  @override
  int get consecutiveReconnectErrors => _proxy.consecutiveReconnectErrors;

  @override
  int get cipherBytes => _proxy.cipherBytes;

  @override
  int get plaintextBytes => _proxy.plaintextBytes;

  @override
  int get downstreamRequestCount => _proxy.downstreamRequestCount;

  @override
  Object? get lastUpstreamError => _proxy.lastUpstreamError;

  @override
  bool get isReconnectingUpstream => _proxy.isReconnectingUpstream;

  @override
  List<AribCaptionLayoutEvent> get aribCaptionEvents =>
      _proxy.aribCaptionEvents;

  @override
  List<AribCaptionLayoutEvent> get aribSuperimposeEvents =>
      _proxy.aribSuperimposeEvents;

  @override
  double? get firstStreamPtsSeconds => _proxy.firstStreamPtsSeconds;

  @override
  Future<void> resetToLiveEdge() => _proxy.resetToLiveEdge();

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    // Close the HTTP client synchronously before waiting on proxy/AKE teardown
    // so the upstream TCP socket drops immediately on user exit.
    _fetcher.close();
    try {
      await _proxy.stop();
      await _keySource?.close();
    } finally {
      _fetcher.close();
    }
  }
}

class _TimeSeekableDtcpPlaybackSession extends _DtcpPlaybackSession
    implements TimeSeekableSession {
  _TimeSeekableDtcpPlaybackSession(
    super.proxy,
    super.keySource,
    super.fetcher,
  );

  @override
  Duration? get totalDuration => _proxy.totalDuration;

  @override
  Future<void> seekToTime(Duration target) => _proxy.seekToTime(target);
}
