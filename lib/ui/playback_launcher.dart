/// Shared playback-start flow (plan 39, extracted from the title
/// detail view where it was built for recordings in plan 28/33):
/// run the engine start, push the player screen on success, and
/// turn each failure category into its dialog — the unsupported
/// notice, the credential-import guidance, or the classified
/// error dialog that names the failing stage. Recorded playback
/// and live viewing share this; only the start call, the player
/// screen and the wording differ.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../core/core.dart';
import 'dtcp_credential_screen.dart';
import 'error_messages.dart';
import 'widgets.dart';

enum _PlaybackErrorAction { close, retry, waitForTuner }

/// Starts a session via [start] and shows the player built by
/// [buildPlayer]. A start that finishes after the caller has
/// left is stopped again immediately. [unsupportedSubject] names
/// what cannot play in the unsupported notice (録画の再生 /
/// TV視聴); [startFailureMessage] is the fallback snack for
/// unclassified failures.
Future<void> startPlaybackAndShowPlayer({
  required BuildContext context,
  required WidgetRef ref,
  required Future<PlaybackSession> Function() start,
  required Widget Function(PlaybackSession session) buildPlayer,
  required String unsupportedSubject,
  String startFailureMessage = '再生を開始できませんでした',
  Duration tunerWaitInterval = const Duration(seconds: 5),
  Duration tunerWaitMaxDuration = const Duration(seconds: 150),
}) async {
  NasneError? pendingError;
  while (true) {
    if (pendingError == null) {
      try {
        final session = await start();
        if (!context.mounted) {
          await session.stop();
          return;
        }
        await Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => buildPlayer(session)),
        );
        return;
      } on NasneError catch (e) {
        if (!context.mounted) return;
        pendingError = e;
      } catch (e) {
        if (!context.mounted) return;
        ref.read(diagLogProvider)(
          DiagCategory.ui,
          'playback start failed (unclassified): $e',
        );
        showSnack(context, startFailureMessage);
        return;
      }
    }

    final e = pendingError;
    pendingError = null;
    if (!context.mounted) return;
    if (e.category == NasneErrorCategory.unsupported) {
      await showPlaybackUnsupportedDialog(
        context,
        subject: unsupportedSubject,
      );
      return;
    }
    if (e.category == NasneErrorCategory.validation) {
      await showCredentialGuidanceDialog(context, userMessageForError(e));
      return;
    }

    // Name the failing stage instead of collapsing everything
    // into one opaque snack (plan 28): the dialog leads with
    // the plain explanation and what to do next, and keeps
    // the classification in its detail section (plan 86).
    // The failure is also recorded under the ui category
    // when debug mode is on. No credential or key material
    // is included.
    ref.read(diagLogProvider)(DiagCategory.ui, 'playback start failed: $e');
    debugPrint(
      '[tmhb:play] start failed: ${e.category.name} ${e.source} '
      'code=${e.code ?? '-'} detail=${e.detail ?? '-'}',
    );
    final action = await _showPlaybackErrorActionDialog(
      context,
      e,
      canRetry: true,
      allowWaitForTuner: isTunerBusyError(e),
    );
    if (!context.mounted) return;
    if (action == _PlaybackErrorAction.close) return;
    if (action == _PlaybackErrorAction.waitForTuner) {
      final waitResult = await _showTunerBusyWaitDialog(
        context: context,
        start: start,
        initialError: e,
        pollInterval: tunerWaitInterval,
        maxWait: tunerWaitMaxDuration,
      );
      if (!context.mounted) {
        if (waitResult.session != null) {
          await waitResult.session!.stop();
        }
        return;
      }
      if (waitResult.cancelled) return;
      if (waitResult.session != null) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => buildPlayer(waitResult.session!),
          ),
        );
        return;
      }
      if (waitResult.nasneError != null) {
        pendingError = waitResult.nasneError;
        continue;
      }
      if (waitResult.unexpectedError != null) {
        ref.read(diagLogProvider)(
          DiagCategory.ui,
          'playback start failed (unclassified): ${waitResult.unexpectedError}',
        );
        showSnack(context, startFailureMessage);
        return;
      }
    }
  }
}

