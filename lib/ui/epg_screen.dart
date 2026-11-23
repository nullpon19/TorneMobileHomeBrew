/// Programme guide screen (plan 21): the channel x time grid for
/// terrestrial broadcasts, in the official torne layout style —
/// channels as columns, time flowing downwards, one day at a time.
/// Data comes from MetadataService.getProgrammeGuide (the EPGGet
/// dataset behind the MetadataService boundary, plan 12.8); the
/// screen only slices and renders it.
///
/// Plan 86 (plan 85 item 8): the app bar gains a programme
/// search entry point (epg_search_screen), which searches the
/// same held dataset by keyword and genre; its results open
/// the shared event detail dialog ([showEpgEventDetail]).
library;

import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../app/providers.dart';
import '../app/state.dart';
import '../app/bs_epg_providers.dart';
import '../core/core.dart';
import 'app_shell.dart';
import 'epg_genre.dart';
import 'epg_search_screen.dart';
import 'error_messages.dart';
import 'format.dart';
import 'live_screen.dart';
import 'schedule_form.dart';
import 'schedules_screen.dart';
import 'epg_subchannel_visibility.dart';
import 'widgets.dart';

/// Vertical scale of the grid: pixels per broadcast minute.
const double _pxPerMinute = 2.4;
const double _channelWidth = 172;
const double _rulerWidth = 40;
const double _headerHeight = 54;

/// Scroll physics that always settles with the grid aligned to a
/// channel-column boundary. Without it the horizontal scroll can
/// rest a few pixels into a column, leaving the leftmost visible
/// column clipped by the viewport edge (its start-time labels lose
/// their first glyph, plan 22).
class _ChannelSnapPhysics extends ScrollPhysics {
  const _ChannelSnapPhysics({super.parent});

  @override
  _ChannelSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _ChannelSnapPhysics(parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    final double nearest =
        ((position.pixels / _channelWidth).round() * _channelWidth).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    if (velocity.abs() < tolerance.velocity &&
        (position.pixels - nearest).abs() < tolerance.distance) {
      // Already at rest on a boundary: defer to the parent physics,
      // whose simulation is null in this state, so the position goes
      // idle. Returning another spring simulation here would loop
      // forever: BallisticScrollActivity re-enters goBallistic(0) when
      // its simulation completes, so a degenerate start == end spring
      // is recreated endlessly, the position never goes idle, and
      // pointer input to the grid stops being delivered (plan 23).
      return super.createBallisticSimulation(position, velocity);
    }
    if (velocity.abs() < tolerance.velocity) {
      // Slow or finished drag: settle to the nearest boundary.
      return ScrollSpringSimulation(
        spring,
        position.pixels,
        nearest,
        velocity,
        tolerance: tolerance,
      );
    }
    // Fling: continue to the next boundary in the fling direction.
    final double target = velocity > 0
        ? (position.pixels / _channelWidth).ceil() * _channelWidth
        : (position.pixels / _channelWidth).floor() * _channelWidth;
    if (target == position.pixels) {
      return super.createBallisticSimulation(position, velocity);
    }
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
      velocity,
      tolerance: tolerance,
    );
  }
}

/// Scroll behaviour for the programme guide: on top of the
/// default drag devices, a pressed mouse button also drags, so
/// desktop users can pull scrollable parts of this screen
/// around the way touch users swipe them (5ch request,
/// 2026-11-21). Applied only around the guide body of this
/// screen; the rest of the app keeps the standard desktop
/// behaviour. The grid itself is the exception: it overrides
/// this with [_EpgGridScrollBehavior] and takes its drags
/// through [_GuideGridScroll], so that one drag can move both
/// axes at once. Event tiles still take plain clicks: the
/// gesture arena only turns a press into a drag once it moves
/// past the slop, so a click that does not move lands on the
/// tile exactly as before.
class _EpgScrollBehavior extends MaterialScrollBehavior {
  const _EpgScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}

/// Scroll behaviour for the guide grid subtree: no drag devices
/// at all. [_GuideGridScroll] drives both of the grid's scroll
/// positions from one pan recogniser; the scroll views' own
/// drag recognisers must stay out of the gesture arena
/// entirely, or they would lock each drag to a single axis
/// again.
class _EpgGridScrollBehavior extends MaterialScrollBehavior {
  const _EpgGridScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const <PointerDeviceKind>{};
}

