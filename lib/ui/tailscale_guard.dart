/// Fire TV Tailscale / VPN auto-check & startup media volume maxing.
///
/// On app launch and whenever returning from another app (such as Tailscale),
/// checks whether the registered nasne is reachable. If unreachable and VPN is
/// inactive while Tailscale is installed, tries the background connect broadcast
/// first, then offers a 1-click D-pad dialog to open Tailscale directly.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/firetv_helper.dart';
import '../app/providers.dart';
import '../app/state.dart';
import '../core/core.dart';

class TailscaleGuard extends ConsumerStatefulWidget {
  const TailscaleGuard({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TailscaleGuard> createState() => _TailscaleGuardState();
}

class _TailscaleGuardState extends ConsumerState<TailscaleGuard>
    with WidgetsBindingObserver {
  bool _startupChecked = false;
  bool _checking = false;
  bool _dialogOpen = false;
  bool _dismissedForSession = false;
  bool _waitingForTailscaleReturn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_onStartup());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _onStartup() async {
    final helper = ref.read(fireTvHelperProvider);
    if (!helper.isAndroid || !ref.read(uiControlModeProvider).isTv) return;
    await helper.setMediaVolumeMax();
    if (!mounted) return;
    final reg = ref.read(selectedRegistrationProvider);
    if (reg != null && !_startupChecked) {
      _startupChecked = true;
      await _checkReachability(reg);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final helper = ref.read(fireTvHelperProvider);
    if (!helper.isAndroid || !ref.read(uiControlModeProvider).isTv) return;
    unawaited(helper.setMediaVolumeMax());
    final reg = ref.read(selectedRegistrationProvider);
    if (reg == null) return;
    if (_waitingForTailscaleReturn) {
      unawaited(_checkReachability(reg, force: true));
    }
  }

  Future<void> _checkReachability(
    RegisteredNasne reg, {
    bool force = false,
  }) async {
    final helper = ref.read(fireTvHelperProvider);
    if (!helper.isAndroid || !ref.read(uiControlModeProvider).isTv) return;
    if (_checking || _dialogOpen) return;
    if (!force && _dismissedForSession) return;
    _checking = true;
    try {
      final regs =
          ref.read(registrationsProvider).value ?? <RegisteredNasne>[reg];
      var reachable = await helper.isNasneReachable(reg.host);
      if (!reachable && regs.length > 1) {
        for (final other in regs) {
          if (other.host == reg.host) continue;
          if (await helper.isNasneReachable(other.host)) {
            reachable = true;
            break;
          }
        }
      }
      if (!mounted) return;
      if (reachable) {
        if (_waitingForTailscaleReturn) {
          _waitingForTailscaleReturn = false;
          invalidateDeviceData(ref, reg);
          _showSnack('nasne に接続しました。情報を更新します。');
        }
        return;
      }

      final vpnActive = await helper.isVpnActive();
      if (!mounted || vpnActive) {
        if (vpnActive && _waitingForTailscaleReturn) {
          _waitingForTailscaleReturn = false;
          invalidateDeviceData(ref, reg);
        }
        return;
      }

      final installed = await helper.isTailscaleInstalled();
      if (!mounted || !installed) return;

      // Attempt background connect broadcast first before interrupting the user.
      final sent = await helper.tryConnectTailscale();
      if (sent) {
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          if (!mounted) return;
          if (await helper.isVpnActive() ||
              await helper.isNasneReachable(reg.host)) {
            _waitingForTailscaleReturn = false;
            invalidateDeviceData(ref, reg);
            _showSnack('Tailscale に接続しました');
            return;
          }
        }
      }

      if (!mounted) return;
      await _showTailscaleDialog(reg, helper);
    } finally {
      _checking = false;
    }
  }

  Future<void> _showTailscaleDialog(
    RegisteredNasne reg,
    FireTvHelper helper,
  ) async {
    if (_dialogOpen || !mounted) return;
    _dialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Tailscale が起動していません'),
          content: Text(
            'nasne (${reg.host}) に接続できませんでした。\n'
            '外出先から利用する場合は Tailscale を起動して VPN をオンにしてください'
            '（戻ると自動で再確認します）。',
          ),
          actions: [
            TextButton(
              onPressed: () {
                _dismissedForSession = true;
                _waitingForTailscaleReturn = false;
                Navigator.of(dialogContext).pop();
              },
              child: const Text('このまま使う'),
            ),
            OutlinedButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                unawaited(_checkReachability(reg, force: true));
              },
              child: const Text('再確認'),
            ),
            FilledButton(
              autofocus: true,
              onPressed: () {
                _waitingForTailscaleReturn = true;
                Navigator.of(dialogContext).pop();
                unawaited(_openTailscale(helper));
              },
              child: const Text('Tailscale を開く'),
            ),
          ],
        ),
      );
    } finally {
      _dialogOpen = false;
    }
  }

  Future<void> _openTailscale(FireTvHelper helper) async {
    final launched = await helper.launchTailscale();
    if (!launched && mounted) {
      _waitingForTailscaleReturn = false;
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

  @override
  Widget build(BuildContext context) {
    ref.listen<RegisteredNasne?>(selectedRegistrationProvider, (prev, next) {
      if (next == null) return;
      final helper = ref.read(fireTvHelperProvider);
      if (!helper.isAndroid) return;
      if (!_startupChecked || prev?.host != next.host) {
        _startupChecked = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_checkReachability(next));
        });
      }
    });
    return widget.child;
  }
}