/// The playback start error dialog (plan 28; reworked in
/// plan 86, plan 85 item 9).
///
/// What the viewer sees first is the plain explanation and
/// what to do next. The classification the plan-28 dialog
/// used to lead with — category / source / code / detail —
/// is diagnostic information a viewer cannot act on, so it
/// now sits in a collapsed 「詳細」 section at the bottom;
/// the same facts are in the diagnostic log as well, so
/// nothing is lost by moving them out of the way.
Future<bool> showPlaybackErrorDialog(
  BuildContext context,
  NasneError e, {
  bool canRetry = false,
}) async {
  final action = await _showPlaybackErrorActionDialog(
    context,
    e,
    canRetry: canRetry,
    allowWaitForTuner: false,
  );
  return action == _PlaybackErrorAction.retry;
}

Future<_PlaybackErrorAction> _showPlaybackErrorActionDialog(
  BuildContext context,
  NasneError e, {
  required bool canRetry,
  required bool allowWaitForTuner,
}) async {
  final nextStep = errorNextStepForError(e);
  final showWait = canRetry && allowWaitForTuner;
  final action = await showDialog<_PlaybackErrorAction>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('再生を開始できませんでした'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(userMessageForError(e)),
            if (nextStep != null) ...[
              const SizedBox(height: 12),
              Text(nextStep),
            ],
            const SizedBox(height: 8),
            ExpansionTile(
              title: const Text('詳細'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    errorDetailText(e),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          autofocus: !canRetry,
          onPressed: () =>
              Navigator.of(context).pop(_PlaybackErrorAction.close),
          child: const Text('閉じる'),
        ),
        if (canRetry)
          if (showWait)
            OutlinedButton.icon(
              onPressed: () =>
                  Navigator.of(context).pop(_PlaybackErrorAction.retry),
              icon: const Icon(Icons.refresh),
              label: const Text('再試行'),
            )
          else
            FilledButton.icon(
              autofocus: true,
              onPressed: () =>
                  Navigator.of(context).pop(_PlaybackErrorAction.retry),
              icon: const Icon(Icons.refresh),
              label: const Text('再試行'),
            ),
        if (showWait)
          FilledButton.icon(
            autofocus: true,
            onPressed: () =>
                Navigator.of(context).pop(_PlaybackErrorAction.waitForTuner),
            icon: const Icon(Icons.hourglass_top),
            label: const Text('空きを待って自動再生'),
          ),
      ],
    ),
  );
  return action ?? _PlaybackErrorAction.close;
}

class _TunerWaitResult {
  const _TunerWaitResult._({
    this.session,
    this.nasneError,
    this.unexpectedError,
    this.cancelled = false,
  });

  const _TunerWaitResult.cancelled() : this._(cancelled: true);

  const _TunerWaitResult.success(PlaybackSession session)
      : this._(session: session);

  const _TunerWaitResult.nasneError(NasneError error)
      : this._(nasneError: error);

  const _TunerWaitResult.unexpectedError(Object error)
      : this._(unexpectedError: error);

  final PlaybackSession? session;
  final NasneError? nasneError;
  final Object? unexpectedError;
  final bool cancelled;
}

Future<_TunerWaitResult> _showTunerBusyWaitDialog({
  required BuildContext context,
  required Future<PlaybackSession> Function() start,
  required NasneError initialError,
  required Duration pollInterval,
  required Duration maxWait,
}) async {
  final result = await showDialog<_TunerWaitResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _TunerBusyWaitDialog(
      start: start,
      initialError: initialError,
      pollInterval: pollInterval,
      maxWait: maxWait,
    ),
  );
  return result ?? const _TunerWaitResult.cancelled();
}

