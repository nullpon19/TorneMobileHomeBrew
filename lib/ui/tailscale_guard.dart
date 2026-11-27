/// Fire TV Tailscale / VPN startup gate, auto-connect & media volume maxing.
///
/// On Android TV cold boot with Tailscale installed, gates mounting the main
/// nasne-fetching tabs until quick parallel reachability or Tailscale VPN
/// connection finishes (so pre-VPN requests do not saturate sockets and stall
/// discovery/HTTP for 30-60s). When returning from Tailscale (dialed via the
/// prompt, the rail icon, or the Fire TV home screen), waits for actual TCP
/// reachability to nasne, closes pre-VPN sockets, and refreshes all registered
/// devices cleanly. When Tailscale is not installed (or on non-TV devices),
/// passes straight through without showing any Tailscale UI.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/firetv_helper.dart';
import '../app/providers.dart';
import '../app/state.dart';
import '../core/core.dart';

enum _TailscaleDialogAction { dismiss, retry, openTailscale }

class TailscaleGuard extends ConsumerStatefulWidget {
  const TailscaleGuard({
    super.key,
    required this.child,
    this.probeTimeout = const Duration(milliseconds: 900),
    this.pollInterval = const Duration(milliseconds: 300),
    this.autoConnectMaxWait = const Duration(milliseconds: 6500),
    this.postVpnReachableMaxWait = const Duration(seconds: 12),
  });

  final Widget child;
  final Duration probeTimeout;
  final Duration pollInterval;
  final Duration autoConnectMaxWait;
  final Duration postVpnReachableMaxWait;

  @override
  ConsumerState<TailscaleGuard> createState() => _TailscaleGuardState();
}

