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
  bool _userMovedIntoHomePane = false;
  final FocusNode _railFocusNode = FocusNode(debugLabel: 'appShellRail');
  late final List<GlobalKey> _railLabelKeys = List<GlobalKey>.generate(
    _destinations.length,
    (_) => GlobalKey(),
  );

  @override
  void initState() {
    super.initState();
    _railFocusNode.addListener(_handleRailFocusChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_railFocusNode.context != null && !_railFocusNode.hasFocus) {
        _focusSelectedRailDestination(ref.read(tabIndexProvider));
      }
    });
  }

  @override
  void dispose() {
    _railFocusNode.removeListener(_handleRailFocusChange);
    _railFocusNode.dispose();
    super.dispose();
  }

  void _handleRailFocusChange() {
    if (_railFocusNode.hasFocus) {
      _userMovedIntoHomePane = false;
    }
  }

  void _restoreHomeRailFocusIfNeeded() {
    if (ref.read(tabIndexProvider) != AppTabs.home || _userMovedIntoHomePane) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(tabIndexProvider) != AppTabs.home ||
          _userMovedIntoHomePane) {
        return;
      }
      if (_railFocusNode.context != null && !_railFocusNode.hasFocus) {
        _focusSelectedRailDestination(AppTabs.home);
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
    ref.listen<AsyncValue<List<RegisteredNasne>>>(
      registrationsProvider,
      (prev, next) => _restoreHomeRailFocusIfNeeded(),
    );
    ref.listen<RegisteredNasne?>(
      selectedRegistrationProvider,
      (prev, next) => _restoreHomeRailFocusIfNeeded(),
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
      if (index == AppTabs.home) {
        _userMovedIntoHomePane = false;
      }
      ref.read(tabIndexProvider.notifier).select(index);
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || _exitDialogOpen) return;
        final activeTab = ref.read(tabIndexProvider);
        final handler = ref.read(tabBackHandlersProvider)[activeTab];
        if (handler != null && handler()) return;
        if (!_railFocusNode.hasFocus &&
            _focusSelectedRailDestination(activeTab)) {
          return;
        }
        unawaited(_confirmExit());
      },
      child: TailscaleGuard(
        child: LayoutBuilder(
        builder: (context, constraints) {
          final body = IndexedStack(
            index: tab,
            children: [
              for (var i = 0; i < screens.length; i++)
                ExcludeFocus(excluding: i != tab, child: screens[i]),
            ],
          );
          if (constraints.maxWidth >= railBreakpoint) {
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
                                  ref.read(tabIndexProvider) == AppTabs.home) {
                                _userMovedIntoHomePane = true;
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
                              trailing: Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: IconButton(
                                  tooltip: 'Tailscale を開く',
                                  icon: const Icon(Icons.vpn_lock),
                                  onPressed: () async {
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
                              ),
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
                            child: Listener(
                              behavior: HitTestBehavior.translucent,
                              onPointerDown: (_) {
                                if (ref.read(tabIndexProvider) ==
                                    AppTabs.home) {
                                  _userMovedIntoHomePane = true;
                                }
                              },
                              child: body,
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
    );
  }
}
