/// The app shell (plan 5.6 / 12.7): six destinations — home /
/// status, live viewing (plan 39), schedules, recorded titles,
/// programme guide, settings — with the navigation form switching
/// by width: a bottom navigation bar on phones, a side rail on
/// tablets and wider layouts.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../app/state.dart';
import '../core/core.dart';
import 'epg_screen.dart';
import 'home_screen.dart';
import 'live_screen.dart';
import 'schedules_screen.dart';
import 'settings_screen.dart';
import 'tailscale_guard.dart';
import 'titles_screen.dart';

/// Width at or above which the shell uses a navigation rail.
const double railBreakpoint = 720;

/// Minimum top clearance guaranteed in the rail (wide) layout, in
/// logical pixels. Some environments (LiveContainer on iPad, observed
/// 2026-11-17) report a top safe-area inset smaller than the status
/// bar actually drawn over the app, which left the rail and the
/// screens' app bars flush with the top edge of the screen. The
/// screens' app bars already consume the reported inset, so the shell
/// only tops up the shortfall below this floor; where the inset is
/// reported correctly nothing is added. The phone (bottom bar) layout
/// is unaffected.
const double wideLayoutMinTopInset = 24;

/// Per-tab Back-button interceptors checked before showing the root app exit
/// confirmation dialog. Returning `true` consumes Back within that tab.
final tabBackHandlersProvider = Provider<Map<int, bool Function()>>(
  (ref) => <int, bool Function()>{},
);

/// Signals whether a nested UI flow inside the active touch tab (e.g. a DLNA
/// subfolder stack) should intercept the Android system Back button before exit.
class TouchBackInterceptNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setActive(bool active) {
    if (ref.mounted && state != active) {
      state = active;
    }
  }
}

final touchBackInterceptProvider =
    NotifierProvider<TouchBackInterceptNotifier, bool>(
      TouchBackInterceptNotifier.new,
    );

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();

  static const _destinations = [
    (icon: Icons.home_outlined, selectedIcon: Icons.home, label: 'ホーム'),
    (
      icon: Icons.live_tv_outlined,
      selectedIcon: Icons.live_tv,
      label: 'TV視聴',
    ),
    (
      icon: Icons.event_note_outlined,
      selectedIcon: Icons.event_note,
      label: '予約',
    ),
    (
      icon: Icons.video_library_outlined,
      selectedIcon: Icons.video_library,
      label: '録画済み',
    ),
    (
      icon: Icons.view_week_outlined,
      selectedIcon: Icons.view_week,
      label: '番組表',
    ),
    (icon: Icons.settings_outlined, selectedIcon: Icons.settings, label: '設定'),
  ];

}

class _AppShellState extends ConsumerState<AppShell> {
  static const _destinations = AppShell._destinations;
  bool _exitDialogOpen = false;
  bool _userMovedIntoInitialPane = false;
  late final int _initialTab;
  final Set<int> _mountedTabs = <int>{};
  final FocusNode _railFocusNode = FocusNode(debugLabel: 'appShellRail');
  final FocusNode _rightPaneFocusNode = FocusNode(
    debugLabel: 'appShellRightPane',
  );
  late final List<GlobalKey> _railLabelKeys = List<GlobalKey>.generate(
    _destinations.length,
    (_) => GlobalKey(),
  );