class _TailscaleGuardState extends ConsumerState<TailscaleGuard>
    with WidgetsBindingObserver {
  bool _startupChecked = false;
  bool _startupScheduled = false;
  bool _gateActive = false;
  bool _checking = false;
  bool _dialogOpen = false;
  bool _dismissedForSession = false;
  bool _waitingForTailscaleReturn = false;
  bool _lastReachable = false;
  bool _showGateActions = false;
  String _statusMessage = 'nasne への接続を確認しています…';
  String? _checkedFirstHost;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initTvVolume());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _initTvVolume() async {
    final helper = ref.read(fireTvHelperProvider);
    if (!helper.isAndroid || !ref.read(uiControlModeProvider).isTv) return;
    await helper.setMediaVolumeMax();
  }

  bool get _isAndroidTv =>
      ref.read(fireTvHelperProvider).isAndroid &&
      ref.read(uiControlModeProvider).isTv;

  void _releaseGate({bool markReachable = false}) {
    if (!mounted) return;
    if (markReachable) _lastReachable = true;
    _startupChecked = true;
    if (_gateActive || _showGateActions) {
      setState(() {
        _gateActive = false;
        _showGateActions = false;
      });
    }
  }

  void _updateGateStatus(String message, {bool showActions = true}) {
    if (!mounted) return;
    if (!_gateActive && _startupChecked) {
      _showSnack(message);
      return;
    }
    setState(() {
      _gateActive = true;
      _statusMessage = message;
      _showGateActions = showActions;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final helper = ref.read(fireTvHelperProvider);
    if (!helper.isAndroid || !ref.read(uiControlModeProvider).isTv) return;
    unawaited(helper.setMediaVolumeMax());
    final regs = ref.read(registrationsProvider).value ?? const <RegisteredNasne>[];
    if (regs.isEmpty) return;
    if (_waitingForTailscaleReturn) {
      unawaited(_checkReachability(regs, force: true, fromReturn: true));
      return;
    }
    if (!_lastReachable && !_dismissedForSession) {
      unawaited(() async {
        final vpnActive = await helper.isVpnActive();
        if (!mounted || !vpnActive) return;
        await _checkReachability(regs, force: true, fromReturn: true);
      }());
    }
  }

  void _maybeScheduleStartupCheck(List<RegisteredNasne> regs) {
    if (_checking || _startupScheduled || regs.isEmpty) return;
    final firstHost = regs.first.host;
    if (_startupChecked && _checkedFirstHost == firstHost) return;
    _startupScheduled = true;
    _checkedFirstHost = firstHost;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startupScheduled = false;
      if (!mounted) return;
      unawaited(_checkReachability(regs));
    });
  }

  Future<bool> _pollUntilReachable(
    FireTvHelper helper,
    List<String> hosts, {
    required Duration maxWait,
    bool ignoreDismissed = false,
  }) async {
    final wallClock = Stopwatch()..start();
    final steps = widget.pollInterval > Duration.zero
        ? (maxWait.inMilliseconds / widget.pollInterval.inMilliseconds)
            .ceil()
            .clamp(1, 100)
        : 1;
    for (var i = 0; i < steps; i++) {
      if (!mounted || (!ignoreDismissed && _dismissedForSession)) return false;
      final remaining = maxWait - wallClock.elapsed;
      if (remaining <= Duration.zero) return false;
      final stepTimeout =
          remaining < widget.probeTimeout ? remaining : widget.probeTimeout;
      if (await helper.isAnyNasneReachable(hosts, timeout: stepTimeout)) {
        return true;
      }
      if (!mounted || (!ignoreDismissed && _dismissedForSession)) return false;
      final afterRemaining = maxWait - wallClock.elapsed;
      if (afterRemaining <= Duration.zero) return false;
      final delay = afterRemaining < widget.pollInterval
          ? afterRemaining
          : widget.pollInterval;
      await Future<void>.delayed(delay);
    }
    return false;
  }

  Future<void> _checkReachability(
    List<RegisteredNasne> regs, {
    bool force = false,
    bool fromReturn = false,
  }) async {
    final helper = ref.read(fireTvHelperProvider);
    if (!helper.isAndroid || !ref.read(uiControlModeProvider).isTv) {
      _releaseGate();
      return;
    }
    if (regs.isEmpty) {
      _releaseGate();
      return;
    }
    if (_checking || _dialogOpen) return;
    if (force) {
      _dismissedForSession = false;
    } else if (_dismissedForSession) {
      _releaseGate();
      return;
    }

    _checking = true;
    final hosts = [for (final r in regs) r.host];
    final wasReachable = _lastReachable;
    final wasWaitingReturn = _waitingForTailscaleReturn;
    var shouldShowDialog = false;

    try {
      bool installed;
      try {
        installed = await ref.read(tailscaleInstalledProvider.future);
      } catch (_) {
        installed = await helper.isTailscaleInstalled();
      }
      if (!mounted) return;
      if (!installed) {
        _releaseGate();
        return;
      }

      if (await helper.isAnyNasneReachable(
        hosts,
        timeout: widget.probeTimeout,
      )) {
        if (!mounted) return;
        _waitingForTailscaleReturn = false;
        _lastReachable = true;
        final shouldReset =
            fromReturn || wasWaitingReturn || !wasReachable && _startupChecked;
        _releaseGate(markReachable: true);
        if (shouldReset) {
          resetNetworkAndInvalidateDevices(ref, regs);
          _showSnack('nasne に接続しました。情報を更新します。');
        }
        return;
      }
      if (!mounted || (!force && _dismissedForSession)) {
        _releaseGate();
        return;
      }

      if (await helper.isVpnActive()) {
        if (!mounted) return;
        _updateGateStatus('Tailscale 接続済み — nasne の応答を待機中…');
        final becameReachable = await _pollUntilReachable(
          helper,
          hosts,
          maxWait: widget.postVpnReachableMaxWait,
          ignoreDismissed: force,
        );
        if (!mounted) return;
        _waitingForTailscaleReturn = false;
        if (becameReachable) {
          _lastReachable = true;
          _releaseGate(markReachable: true);
          resetNetworkAndInvalidateDevices(ref, regs);
          _showSnack('nasne に接続しました');
          return;
        }
        if (fromReturn || wasWaitingReturn) {
          resetNetworkAndInvalidateDevices(ref, regs);
        }
        _releaseGate();
        return;
      }

      // VPN is inactive and nasne is unreachable: attempt background connect
      // first before showing the D-pad Tailscale prompt.
      _updateGateStatus('Tailscale に自動接続しています…');
      final sent = await helper.tryConnectTailscale();
      if (!mounted || (!force && _dismissedForSession)) {
        _releaseGate();
        return;
      }

      if (sent) {
        final connectClock = Stopwatch()..start();
        final steps = widget.pollInterval > Duration.zero
            ? (widget.autoConnectMaxWait.inMilliseconds /
                    widget.pollInterval.inMilliseconds)
                .ceil()
                .clamp(1, 40)
            : 1;
        for (var i = 0; i < steps; i++) {
          final remainingDelay = widget.autoConnectMaxWait - connectClock.elapsed;
          if (remainingDelay <= Duration.zero) break;
          final delay = remainingDelay < widget.pollInterval
              ? remainingDelay
              : widget.pollInterval;
          await Future<void>.delayed(delay);
          if (!mounted || (!force && _dismissedForSession)) {
            _releaseGate();
            return;
          }
          final probeBudget = widget.autoConnectMaxWait - connectClock.elapsed;
          final stepTimeout = probeBudget > Duration.zero &&
                  probeBudget < widget.probeTimeout
              ? probeBudget
              : widget.probeTimeout;
          if (await helper.isAnyNasneReachable(
            hosts,
            timeout: stepTimeout,
          )) {
            _waitingForTailscaleReturn = false;
            _lastReachable = true;
            _releaseGate(markReachable: true);
            resetNetworkAndInvalidateDevices(ref, regs);
            _showSnack('Tailscale に接続しました');
            return;
          }
          if (await helper.isVpnActive()) {
            _updateGateStatus('Tailscale 接続済み — nasne の応答を待機中…');
            final becameReachable = await _pollUntilReachable(
              helper,
              hosts,
              maxWait: widget.postVpnReachableMaxWait,
              ignoreDismissed: force,
            );
            if (!mounted) return;
            _waitingForTailscaleReturn = false;
            if (becameReachable) {
              _lastReachable = true;
              _releaseGate(markReachable: true);
              resetNetworkAndInvalidateDevices(ref, regs);
              _showSnack('Tailscale に接続しました');
            } else {
              _releaseGate();
            }
            return;
          }
        }
      }

      if (!mounted || (!force && _dismissedForSession)) {
        _releaseGate();
        return;
      }
      _startupChecked = true;
      shouldShowDialog = true;
    } finally {
      _checking = false;
    }

    if (shouldShowDialog && mounted && !_dismissedForSession) {
      await _showTailscaleDialog(regs, helper);
    }
  }

  Future<void> _showTailscaleDialog(
    List<RegisteredNasne> regs,
    FireTvHelper helper,
  ) async {
    if (_dialogOpen || !mounted) return;
    _dialogOpen = true;
    if (mounted && _gateActive) {
      setState(() => _showGateActions = false);
    }
    final primaryReg = regs.first;
    _TailscaleDialogAction? action;
    try {
      action = await showDialog<_TailscaleDialogAction>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Tailscale が起動していません'),
          content: Text(
            'nasne (${primaryReg.host}) に接続できませんでした。\n'
            '外出先から利用する場合は Tailscale を起動して VPN をオンにしてください'
            '（戻ると自動で再確認します）。',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_TailscaleDialogAction.dismiss),
              child: const Text('このまま使う'),
            ),
            OutlinedButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_TailscaleDialogAction.retry),
              child: const Text('再確認'),
            ),
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.of(dialogContext).pop(
                _TailscaleDialogAction.openTailscale,
              ),
              child: const Text('Tailscale を開く'),
            ),
          ],
        ),
      );
    } finally {
      _dialogOpen = false;
    }
    if (!mounted) return;
    switch (action) {
      case _TailscaleDialogAction.retry:
        _dismissedForSession = false;
        unawaited(_checkReachability(regs, force: true));
      case _TailscaleDialogAction.openTailscale:
        _waitingForTailscaleReturn = true;
        _updateGateStatus('Tailscale の接続を待機しています…', showActions: true);
        unawaited(_openTailscale(helper));
      case _TailscaleDialogAction.dismiss:
      case null:
        _dismissedForSession = true;
        _waitingForTailscaleReturn = false;
        _releaseGate();
    }
  }

  Future<void> _openTailscale(FireTvHelper helper) async {
    final launched = await helper.launchTailscale();
    if (!launched && mounted) {
      _waitingForTailscaleReturn = false;
      _releaseGate();
      _showSnack('Tailscale アプリが見つかりませんでした');
    }
  }

  void _showSnack(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildStartupGate(List<RegisteredNasne> regs) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 28,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_checking)
                      const CircularProgressIndicator()
                    else
                      const Icon(Icons.vpn_lock, size: 40),
                    const SizedBox(height: 18),
                    Text(
                      _statusMessage,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (_showGateActions) ...[
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          TextButton(
                            onPressed: () {
                              _dismissedForSession = true;
                              _waitingForTailscaleReturn = false;
                              _releaseGate();
                            },
                            child: const Text('このまま進む'),
                          ),
                          FilledButton.icon(
                            onPressed: () {
                              _waitingForTailscaleReturn = true;
                              unawaited(
                                _openTailscale(ref.read(fireTvHelperProvider)),
                              );
                            },
                            icon: const Icon(Icons.vpn_lock),
                            label: const Text('Tailscale を開く'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(tailscaleManualLaunchSignalProvider, (_, _) {
      _waitingForTailscaleReturn = true;
    });
    ref.listen<AsyncValue<List<RegisteredNasne>>>(registrationsProvider, (
      prev,
      next,
    ) {
      final list = next.value;
      if (!_isAndroidTv) return;
      if (list != null && list.isNotEmpty) {
        _maybeScheduleStartupCheck(list);
      } else if (next.hasValue || next.hasError) {
        _releaseGate();
      }
    });
    ref.listen<RegisteredNasne?>(selectedRegistrationProvider, (prev, next) {
      if (next == null || !_isAndroidTv) return;
      if (!_startupChecked) {
        final regs =
            ref.read(registrationsProvider).value ?? <RegisteredNasne>[next];
        _maybeScheduleStartupCheck(regs);
      }
    });

    final isAndroidTv =
        ref.read(fireTvHelperProvider).isAndroid &&
        ref.watch(uiControlModeProvider).isTv;
    if (!isAndroidTv) {
      return widget.child;
    }

    final regsAsync = ref.watch(registrationsProvider);
    final regs = regsAsync.value ?? const <RegisteredNasne>[];
    final installedAsync = ref.watch(tailscaleInstalledProvider);

    if (regs.isNotEmpty && !_startupChecked && !_dismissedForSession) {
      if (installedAsync.hasValue && installedAsync.value == false) {
        _startupChecked = true;
        _gateActive = false;
      } else {
        _gateActive = true;
        _maybeScheduleStartupCheck(regs);
      }
    }

    if (_gateActive) {
      if (_dialogOpen) {
        return const Scaffold(body: SizedBox.shrink());
      }
      return _buildStartupGate(regs);
    }
    return widget.child;
  }
}