class _TunerBusyWaitDialog extends StatefulWidget {
  const _TunerBusyWaitDialog({
    required this.start,
    required this.initialError,
    required this.pollInterval,
    required this.maxWait,
  });

  final Future<PlaybackSession> Function() start;
  final NasneError initialError;
  final Duration pollInterval;
  final Duration maxWait;

  @override
  State<_TunerBusyWaitDialog> createState() => _TunerBusyWaitDialogState();
}

class _TunerBusyWaitDialogState extends State<_TunerBusyWaitDialog> {
  final Stopwatch _sw = Stopwatch();
  Timer? _pollTimer;
  late NasneError _lastError = widget.initialError;
  bool _cancelled = false;
  bool _checking = false;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _sw.start();
    _pollTimer = Timer(widget.pollInterval, _attemptStart);
  }

  @override
  void dispose() {
    _cancelled = true;
    _pollTimer?.cancel();
    _sw.stop();
    super.dispose();
  }

  void _cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _pollTimer?.cancel();
    if (mounted) {
      Navigator.of(context).pop(const _TunerWaitResult.cancelled());
    }
  }

  Future<void> _attemptStart() async {
    if (_cancelled || !mounted) return;
    if (_sw.elapsed >= widget.maxWait) {
      Navigator.of(context).pop(_TunerWaitResult.nasneError(_lastError));
      return;
    }
    setState(() {
      _attempt++;
      _checking = true;
    });
    try {
      final session = await widget.start();
      if (_cancelled || !mounted) {
        await session.stop();
        return;
      }
      Navigator.of(context).pop(_TunerWaitResult.success(session));
    } on NasneError catch (e) {
      if (_cancelled || !mounted) return;
      if (isTunerBusyError(e) && _sw.elapsed < widget.maxWait) {
        _lastError = e;
        setState(() => _checking = false);
        _pollTimer = Timer(widget.pollInterval, _attemptStart);
      } else {
        Navigator.of(context).pop(_TunerWaitResult.nasneError(e));
      }
    } catch (e) {
      if (_cancelled || !mounted) return;
      Navigator.of(context).pop(_TunerWaitResult.unexpectedError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusText = _checking
        ? 'チューナーの空きを確認しています（$_attempt 回目）...'
        : _attempt == 0
            ? 'チューナーが空くのを待っています...'
            : '引き続き待機しています（$_attempt 回確認済み）...';
    return AlertDialog(
      title: const Text('チューナーの空きを待機中'),
      content: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(statusText),
                const SizedBox(height: 6),
                Text(
                  '空き次第、自動で再生を開始します（最大 ${widget.maxWait.inSeconds} 秒）。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: _cancel,
          child: const Text('キャンセル'),
        ),
      ],
    );
  }
}

/// Guidance shown when the credential pair has not been imported.
///
/// Plan 86.2 (plan 85 item 2): the dialog leads straight to the
/// import screen. Before this its only action was "close", and
/// the viewer had to go and find the credential entry in the
/// settings tab themselves — the step where the playback path
/// lost people who did not already know the app.
Future<void> showCredentialGuidanceDialog(
  BuildContext context,
  String message,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('資格情報が必要です'),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('閉じる'),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () {
            final navigator = Navigator.of(context);
            navigator.pop();
            navigator.push(
              MaterialPageRoute<void>(
                builder: (_) => const DtcpCredentialScreen(),
              ),
            );
          },
          child: const Text('インポートする'),
        ),
      ],
    ),
  );
}

/// The notice shown when the configured engine cannot play.
Future<void> showPlaybackUnsupportedDialog(
  BuildContext context, {
  required String subject,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('再生は未実装です'),
      content: Text(
        '$subjectには DTCP-IP の資格情報 (DTLA 署名の証明書と機器秘密鍵のペア) '
        'が必要です。資格情報ペアが得られていないため、再生は未実装です。',
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('閉じる'),
        ),
      ],
    ),
  );
}