/// The guide grid: the horizontal channel scroll view around
/// the vertical day grid, with drags driven by a single pan
/// recogniser instead of the two scroll views' own drag
/// recognisers.
///
/// A horizontal and a vertical drag recogniser in the same
/// gesture arena lock a drag to whichever axis crosses the
/// touch slop first, so a diagonal pull only ever scrolled one
/// way (reported from the Windows build, 2026-11-21: start
/// pulling vertically and only vertical moves, start
/// horizontally and only horizontal moves). Here the grid
/// subtree's [ScrollConfiguration] offers no drag devices (see
/// [_EpgGridScrollBehavior]), and one [PanGestureRecognizer]
/// forwards every update to both scroll positions through the
/// same hold/drag/end hand-off [Scrollable] itself uses — the
/// arrangement the framework's two-dimensional scrolling uses
/// for DiagonalDragBehavior.free. Each position keeps its own
/// physics, so a released fling still settles the channel axis
/// on a column boundary, the time ruler stays in step through
/// the existing controller link, and plain clicks still land
/// on the event tiles: the pan recogniser only claims a press
/// once it moves past the slop.
class _GuideGridScroll extends StatefulWidget {
  const _GuideGridScroll({
    required this.gridController,
    required this.bodyController,
    required this.child,
  });

  /// Horizontal (channel axis) scroll of the grid.
  final ScrollController gridController;

  /// Vertical (time axis) scroll of the day grid.
  final ScrollController bodyController;

  final Widget child;

  @override
  State<_GuideGridScroll> createState() => _GuideGridScrollState();
}

class _GuideGridScrollState extends State<_GuideGridScroll> {
  Drag? _horizontalDrag;
  Drag? _verticalDrag;
  ScrollHoldController? _horizontalHold;
  ScrollHoldController? _verticalHold;

  ScrollPosition? get _horizontalPosition =>
      widget.gridController.hasClients ? widget.gridController.position : null;

  ScrollPosition? get _verticalPosition =>
      widget.bodyController.hasClients ? widget.bodyController.position : null;

  @override
  void dispose() {
    _horizontalHold?.cancel();
    _horizontalDrag?.cancel();
    _verticalHold?.cancel();
    _verticalDrag?.cancel();
    super.dispose();
  }

  void _disposeHorizontalHold() => _horizontalHold = null;

  void _disposeVerticalHold() => _verticalHold = null;

  void _disposeHorizontalDrag() => _horizontalDrag = null;

  void _disposeVerticalDrag() => _verticalDrag = null;

  // The handlers below mirror ScrollableState's touch handlers,
  // once per axis: hold on down, drag on start, and the drag
  // hand-off disposes the hold on its own.
  void _handleDragDown(DragDownDetails details) {
    _horizontalHold = _horizontalPosition?.hold(_disposeHorizontalHold);
    _verticalHold = _verticalPosition?.hold(_disposeVerticalHold);
  }

  void _handleDragStart(DragStartDetails details) {
    final horizontal = _horizontalPosition;
    if (horizontal != null) {
      _horizontalDrag = horizontal.drag(details, _disposeHorizontalDrag);
    }
    if (_horizontalHold != null) _disposeHorizontalHold();
    final vertical = _verticalPosition;
    if (vertical != null) {
      _verticalDrag = vertical.drag(details, _disposeVerticalDrag);
    }
    if (_verticalHold != null) _disposeVerticalHold();
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    // ScrollDragController reads primaryDelta, so each axis
    // gets the pan delta projected onto it, as the framework's
    // two-dimensional scrollable does.
    _horizontalDrag?.update(
      DragUpdateDetails(
        sourceTimeStamp: details.sourceTimeStamp,
        delta: Offset(details.delta.dx, 0.0),
        primaryDelta: details.delta.dx,
        globalPosition: details.globalPosition,
        localPosition: details.localPosition,
      ),
    );
    _verticalDrag?.update(
      DragUpdateDetails(
        sourceTimeStamp: details.sourceTimeStamp,
        delta: Offset(0.0, details.delta.dy),
        primaryDelta: details.delta.dy,
        globalPosition: details.globalPosition,
        localPosition: details.localPosition,
      ),
    );
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond;
    _horizontalDrag?.end(
      DragEndDetails(
        velocity: Velocity(pixelsPerSecond: Offset(velocity.dx, 0.0)),
        primaryVelocity: velocity.dx,
      ),
    );
    _verticalDrag?.end(
      DragEndDetails(
        velocity: Velocity(pixelsPerSecond: Offset(0.0, velocity.dy)),
        primaryVelocity: velocity.dy,
      ),
    );
  }