  @override
  void initState() {
    super.initState();
    _initialTab = ref.read(tabIndexProvider);
    _mountedTabs.add(_initialTab);
    _railFocusNode.addListener(_handleRailFocusChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!ref.read(uiControlModeProvider).isTv) return;
      if (_railFocusNode.context != null && !_railFocusNode.hasFocus) {
        _focusSelectedRailDestination(ref.read(tabIndexProvider));
      }
    });
  }

  @override
  void dispose() {
    _railFocusNode.removeListener(_handleRailFocusChange);
    _railFocusNode.dispose();
    _rightPaneFocusNode.dispose();
    super.dispose();
  }

  static double _horizontalEdgeDistance(Rect rect, double x) {
    if (x < rect.left) return rect.left - x;
    if (x > rect.right) return x - rect.right;
    return 0.0;
  }

  KeyEventResult _handleRightPaneKeyEvent(FocusNode node, KeyEvent event) {
    if ((event is! KeyDownEvent && event is! KeyRepeatEvent) ||
        event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || primary.context == null) {
      return KeyEventResult.ignored;
    }
    final primaryRect = primary.rect;
    final candidates = _rightPaneFocusNode.traversalDescendants
        .where(
          (n) =>
              n != primary &&
              n.canRequestFocus &&
              !n.skipTraversal &&
              n.context != null,
        )
        .toList();
    final above = <FocusNode>[];
    for (final c in candidates) {
      final r = c.rect;
      if (r.width <= 0 || r.height <= 0) continue;
      if (r.center.dy <= primaryRect.top - 1) {
        above.add(c);
      }
    }
    if (above.isEmpty) return KeyEventResult.ignored;
    final hasInBand = above.any((c) {
      final r = c.rect;
      return r.right > primaryRect.left && r.left < primaryRect.right;
    });
    if (hasInBand) return KeyEventResult.ignored;
    above.sort((a, b) {
      final dyCmp = (primaryRect.top - a.rect.center.dy).abs().compareTo(
        (primaryRect.top - b.rect.center.dy).abs(),
      );
      if (dyCmp != 0) return dyCmp;
      return _horizontalEdgeDistance(a.rect, primaryRect.center.dx).compareTo(
        _horizontalEdgeDistance(b.rect, primaryRect.center.dx),
      );
    });
    above.first.requestFocus();
    return KeyEventResult.handled;
  }

  void _handleRailFocusChange() {
    if (_railFocusNode.hasFocus) {
      _userMovedIntoInitialPane = false;
    }
  }

  void _restoreInitialRailFocusIfNeeded() {
    if (!ref.read(uiControlModeProvider).isTv) return;
    if (ref.read(tabIndexProvider) != _initialTab ||
        _userMovedIntoInitialPane) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(tabIndexProvider) != _initialTab ||
          _userMovedIntoInitialPane) {
        return;
      }
      if (_railFocusNode.context != null && !_railFocusNode.hasFocus) {
        _focusSelectedRailDestination(_initialTab);
      }
    });
  }

  bool _focusSelectedRailDestination(int activeTab) {
    if (_railFocusNode.context == null) return false;
    if (activeTab >= 0 && activeTab < _railLabelKeys.length) {
      final ctx = _railLabelKeys[activeTab].currentContext;
      if (ctx != null) {
        final node = Focus.maybeOf(ctx);
        if (node != null && node.canRequestFocus) {
          node.requestFocus();
          return true;
        }
      }
    }
    final nodes = _railFocusNode.traversalDescendants
        .where((n) => n.canRequestFocus && !n.skipTraversal)
        .toList();
    if (nodes.isNotEmpty) {
      nodes[activeTab.clamp(0, nodes.length - 1)].requestFocus();
      return true;
    }
    return false;
  }

  bool _focusRightPaneFirst() {
    if (_rightPaneFocusNode.context == null) return false;
    final candidates = _rightPaneFocusNode.traversalDescendants
        .where(
          (n) =>
              n.canRequestFocus &&
              !n.skipTraversal &&
              n.context != null &&
              n.rect.width > 0 &&
              n.rect.height > 0,
        )
        .toList();
    if (candidates.isEmpty) return false;
    final paneBox = _rightPaneFocusNode.context?.findRenderObject() as RenderBox?;
    final paneTop = paneBox?.localToGlobal(Offset.zero).dy ?? 0.0;
    int compareVisualOrder(FocusNode a, FocusNode b) {
      final dyDiff = a.rect.top - b.rect.top;
      if (dyDiff.abs() > 8.0) return dyDiff.compareTo(0.0);
      return a.rect.left.compareTo(b.rect.left);
    }

    final bodyCandidates = [
      for (final n in candidates)
        if (n.rect.top >= paneTop + 56.0) n,
    ]..sort(compareVisualOrder);
    if (bodyCandidates.isNotEmpty) {
      bodyCandidates.first.requestFocus();
      return true;
    }
    candidates.sort(compareVisualOrder);
    candidates.first.requestFocus();
    return true;
  }

  Future<void> _confirmExit() async {
    if (_exitDialogOpen || !mounted) return;
    _exitDialogOpen = true;
    bool? shouldExit;
    try {
      shouldExit = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('アプリを終了しますか？'),
          content: const Text('再生や操作を終了してホーム画面に戻ります。'),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('終了する'),
            ),
          ],
        ),
      );
      if (shouldExit == true) {
        await SystemNavigator.pop();
      }
    } finally {
      _exitDialogOpen = false;
    }
    if (shouldExit != true &&
        mounted &&
        _railFocusNode.context != null &&
        !_railFocusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _railFocusNode.hasFocus) return;
        _focusSelectedRailDestination(ref.read(tabIndexProvider));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(tabIndexProvider);
    _mountedTabs.add(tab);
    final uiMode = ref.watch(uiControlModeProvider);
    final showTailscaleButton =
        ref.watch(tailscaleInstalledProvider).value ?? false;
    ref.listen<AsyncValue<List<RegisteredNasne>>>(
      registrationsProvider,
      (prev, next) => _restoreInitialRailFocusIfNeeded(),
    );
    ref.listen<RegisteredNasne?>(
      selectedRegistrationProvider,
      (prev, next) => _restoreInitialRailFocusIfNeeded(),
    );
    final screens = const [
      HomeScreen(),
      LiveScreen(),
      SchedulesScreen(),
      TitlesScreen(),
      EpgScreen(),
      SettingsScreen(),
    ];
    void select(int index) {
      if (index == _initialTab) {
        _userMovedIntoInitialPane = true;
      }
      ref.read(tabIndexProvider.notifier).select(index);
      if (uiMode.isTv) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _focusRightPaneFirst();
        });
      }
    }

    final touchTabInterceptsBack =
        uiMode.isTouch &&
        tab == AppTabs.titles &&
        ref.watch(touchBackInterceptProvider);
    return PopScope(
      canPop: !uiMode.isTv && !touchTabInterceptsBack,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || _exitDialogOpen) return;
        final activeTab = ref.read(tabIndexProvider);
        final handler = ref.read(tabBackHandlersProvider)[activeTab];
        if (handler != null && handler()) return;
        if (!uiMode.isTv) return;
        if (!_railFocusNode.hasFocus &&
            _focusSelectedRailDestination(activeTab)) {
          return;
        }
        unawaited(_confirmExit());
      },
      child: TailscaleGuard(
        child: _ShellStartupPrefetcher(
          initialTab: _initialTab,
          child: LayoutBuilder(
          builder: (context, constraints) {
            final body = IndexedStack(
              index: tab,
              children: [
                for (var i = 0; i < screens.length; i++)
                  ExcludeFocus(
                    excluding: i != tab,
                    child: _mountedTabs.contains(i)
                        ? screens[i]
                        : const SizedBox.shrink(),
                  ),
              ],
            );
            if (constraints.maxWidth >= railBreakpoint) {
              if (uiMode.isTv &&
                  tab == _initialTab &&
                  !_userMovedIntoInitialPane &&
                  !_railFocusNode.hasFocus) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  if (ref.read(tabIndexProvider) == _initialTab &&
                      !_userMovedIntoInitialPane &&
                      _railFocusNode.context != null &&
                      !_railFocusNode.hasFocus &&
                      ModalRoute.of(context)?.isCurrent == true) {
                    _focusSelectedRailDestination(_initialTab);
                  }
                });
              }
            final reportedTopInset = MediaQuery.paddingOf(context).top;
            final extraTop = wideLayoutMinTopInset > reportedTopInset
                ? wideLayoutMinTopInset - reportedTopInset
                : 0.0;
            return Scaffold(
              body: Padding(
                padding: EdgeInsets.only(top: extraTop),
                child: FocusTraversalGroup(
                  policy: OrderedTraversalPolicy(),
                  child: Row(
                    children: [
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(0),
                        child: FocusTraversalGroup(
                          policy: ReadingOrderTraversalPolicy(),
                          child: Focus(
                            focusNode: _railFocusNode,
                            canRequestFocus: false,
                            skipTraversal: true,
                            onKeyEvent: (node, event) {
                              if ((event is KeyDownEvent ||
                                      event is KeyRepeatEvent) &&
                                  event.logicalKey ==
                                      LogicalKeyboardKey.arrowRight &&
                                  ref.read(tabIndexProvider) == _initialTab) {
                                _userMovedIntoInitialPane = true;
                              }
                              return KeyEventResult.ignored;
                            },
                            child: NavigationRail(
                              selectedIndex: tab,
                              onDestinationSelected: select,
                              labelType: NavigationRailLabelType.all,
                              destinations: [
                                for (int i = 0; i < _destinations.length; i++)
                                  NavigationRailDestination(
                                    icon: Icon(_destinations[i].icon),
                                    selectedIcon: Icon(
                                      _destinations[i].selectedIcon,
                                    ),
                                    label: Text(
                                      _destinations[i].label,
                                      key: _railLabelKeys[i],
                                    ),
                                  ),
                              ],
                              trailing: showTailscaleButton
                                  ? Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: IconButton(
                                        tooltip: 'Tailscale を開く',
                                        icon: const Icon(Icons.vpn_lock),
                                        onPressed: () async {
                                          ref
                                              .read(
                                                tailscaleManualLaunchSignalProvider
                                                    .notifier,
                                              )
                                              .notifyLaunched();
                                          final ok = await ref
                                              .read(fireTvHelperProvider)
                                              .launchTailscale();
                                          if (!ok && context.mounted) {
                                            ScaffoldMessenger.maybeOf(
                                              context,
                                            )?.showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                  'Tailscale アプリが見つかりませんでした',
                                                ),
                                              ),
                                            );
                                          }
                                        },
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                      const VerticalDivider(thickness: 1, width: 1),
                      Expanded(
                        child: FocusTraversalOrder(
                          order: const NumericFocusOrder(1),
                          child: FocusTraversalGroup(
                            policy: ReadingOrderTraversalPolicy(),
                            child: Focus(
                              focusNode: _rightPaneFocusNode,
                              canRequestFocus: false,
                              skipTraversal: true,
                              onKeyEvent: _handleRightPaneKeyEvent,
                              child: Listener(
                                behavior: HitTestBehavior.translucent,
                                onPointerDown: (_) {
                                  if (ref.read(tabIndexProvider) ==
                                      _initialTab) {
                                    _userMovedIntoInitialPane = true;
                                  }
                                },
                                child: body,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          return Scaffold(
            body: body,
            bottomNavigationBar: NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: select,
              destinations: [
                for (final d in _destinations)
                  NavigationDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: d.label,
                  ),
              ],
            ),
          );
        },
        ),
        ),
      ),
    );
  }
}

/// Runs sequential background data prefetching once the startup tab has settled
/// (and after [TailscaleGuard] releases), skipping UI mounting and thumbnails so
/// navigation stays responsive without starving sockets.
class _ShellStartupPrefetcher extends ConsumerStatefulWidget {
  const _ShellStartupPrefetcher({
    required this.initialTab,
    required this.child,
  });

  final int initialTab;
  final Widget child;
  static const Duration _initialTabWaitCap = Duration(seconds: 3);
  static const Duration _startDelay = Duration(milliseconds: 300);
  static const Duration _betweenTabDelay = Duration(milliseconds: 50);

  @override
  ConsumerState<_ShellStartupPrefetcher> createState() =>
      _ShellStartupPrefetcherState();
}

class _ShellStartupPrefetcherState
    extends ConsumerState<_ShellStartupPrefetcher> {
  static const List<int> _prefetchOrder = [
    AppTabs.live,
    AppTabs.schedules,
    AppTabs.epg,
    AppTabs.titles,
    AppTabs.home,
  ];

  bool _disposed = false;
  String? _startedForKey;
  int _runGeneration = 0;
  final Set<Timer> _activeTimers = <Timer>{};
  final Set<Completer<void>> _pendingVoidCompleters = <Completer<void>>{};
  final Set<Completer<bool>> _pendingBoolCompleters = <Completer<bool>>{};
  final Set<ProviderSubscription<dynamic>> _activeSubscriptions =
      <ProviderSubscription<dynamic>>{};

  @override
  void dispose() {
    _disposed = true;
    _runGeneration++;
    for (final timer in _activeTimers.toList()) {
      timer.cancel();
    }
    _activeTimers.clear();
    for (final sub in _activeSubscriptions.toList()) {
      sub.close();
    }
    _activeSubscriptions.clear();
    for (final c in _pendingVoidCompleters.toList()) {
      if (!c.isCompleted) c.complete();
    }
    _pendingVoidCompleters.clear();
    for (final c in _pendingBoolCompleters.toList()) {
      if (!c.isCompleted) c.complete(false);
    }
    _pendingBoolCompleters.clear();
    super.dispose();
  }

  bool _shouldStop(int gen) {
    if (_disposed || !mounted || gen != _runGeneration) return true;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return true;
    return false;
  }

  Future<bool> _delay(Duration duration, int gen) async {
    if (_shouldStop(gen)) return false;
    if (duration <= Duration.zero) return true;
    final completer = Completer<void>();
    _pendingVoidCompleters.add(completer);
    late final Timer timer;
    timer = Timer(duration, () {
      _activeTimers.remove(timer);
      if (!completer.isCompleted) completer.complete();
    });
    _activeTimers.add(timer);
    try {
      await completer.future;
    } finally {
      _pendingVoidCompleters.remove(completer);
    }
    return !_shouldStop(gen);
  }

  Future<bool> _waitInitialWithCap(
    Future<void> future,
    Duration cap,
    int gen,
  ) async {
    if (_shouldStop(gen)) return false;
    final gate = Completer<bool>();
    _pendingBoolCompleters.add(gate);
    late final Timer timer;
    timer = Timer(cap, () {
      _activeTimers.remove(timer);
      if (!gate.isCompleted) gate.complete(true);
    });
    _activeTimers.add(timer);
    future.then(
      (_) {
        timer.cancel();
        _activeTimers.remove(timer);
        if (!gate.isCompleted) gate.complete(true);
      },
      onError: (_, _) {
        timer.cancel();
        _activeTimers.remove(timer);
        if (!gate.isCompleted) gate.complete(false);
      },
    );
    try {
      final ok = await gate.future;
      return ok && !_shouldStop(gen);
    } finally {
      _pendingBoolCompleters.remove(gate);
    }
  }

  Future<void> _awaitTitles(
    RegisteredNasne reg, {
    required bool waitForComplete,
  }) async {
    if (_disposed || !mounted) return;
    final completer = Completer<void>();
    _pendingVoidCompleters.add(completer);
    late final ProviderSubscription<AsyncValue<TitleListProgress>> sub;
    sub = ref.listenManual<AsyncValue<TitleListProgress>>(
      titlesProvider(reg),
      (_, next) {
        if (completer.isCompleted) return;
        if (next.hasError) {
          completer.completeError(next.error!, next.stackTrace);
          return;
        }
        final value = next.value;
        if (value != null && (!waitForComplete || value.complete)) {
          completer.complete();
        }
      },
      fireImmediately: true,
    );
    _activeSubscriptions.add(sub);
    try {
      await completer.future;
    } finally {
      _activeSubscriptions.remove(sub);
      sub.close();
      _pendingVoidCompleters.remove(completer);
    }
  }

  Future<bool> _waitForInitialTab(
    RegisteredNasne selected,
    int gen,
  ) async {
    final Future<void>? primaryFuture = switch (widget.initialTab) {
      AppTabs.home => ref.read(deviceInfoProvider(selected).future).then((_) {}),
      AppTabs.live =>
        ref.read(liveChannelsProvider(selected).future).then((_) {}),
      AppTabs.schedules =>
        ref.read(schedulesProvider(selected).future).then((_) {}),
      AppTabs.titles => _awaitTitles(selected, waitForComplete: false),
      AppTabs.epg => ref.read(epgGuideProvider(selected).future).then((_) {}),
      _ => null,
    };
    if (primaryFuture == null) return !_shouldStop(gen);
    return _waitInitialWithCap(
      primaryFuture,
      _ShellStartupPrefetcher._initialTabWaitCap,
      gen,
    );
  }

  Future<void> _prefetchTab(
    int tab,
    List<RegisteredNasne> activeRegs,
    RegisteredNasne selected,
    int gen,
  ) async {
    try {
      switch (tab) {
        case AppTabs.live:
          for (final r in activeRegs) {
            if (_shouldStop(gen)) return;
            await ref.read(liveChannelsProvider(r).future);
            if (_shouldStop(gen)) return;
            await ref.read(schedulesProvider(r).future);
          }
        case AppTabs.schedules:
          for (final r in activeRegs) {
            if (_shouldStop(gen)) return;
            await ref.read(schedulesProvider(r).future);
            if (_shouldStop(gen)) return;
            await ref.read(recNgProvider(r).future);
          }
        case AppTabs.epg:
          if (_shouldStop(gen)) return;
          await ref.read(channelsProvider(selected).future);
          if (_shouldStop(gen)) return;
          await ref.read(epgGuideProvider(selected).future);
          if (_shouldStop(gen)) return;
          await ref.read(channelLogosProvider(selected).future);
        case AppTabs.titles:
          for (final r in activeRegs) {
            if (_shouldStop(gen)) return;
            await ref.read(titleCountsProvider(r).future);
            if (_shouldStop(gen)) return;
            await _awaitTitles(r, waitForComplete: true);
          }
        case AppTabs.home:
          if (_shouldStop(gen)) return;
          await Future.wait([
            ref.read(deviceInfoProvider(selected).future),
            ref.read(hddDetailsProvider(selected).future),
            ref.read(liveStatusProvider(selected).future),
            ref.read(recNgProvider(selected).future),
            ref.read(networkInfoProvider(selected).future),
            ref.read(bcasInfoProvider(selected).future),
          ]);
      }
    } catch (_) {
      // Best-effort prefetch: failures are handled when the user visits the tab.
    }
  }

  Future<void> _runPrefetch(
    List<RegisteredNasne> regs,
    RegisteredNasne selected,
    int gen,
  ) async {
    final activeRegs = regs.length > 1 ? regs : <RegisteredNasne>[selected];
    final initialOk = await _waitForInitialTab(selected, gen);
    if (!initialOk || _shouldStop(gen)) return;
    if (!await _delay(_ShellStartupPrefetcher._startDelay, gen)) return;

    for (final tab in _prefetchOrder) {
      if (tab == widget.initialTab) continue;
      if (_shouldStop(gen)) return;
      await _prefetchTab(tab, activeRegs, selected, gen);
      if (!await _delay(_ShellStartupPrefetcher._betweenTabDelay, gen)) return;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(startupPrefetchEnabledProvider)) {
      final regs =
          ref.watch(registrationsProvider).value ?? const <RegisteredNasne>[];
      final selected = ref.watch(selectedRegistrationProvider);
      if (regs.isNotEmpty && selected != null) {
        final key = '${regs.map((r) => r.host).join('|')}::${selected.host}';
        if (_startedForKey != key) {
          _startedForKey = key;
          final gen = ++_runGeneration;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_shouldStop(gen)) return;
            unawaited(_runPrefetch(regs, selected, gen));
          });
        }
      }
    }
    return widget.child;
  }
}