  void _handleDragCancel() {
    _horizontalHold?.cancel();
    _horizontalDrag?.cancel();
    _verticalHold?.cancel();
    _verticalDrag?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      gestures: <Type, GestureRecognizerFactory>{
        PanGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
              () => PanGestureRecognizer(
                supportedDevices: const <PointerDeviceKind>{
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.stylus,
                  PointerDeviceKind.invertedStylus,
                  PointerDeviceKind.trackpad,
                  PointerDeviceKind.unknown,
                },
              ),
              (PanGestureRecognizer instance) {
                instance
                  ..onDown = _handleDragDown
                  ..onStart = _handleDragStart
                  ..onUpdate = _handleDragUpdate
                  ..onEnd = _handleDragEnd
                  ..onCancel = _handleDragCancel
                  ..dragStartBehavior = DragStartBehavior.start
                  ..velocityTrackerBuilder = ScrollConfiguration.of(context)
                      .velocityTrackerBuilder(context)
                  ..gestureSettings = MediaQuery.maybeGestureSettingsOf(
                    context,
                  );
              },
            ),
      },
      child: ScrollConfiguration(
        behavior: const _EpgGridScrollBehavior(),
        child: SingleChildScrollView(
          controller: widget.gridController,
          scrollDirection: Axis.horizontal,
          physics: const _ChannelSnapPhysics(),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Screen width at or above which the 地デジ/BS selector is placed inline inside
/// the AppBar alongside the Search and Refresh actions.
const double epgInlineBandBreakpoint = 600;

class EpgScreen extends ConsumerStatefulWidget {
  const EpgScreen({super.key});

  @override
  ConsumerState<EpgScreen> createState() => _EpgScreenState();
}

class _EpgScreenState extends ConsumerState<EpgScreen> {
  /// Selected day as a JST calendar date (stored as a UTC-midnight
  /// DateTime of the JST date fields, like format.dart's helpers).
  DateTime? _selectedDay;
  bool _scrolledToNow = false;
  int _selectedBand = terrestrialBroadcastingType;

  final _rulerController = ScrollController();
  final _bodyController = ScrollController();
  final _gridController = ScrollController();
  final FocusNode _topBarFocusNode = FocusNode(debugLabel: 'epgTopBar');
  final FocusNode _gridFocusNode = FocusNode(debugLabel: 'epgGrid');
  late final Map<int, bool Function()> _tabBackHandlers;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _link(_rulerController, _bodyController);
    _link(_bodyController, _rulerController);
    _tabBackHandlers = ref.read(tabBackHandlersProvider);
    _tabBackHandlers[AppTabs.epg] = _handleBackFromGrid;
  }

  void _link(ScrollController from, ScrollController to) {
    from.addListener(() {
      if (_syncing || !to.hasClients) return;
      _syncing = true;
      if ((to.offset - from.offset).abs() > 0.5) to.jumpTo(from.offset);
      _syncing = false;
    });
  }

  @override
  void dispose() {
    if (_tabBackHandlers[AppTabs.epg] == _handleBackFromGrid) {
      _tabBackHandlers.remove(AppTabs.epg);
    }
    _topBarFocusNode.dispose();
    _gridFocusNode.dispose();
    _rulerController.dispose();
    _bodyController.dispose();
    _gridController.dispose();
    super.dispose();
  }

  void _focusTopBar() {
    final targets = _topBarFocusNode.traversalDescendants
        .where((n) => n.canRequestFocus && !n.skipTraversal)
        .toList();
    if (targets.isNotEmpty) {
      targets.first.requestFocus();
    }
  }

  bool _handleBackFromGrid() {
    if (!_gridFocusNode.hasFocus) return false;
    _focusTopBar();
    return true;
  }

  /// The JST calendar date (as UTC fields) containing [instant].
  static DateTime _jstDateOf(DateTime instant) {
    final jst = instant.toUtc().add(const Duration(hours: 9));
    return DateTime.utc(jst.year, jst.month, jst.day);
  }

  /// The instant a JST calendar date starts.
  static DateTime _jstDayStart(DateTime jstDate) =>
      jstDate.subtract(const Duration(hours: 9));

  Widget _buildBandSelector() {
    return SegmentedButton<int>(
      segments: const [
        ButtonSegment<int>(
          value: terrestrialBroadcastingType,
          label: Text('地デジ'),
        ),
        ButtonSegment<int>(value: bsBroadcastingType, label: Text('BS')),
      ],
      selected: {_selectedBand},
      onSelectionChanged: (selection) => setState(() {
        _selectedBand = selection.first;
        _scrolledToNow = false;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reg = ref.watch(selectedRegistrationProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final inlineBand = constraints.maxWidth >= epgInlineBandBreakpoint;
        final showHint = constraints.maxWidth >= 760;
        final actionsRow = reg == null
            ? null
            : Focus(
                focusNode: _topBarFocusNode,
                canRequestFocus: false,
                skipTraversal: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (inlineBand) ...[
                      Center(child: _buildBandSelector()),
                      const SizedBox(width: 8),
                    ],
                    IconButton(
                      icon: const Icon(Icons.search),
                      tooltip: '番組検索',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => EpgSearchScreen(reg: reg),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: '更新',
                      onPressed: () {
                        ref.invalidate(schedulesProvider(reg));
                        if (_selectedBand == terrestrialBroadcastingType) {
                          ref.invalidate(epgGuideProvider(reg));
                          ref.invalidate(channelLogosProvider(reg));
                        } else {
                          ref.invalidate(bsChannelsProvider(reg));
                          ref.invalidate(bsEpgGuideProvider(reg));
                          ref.invalidate(bsChannelLogosProvider(reg));
                        }
                      },
                    ),
                  ],
                ),
              );

        return Scaffold(
          appBar: AppBar(
            title: inlineBand && showHint && reg != null
                ? Row(
                    children: [
                      const Text('番組表'),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          '戻る / メニューで上部へ',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    ],
                  )
                : const Text('番組表'),
            actions: [?actionsRow],
          ),
          body: reg == null
              ? NoDeviceView(
                  onRegister: () => ref
                      .read(tabIndexProvider.notifier)
                      .select(AppTabs.settings),
                )
              : ScrollConfiguration(
                  behavior: const _EpgScrollBehavior(),
                  child: _buildBandGuide(reg, showBandRow: !inlineBand),
                ),
        );
      },
    );
  }

  Widget _buildBandGuide(RegisteredNasne reg, {required bool showBandRow}) {
    final isBs = _selectedBand == bsBroadcastingType;
    final guideAsync = isBs
        ? ref.watch(bsEpgGuideProvider(reg))
        : ref.watch(epgGuideProvider(reg));
    final schedules =
        ref.watch(schedulesProvider(reg)).value ?? const <RecordSchedule>[];
    final logos = isBs
        ? (ref.watch(bsChannelLogosProvider(reg)).value ??
              const <int, List<int>>{})
        : (ref.watch(channelLogosProvider(reg)).value ??
              const <int, List<int>>{});

    return Column(
      children: [
        if (showBandRow)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Focus(
              focusNode: _topBarFocusNode,
              canRequestFocus: false,
              skipTraversal: true,
              child: _buildBandSelector(),
            ),
          ),
        Expanded(
          child: guideAsync.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(
              message: userMessageForError(e),
              onRetry: () {
                if (isBs) {
                  ref.invalidate(bsChannelsProvider(reg));
                  ref.invalidate(bsEpgGuideProvider(reg));
                } else {
                  ref.invalidate(epgGuideProvider(reg));
                }
              },
            ),
            data: (guide) => _GuideView(
              reg: reg,
              guide: guideWithSubchannelSetting(
                guide,
                ref.watch(showSubchannelsProvider),
              ),
              schedules: schedules,
              hiddenGenres: ref.watch(hiddenEpgGenresProvider),
              onWatchEvent: (channel) => openLiveChannelForEpg(
                context,
                ref,
                reg: reg,
                channel: channel,
              ),
              logos: logos,
              selectedDay: _selectedDay,
              onSelectDay: (day) => setState(() {
                _selectedDay = day;
                _scrolledToNow = false;
              }),
              rulerController: _rulerController,
              bodyController: _bodyController,
              gridController: _gridController,
              gridFocusNode: _gridFocusNode,
              onJumpToTopBar: _focusTopBar,
              scrolledToNow: _scrolledToNow,
              onScrolledToNow: () => _scrolledToNow = true,
            ),
          ),
        ),
      ],
    );
  }
}

class _GuideView extends StatelessWidget {
  const _GuideView({
    required this.reg,
    required this.guide,
    required this.schedules,
    required this.hiddenGenres,
    required this.onWatchEvent,
    required this.logos,
    required this.selectedDay,
    required this.onSelectDay,
    required this.rulerController,
    required this.bodyController,
    required this.gridController,
    required this.gridFocusNode,
    required this.onJumpToTopBar,
    required this.scrolledToNow,
    required this.onScrolledToNow,
  });

  final RegisteredNasne reg;
  final EpgGuide guide;
  final List<RecordSchedule> schedules;

  /// Genres the viewer marked as not watched (plan 95):
  /// their tiles paint blank.
  final Set<int> hiddenGenres;

  /// Opens live viewing for a guide channel (plan 95);
  /// offered from the event detail while the event is on air.
  final void Function(Channel channel) onWatchEvent;
  final Map<int, List<int>> logos;
  final DateTime? selectedDay;
  final ValueChanged<DateTime> onSelectDay;
  final ScrollController rulerController;
  final ScrollController bodyController;
  final ScrollController gridController;
  final FocusNode gridFocusNode;
  final VoidCallback onJumpToTopBar;
  final bool scrolledToNow;
  final VoidCallback onScrolledToNow;

  @override
  Widget build(BuildContext context) {
    final from = guide.from;
    final to = guide.to;
    if (from == null || to == null || guide.services.isEmpty) {
      return const Center(child: Text('番組データがありません。'));
    }
    final firstDay = _EpgScreenState._jstDateOf(from);
    final lastDay = _EpgScreenState._jstDateOf(
      to.subtract(const Duration(seconds: 1)),
    );
    final days = <DateTime>[
      for (
        var d = firstDay;
        !d.isAfter(lastDay);
        d = d.add(const Duration(days: 1))
      )
        d,
    ];
    final today = _EpgScreenState._jstDateOf(DateTime.now());
    final day = selectedDay != null && days.contains(selectedDay)
        ? selectedDay!
        : (days.contains(today) ? today : days.first);
    final dayStart = _EpgScreenState._jstDayStart(day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    // Initial position: one hour before "now" when today is shown.
    if (!scrolledToNow && day == today) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (bodyController.hasClients) {
          final now = DateTime.now();
          final minutes = now.difference(dayStart).inMinutes - 60;
          // Clamp to the scrollable range: late in the evening the
          // raw target exceeds the maximum extent, and an out-of-range
          // rest position leaves the grid in a corrected state that
          // does not accept drags cleanly (plan 23).
          final target = math.max(0, minutes * _pxPerMinute).toDouble();
          bodyController.jumpTo(
            math.min(target, bodyController.position.maxScrollExtent),
          );
        }
        onScrolledToNow();
      });
    }

    return Column(
      children: [
        _DaySelector(days: days, selected: day, onSelect: onSelectDay),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _rulerWidth,
                child: Column(
                  children: [
                    const SizedBox(height: _headerHeight),
                    Expanded(child: _TimeRuler(controller: rulerController)),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Focus(
                  focusNode: gridFocusNode,
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent &&
                        (event.logicalKey == LogicalKeyboardKey.contextMenu ||
                            event.logicalKey == LogicalKeyboardKey.info ||
                            event.logicalKey == LogicalKeyboardKey.escape)) {
                      onJumpToTopBar();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: _GuideGridScroll(
                    gridController: gridController,
                    bodyController: bodyController,
                    child: SizedBox(
                      width: _channelWidth * guide.services.length,
                      child: Column(
                        children: [
                          _ChannelHeader(services: guide.services, logos: logos),
                          Expanded(
                            child: _DayGrid(
                              reg: reg,
                              services: guide.services,
                              schedules: schedules,
                              hiddenGenres: hiddenGenres,
                              onWatchEvent: onWatchEvent,
                              dayStart: dayStart,
                              dayEnd: dayEnd,
                              controller: bodyController,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DaySelector extends StatelessWidget {
  const _DaySelector({
    required this.days,
    required this.selected,
    required this.onSelect,
  });

  final List<DateTime> days;
  final DateTime selected;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final today = _EpgScreenState._jstDateOf(DateTime.now());
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        children: [
          for (final day in days)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(
                  day == today
                      ? '今日 ${day.month}/${day.day}'
                      : '${day.month}/${day.day} (${formatWeekdayJst(day.add(const Duration(hours: 9)))})',
                ),
                selected: day == selected,
                onSelected: (_) => onSelect(day),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChannelHeader extends StatelessWidget {
  const _ChannelHeader({required this.services, required this.logos});

  final List<EpgServiceGuide> services;
  final Map<int, List<int>> logos;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: _headerHeight,
      child: Row(
        children: [
          for (final service in services)
            SizedBox(
              width: _channelWidth,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (logos[service.channel.serviceId] != null)
                      SizedBox(
                        height: 24,
                        child: Image.memory(
                          Uint8List.fromList(logos[service.channel.serviceId]!),
                          fit: BoxFit.contain,
                        ),
                      ),
                    Text(
                      service.channel.serviceName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TimeRuler extends StatelessWidget {
  const _TimeRuler({required this.controller});

  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      controller: controller,
      physics: const NeverScrollableScrollPhysics(),
      child: SizedBox(
        height: 24 * 60 * _pxPerMinute,
        child: Stack(
          children: [
            for (var hour = 0; hour < 24; hour++)
              Positioned(
                top: hour * 60 * _pxPerMinute + 2,
                left: 0,
                right: 0,
                child: Text(
                  '$hour',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DayGrid extends StatelessWidget {
  const _DayGrid({
    required this.reg,
    required this.services,
    required this.schedules,
    required this.hiddenGenres,
    required this.onWatchEvent,
    required this.dayStart,
    required this.dayEnd,
    required this.controller,
  });

  final RegisteredNasne reg;
  final List<EpgServiceGuide> services;
  final List<RecordSchedule> schedules;
  final Set<int> hiddenGenres;
  final void Function(Channel channel) onWatchEvent;
  final DateTime dayStart;
  final DateTime dayEnd;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final dayHeight = 24 * 60 * _pxPerMinute;
    final isToday =
        _EpgScreenState._jstDateOf(DateTime.now()) ==
        _EpgScreenState._jstDateOf(dayStart);
    final nowOffset = isToday
        ? DateTime.now().difference(dayStart).inMinutes * _pxPerMinute
        : null;
    return SingleChildScrollView(
      controller: controller,
      child: SizedBox(
        height: dayHeight,
        child: Stack(
          children: [
            // Hour gridlines.
            for (var hour = 0; hour <= 24; hour++)
              Positioned(
                top: hour * 60 * _pxPerMinute,
                left: 0,
                right: 0,
                child: const Divider(height: 1),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < services.length; i++)
                  SizedBox(
                    width: _channelWidth,
                    height: dayHeight,
                    child: Stack(
                      children: [
                        for (final event in services[i].events.where(
                          (e) =>
                              e.end.isAfter(dayStart) &&
                              e.start.isBefore(dayEnd),
                        ))
                          _EventTile(
                            key: ValueKey(
                              '${services[i].channel.serviceId}-${event.eventId}-${event.start}',
                            ),
                            event: event,
                            channel: services[i].channel,
                            channelName: services[i].channel.serviceName,
                            reg: reg,
                            dayStart: dayStart,
                            suppressed: epgGenreSuppressed(
                              event.genreLevel1,
                              hiddenGenres,
                            ),
                            matchedSchedule: findMatchingSchedule(
                              schedules,
                              services[i].channel,
                              event,
                            ),
                            onWatch: () =>
                                onWatchEvent(services[i].channel),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
            if (nowOffset != null && nowOffset >= 0 && nowOffset <= dayHeight)
              Positioned(
                top: nowOffset,
                left: 0,
                right: 0,
                child: Container(height: 2, color: Colors.red),
              ),
          ],
        ),
      ),
    );
  }
}

class _EventTile extends StatefulWidget {
  const _EventTile({
    super.key,
    required this.event,
    required this.channel,
    required this.channelName,
    required this.reg,
    required this.dayStart,
    required this.suppressed,
    this.matchedSchedule,
    required this.onWatch,
  });

  final EpgEvent event;
  final Channel channel;
  final String channelName;
  final RegisteredNasne reg;
  final DateTime dayStart;

  /// The event's genre is one the viewer marked as not
  /// watched (plan 95): the tile paints as a blank of plain
  /// surface colour — no tint, no text — so it does not draw
  /// the eye. The slot and the tap (the detail dialog) stay.
  final bool suppressed;

  /// Existing scheduled recording matching this broadcast event, if any.
  final RecordSchedule? matchedSchedule;

  /// Opens live viewing for this tile's channel (plan 95);
  /// the detail dialog offers it only while the event is on
  /// air.
  final VoidCallback onWatch;

  @override
  State<_EventTile> createState() => _EventTileState();
}

class _EventTileState extends State<_EventTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final event = widget.event;
    final isReserved = widget.matchedSchedule != null;
    final startMin = math.max(
      0,
      event.start.difference(widget.dayStart).inMinutes,
    );
    final endMin = math.min(
      24 * 60,
      event.end.difference(widget.dayStart).inMinutes,
    );
    final top = startMin * _pxPerMinute;
    final height = math.max(10, (endMin - startMin) * _pxPerMinute - 1);
    final title = event.title;
    final timeText = formatTimeJst(event.start);
    final timeStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.bold,
    );
    // Title lines that fit under the time line: the time line is
    // about 16px at the labelSmall size and a title line about
    // 17px, with 2px of vertical padding at each edge.
    final maxTitleLines = ((height - 4 - 16) / 17).floor();
    final focusBorderColor = isDark ? Colors.amberAccent : Colors.black;
    final reservedBorderColor = isDark
        ? Colors.redAccent
        : const Color(0xFFD32F2F);
    final Widget content = widget.suppressed
        ? const SizedBox.expand()
        : maxTitleLines >= 1
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (isReserved) ...[
                      Icon(
                        Icons.fiber_manual_record,
                        size: 10,
                        color: reservedBorderColor,
                      ),
                      const SizedBox(width: 2),
                    ],
                    Expanded(
                      child: Text(
                        timeText,
                        style: timeStyle,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                      ),
                    ),
                  ],
                ),
                if (title != null)
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                      maxLines: maxTitleLines.clamp(1, 4),
                    ),
                  ),
              ],
            ),
          )
        : Padding(
            // Compact form for tiles too short for two lines:
            // time and title share one small line.
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (isReserved) ...[
                  Icon(
                    Icons.fiber_manual_record,
                    size: 9,
                    color: reservedBorderColor,
                  ),
                  const SizedBox(width: 2),
                ],
                Text(
                  timeText,
                  style: timeStyle?.copyWith(fontSize: 10, height: 1.1),
                ),
                if (title != null) ...[
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 10,
                        height: 1.1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          );
    return Positioned(
      top: top,
      left: 1,
      right: 1,
      height: height.toDouble(),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: _focused
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: focusBorderColor, width: 3),
              )
            : isReserved
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: reservedBorderColor, width: 2.5),
              )
            : const BoxDecoration(),
        child: Material(
          // Tiles are tinted by the event's genre (plan 86,
          // plan 85 item 10); events without a known genre
          // keep the neutral colour they have always had.
          // A suppressed genre (plan 95) paints the plain
          // surface instead, with no text below.
          color: widget.suppressed
              ? theme.colorScheme.surface
              : epgGenreTileColor(
                  genreLevel1: event.genreLevel1,
                  surface: theme.colorScheme.surface,
                  fallback: theme.colorScheme.surfaceContainerHighest,
                ),
          borderRadius: BorderRadius.circular(3),
          // Tiles too short for their text must not paint outside
          // their box: spilled glyphs used to bleed into the tile
          // below and get half-covered there (plan 22).
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: BorderRadius.circular(3),
            focusColor: Colors.transparent,
            onFocusChange: (focused) {
              if (_focused != focused) setState(() => _focused = focused);
            },
            onTap: () => showEpgEventDetail(
              context,
              reg: widget.reg,
              channel: widget.channel,
              channelName: widget.channelName,
              event: event,
              existingSchedule: widget.matchedSchedule,
              onWatch: widget.onWatch,
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                content,
                if (_focused && isReserved)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(1),
                            border: Border.all(
                              color: reservedBorderColor,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the programme detail dialog for a guide [event],
/// with the reservation action wired to the prefilled form
/// when the event has not ended yet. Shared by the guide
/// grid's tiles and the programme search results (plan 86),
/// so both paths offer exactly the same detail and the same
/// way into a reservation.
///
/// Reserve from the guide (plan 28): opens the create form
/// prefilled with this event, through the same XSRS create
/// path as a manual reservation. Events that have already
/// ended cannot be reserved.
///
/// Watch from the guide (plan 95): while the event is on air,
/// [onWatch] — wired by the caller to the channel's live
/// viewing — is offered next to the reservation. Before the
/// start and after the end there is nothing of this event to
/// watch (the live stream carries whatever is on air then),
/// so the action is not shown at all.
/// Parses the 4th comma-separated element (EIT `event_id`) from an XSRS
/// `desiredMatchingID` string (e.g. `,,0x7880,0x12ab`). Returns `null` when
/// absent, malformed, or `<= 0` (manual time-based reservations use `0`).
int? parseScheduleEventId(String desiredMatchingId) {
  final parts = desiredMatchingId.split(',');
  if (parts.length < 4) return null;
  final raw = parts[3].trim();
  if (raw.isEmpty) return null;
  final parsed = (raw.startsWith('0x') || raw.startsWith('0X'))
      ? int.tryParse(raw.substring(2), radix: 16)
      : int.tryParse(raw);
  if (parsed == null || parsed <= 0) return null;
  return parsed;
}

/// Finds an active reservation matching [event] on [channel], matching on EIT
/// `eventId` first and falling back to an exact start/end time match for
/// manual reservations (`eventId == 0`).
RecordSchedule? findMatchingSchedule(
  List<RecordSchedule> schedules,
  Channel channel,
  EpgEvent event,
) {
  for (final s in schedules) {
    if (s.channel.broadcastingType != channel.broadcastingType ||
        s.channel.serviceId != channel.serviceId) {
      continue;
    }
    final eid = parseScheduleEventId(s.desiredMatchingId);
    if (eid != null &&
        eid == event.eventId &&
        s.start.difference(event.start).abs() <= const Duration(hours: 6)) {
      return s;
    }
  }
  for (final s in schedules) {
    if (s.channel.broadcastingType != channel.broadcastingType ||
        s.channel.serviceId != channel.serviceId) {
      continue;
    }
    if (parseScheduleEventId(s.desiredMatchingId) != null) continue;
    if (s.start.difference(event.start).abs() <= const Duration(minutes: 2) &&
        s.end.difference(event.end).abs() <= const Duration(minutes: 2)) {
      return s;
    }
  }
  return null;
}

void showEpgEventDetail(
  BuildContext context, {
  required RegisteredNasne reg,
  required Channel channel,
  required String channelName,
  required EpgEvent event,
  RecordSchedule? existingSchedule,
  VoidCallback? onWatch,
}) {
  final now = DateTime.now();
  final watchable =
      onWatch != null && !event.start.isAfter(now) && event.end.isAfter(now);
  showDialog<void>(
    context: context,
    builder: (dialogContext) => EpgEventDetailDialog(
      event: event,
      channelName: channelName,
      onEditSchedule: existingSchedule != null
          ? () {
              Navigator.of(dialogContext).pop();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ScheduleDetailPage(
                    reg: reg,
                    scheduleId: existingSchedule.id,
                  ),
                ),
              );
            }
          : null,
      onReserve: existingSchedule == null && event.end.isAfter(now)
          ? () {
              Navigator.of(dialogContext).pop();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ScheduleFormPage.fromEpg(
                    reg,
                    channel: channel,
                    event: event,
                  ),
                ),
              );
            }
          : null,
      onWatch: watchable
          ? () {
              Navigator.of(dialogContext).pop();
              onWatch();
            }
          : null,
    ),
  );
}

class EpgEventDetailDialog extends StatelessWidget {
  const EpgEventDetailDialog({
    super.key,
    required this.event,
    required this.channelName,
    this.onReserve,
    this.onEditSchedule,
    this.onWatch,
  });

  final EpgEvent event;
  final String channelName;

  /// Opens the prefilled reservation form (plan 28); null when
  /// the event has already ended or is already scheduled.
  final VoidCallback? onReserve;

  /// Opens [ScheduleDetailPage] for an already-reserved programme.
  final VoidCallback? onEditSchedule;

  /// Opens the channel's live viewing (plan 95); null unless
  /// the event is on air now.
  final VoidCallback? onWatch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final genreLabel = epgGenreLabel(event.genreLevel1);
    final reservedColor = theme.brightness == Brightness.dark
        ? Colors.redAccent
        : const Color(0xFFD32F2F);
    return AlertDialog(
      title: Text(event.title ?? '番組情報なし'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(channelName, style: theme.textTheme.bodySmall),
            if (genreLabel != null)
              Text('ジャンル: $genreLabel', style: theme.textTheme.bodySmall),
            Text(
              '${formatDateTimeWithWeekdayJst(event.start)} 〜 '
              '${formatTimeJst(event.end)}'
              '（${event.duration.inMinutes}分）',
              style: theme.textTheme.bodyMedium,
            ),
            if (onEditSchedule != null) ...[
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.fiber_manual_record, size: 12, color: reservedColor),
                  const SizedBox(width: 4),
                  Text(
                    '録画予約済み',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: reservedColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
            if (event.shortText != null && event.shortText!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(event.shortText!),
            ],
            if (event.description != null && event.description!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('番組内容', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(event.description!),
            ],
            if (event.cast != null && event.cast!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('出演者', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(event.cast!),
            ],
            for (final item in event.extendedItems) ...[
              const SizedBox(height: 12),
              Text(item.label, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(item.value),
            ],
            if (event.extendedText != null &&
                event.extendedText!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(event.extendedText!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('閉じる'),
        ),
        if (onWatch != null)
          FilledButton.icon(
            onPressed: onWatch,
            icon: const Icon(Icons.live_tv, size: 18),
            label: const Text('試聴'),
          ),
        if (onEditSchedule != null)
          FilledButton.icon(
            onPressed: onEditSchedule,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('予約を編集'),
          )
        else if (onReserve != null)
          FilledButton.icon(
            onPressed: onReserve,
            icon: const Icon(Icons.fiber_manual_record, size: 18),
            label: const Text('録画予約'),
          ),
      ],
    );
  }
}
