/// The three places the app is, and the rail that moves between them.
///
/// Before this there was no navigation: the whole paired app was the feed, and
/// everything else hung off icons crammed into its header — a map button, a
/// refresh button, and an overflow menu holding the device check and unpairing.
/// The map was the thing worth opening the app for and it was the thing hidden
/// behind an unlabelled glyph.
///
/// ## Why the office is kept alive rather than rebuilt
///
/// The obvious shape — swap the body when the tab changes — is wrong here, and
/// expensively so. `MapScreen` owns an `ArtCache` holding 573 decoded images for
/// the reference space, a `TransformationController` holding where you have
/// panned to, and a `_placed` flag that fires the "centre on me at 3×" opening
/// shot exactly once. Destroying that subtree on every tab switch re-decodes the
/// floor from disk and yanks the view back to the opening shot, which makes the
/// rail feel like it is reloading the office rather than returning to it. So all
/// three tabs live in an `IndexedStack` and keep their state.
///
/// That has two costs, and both are paid here rather than left to leak:
///
///  * **Tickers keep running when nothing is on screen.** `MapMotion` drives the
///    walk at 60fps and does not know it is behind another tab. Each tab is
///    wrapped in a `TickerMode` so the ones you are not looking at are muted.
///  * **`AppState.positions` ticks at 4Hz.** That listenable exists precisely so
///    that footsteps repaint the map without waking the rest of the tree, so
///    merging it in unconditionally would hand the map four rebuilds a second
///    while you are reading settings. It is merged in only while the map is the
///    selected tab.
///
/// ## Why the rail floats
///
/// The map body is deliberately not wrapped in a `SafeArea` — the floor runs
/// under the home indicator, because that is what fullscreen has to mean for
/// something you pan around. A docked bar would cut a strip off the bottom of
/// the office to sit in. Instead the rail is an island over the floor, and the
/// shell adds its height to the bottom of every tab's `MediaQuery` padding. Each
/// tab's existing `SafeArea(top: false)` then clears the rail without knowing
/// that a rail exists — which is why `map_screen.dart` needed no changes at all
/// for its D-pad and legend to lift above it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/app_state.dart';
import '../theme/gather_theme.dart';
import 'activity_screen.dart';
import 'control_bar.dart';
import 'gameboy_shell.dart';
import 'map_screen.dart';
import 'settings_screen.dart';

/// Declaration order is rail order, left to right.
///
/// It is also `IndexedStack` order, but nothing here relies on somebody
/// remembering that: both the rail and the stack are built by walking
/// [_Tab.values], so the two cannot fall out of step. They were hand-written as
/// parallel lists once, and reordering the enum without reordering the children
/// silently swapped two tabs' bodies — the rail said Activity and the office
/// appeared. Adding a destination is a case in [_TabView.icon], [_TabView.label]
/// and `_bodyFor`, which the compiler will demand.
enum _Tab { activity, map, settings }

extension _TabView on _Tab {
  IconData get icon => switch (this) {
        _Tab.activity => Icons.notifications_rounded,
        _Tab.map => Icons.map_outlined,
        _Tab.settings => Icons.settings_rounded,
      };

  String get label => switch (this) {
        _Tab.activity => 'Activity',
        _Tab.map => 'Office',
        _Tab.settings => 'Settings',
      };
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.state, required this.onUnpair});

  final AppState state;
  final VoidCallback onUnpair;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  /// Activity opens first: it is the leftmost destination, and it is the one
  /// screen that can have something waiting on it — "did I miss anything" is
  /// what somebody unlocking their phone is usually asking.
  ///
  /// The office being one tap away costs it nothing. No tab is rebuilt when you
  /// leave it, so it is already drawn, already panned where you left it, and its
  /// artwork is still decoded.
  _Tab _tab = _Tab.activity;

  /// Built once and held. A fresh `Listenable.merge` on every build would hand
  /// the map's `ListenableBuilder` a new object each frame and make it
  /// unsubscribe and resubscribe on every socket notification.
  late final Listenable _mapTick = Listenable.merge([widget.state, widget.state.positions]);

  void _select(_Tab tab) {
    if (tab == _tab) return;
    HapticFeedback.selectionClick();
    setState(() => _tab = tab);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final mq = MediaQuery.of(context);
    // The handheld owns the whole office tab, controls and all, so the floating
    // dock stands down while it is on screen — its mute, its rail and its
    // reactions have moved onto the body.
    final gameboyMap = widget.state.gameboyMode && _tab == _Tab.map;

    return Scaffold(
      backgroundColor: t.background,
      // The keyboard never resizes the shell. Nothing in a tab takes text — the one
      // field reachable from here is the status sheet, which lifts itself — and a
      // resize shrank the office's viewport under the sheet, rescaling the floor
      // mid-animation and leaving the strip behind the keyboard black.
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          MediaQuery(
            data: mq.copyWith(
              // The rail's strip is reserved only while the dock is up. In Gameboy
              // mode it stands down (see the `if (!gameboyMap)` below), so the
              // handheld shell wants the whole height rather than a dock's worth
              // of dead plastic under it.
              padding: mq.padding.copyWith(bottom: mq.padding.bottom + (gameboyMap ? 0 : kRailInset)),
              // And see `resizeToAvoidBottomInset`: a tab's own `Scaffold` would
              // otherwise do the resize this one just declined to.
              viewInsets: mq.viewInsets.copyWith(bottom: 0),
            ),
            child: IndexedStack(
              index: _tab.index,
              // Walked rather than listed, so `index` always names the body the
              // rail says it does.
              children: [
                for (final tab in _Tab.values) _asleepUnless(tab, _bodyFor(tab)),
              ],
            ),
          ),
          if (!gameboyMap)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _Dock(
                state: widget.state,
                // The controls are the office's, so they are up only while it is.
                showingControls: _tab == _Tab.map,
                selected: _tab,
                onSelect: _select,
              ),
            ),
        ],
      ),
    );
  }

  Widget _bodyFor(_Tab tab) => switch (tab) {
        // In Gameboy mode the handheld shell wraps the office and carries the
        // controls itself; the normal dock is hidden (see `build`), so the map
        // body skips the control-bar inset. Otherwise the office alone carries the
        // control bar, so the office alone pays for it: the same inset trick the
        // shell uses for the rail, one layer in, so the D-pad and the legend lift
        // above both islands without either knowing the other is there.
        _Tab.map => widget.state.gameboyMode
            ? GameboyShell(
                state: widget.state,
                onOpenSettings: () => _select(_Tab.settings),
                onOpenActivity: () => _select(_Tab.activity),
                child: ListenableBuilder(
                  listenable: _tab == _Tab.map ? _mapTick : widget.state,
                  builder: (context, _) => MapScreen(state: widget.state),
                ),
              )
            : _Inset(
                bottom: kControlBarInset,
                child: ListenableBuilder(
                  // `state` for the connection and the party; `positions` for
                  // people walking, which the presence tracker deliberately does
                  // not count as a change because no other screen draws it. Only
                  // while the map is what you are looking at — off the tab it would
                  // be four rebuilds a second behind something else.
                  listenable: _tab == _Tab.map ? _mapTick : widget.state,
                  builder: (context, _) => MapScreen(state: widget.state),
                ),
              ),
        _Tab.activity => ActivityScreen(state: widget.state),
        _Tab.settings => SettingsScreen(state: widget.state, onUnpair: widget.onUnpair),
      };

  /// Keeps a tab's state but stops its clocks while it is behind another one.
  Widget _asleepUnless(_Tab tab, Widget child) =>
      TickerMode(enabled: _tab == tab, child: child);
}

/// Adds to a subtree's bottom padding, so its own `SafeArea` clears something it
/// does not know about. The shell does this for the rail; this is the same thing
/// for one tab.
class _Inset extends StatelessWidget {
  const _Inset({required this.bottom, required this.child});

  final double bottom;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(
        padding: mq.padding.copyWith(bottom: mq.padding.bottom + bottom),
      ),
      child: child,
    );
  }
}

/// One island holding both rows: what you can do about yourself, and where you
/// can go.
///
/// These were two separate floating bars for about an hour, and the hour was
/// instructive. Two rounded rectangles stacked with a gap read as two unrelated
/// widgets that happened to land near each other, and the eye kept asking which
/// one it was supposed to be looking at. Attached, with a hairline between them,
/// they read as one control surface with a section that comes and goes — which is
/// what they are.
///
/// The island itself — its one width, its floor of [kRailMinWidth], and the way it
/// closes up over a row that leaves — is [DockIsland], which the call screen uses
/// too. The navigation is exactly as wide as the controls above it because the
/// island stretches every row to its widest.
///
/// The controls cannot live *inside* the map tab, which is where they belong
/// conceptually: an `IndexedStack` stops painting a tab the moment it is not
/// selected, so a row animating out from in there would be switched off
/// mid-gesture rather than seen to leave.
class _Dock extends StatelessWidget {
  const _Dock({
    required this.state,
    required this.showingControls,
    required this.selected,
    required this.onSelect,
  });

  final AppState state;
  final bool showingControls;
  final _Tab selected;
  final ValueChanged<_Tab> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return DockIsland(
      children: [
        if (showingControls)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.border)),
            ),
            child: ListenableBuilder(
              // Outside the `IndexedStack`, so it has no listener of its own —
              // the mute button has to redraw when the call state changes and
              // when a roster moves us in or out of a conversation.
              listenable: state,
              builder: (context, _) => ControlBar(state: state),
            ),
          ),
        SizedBox(
          height: kRailHeight,
          // Equal thirds rather than `spaceEvenly`: three fixed-width plates
          // spread across the widened island floated in it as three loose pills,
          // with the bar's fill showing as dead space around each one. Segments
          // own the width instead.
          child: Padding(
            // The one breathing distance: 6 between a plate and the island's
            // edge, and 6 between neighbouring plates — the gaps below, not
            // per-item padding, so the edges do not end up wider than the seams.
            padding: const EdgeInsets.all(6),
            child: Row(
              children: [
                for (final tab in _Tab.values) ...[
                  if (tab != _Tab.values.first) const SizedBox(width: 6),
                  Expanded(
                    child: _NavItem(tab: tab, selected: selected, onSelect: onSelect),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One destination: an icon with its name under it, on a plate that fills in
/// when it is the one you are on.
///
/// The name is not optional decoration. Bare glyphs at a fixed 60 points were
/// tried first and they floated in the widened bar as three loose pills —
/// unlabelled, they read as ornaments rather than as places to go, and a map
/// glyph does not say "The office" to anybody new. Each item now owns a third
/// of the bar, so the plates meet the width instead of swimming in it.
///
/// The D-pad's rule — pressed is a step of opacity, not a colour — is about a
/// control being *pushed*, and does not apply to a control that is *in a state*.
/// This is the second kind, so it follows the media check's toggles instead and
/// uses the brand for on.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.tab,
    required this.selected,
    required this.onSelect,
  });

  final _Tab tab;
  final _Tab selected;
  final ValueChanged<_Tab> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final on = tab == selected;
    // Concentric with the island: the dock's corner is `t.radius + 10` and the
    // plate sits 6 points inside it, so its corner is the dock's minus that
    // inset. Any other number and the two curves visibly disagree at the
    // corners of the bar.
    final radius = BorderRadius.circular(t.radius + 4);

    return Semantics(
      button: true,
      selected: on,
      label: tab.label,
      child: Tooltip(
        message: tab.label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => onSelect(tab),
            borderRadius: radius,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                // A wash of the accent rather than `t.secondary`. The plain
                // surface was the first try and it all but vanished: `#20242F`
                // against a `t.card` rail is a couple of points of luminance, so
                // "selected" was being carried by the icon's colour alone and the
                // plate read as a smudge. This is the link strip's idiom — a
                // tinted fill of the colour the content already is.
                color: on ? t.brand.withValues(alpha: 0.18) : Colors.transparent,
                borderRadius: radius,
              ),
              // The outer `Semantics` already says the name; without this the
              // visible label would make a screen reader say it twice.
              child: ExcludeSemantics(
                child: TweenAnimationBuilder<Color?>(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  tween: ColorTween(end: on ? t.brand : t.mutedForeground),
                  builder: (context, colour, _) => Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(tab.icon, size: 22, color: colour),
                      const SizedBox(height: 3),
                      Text(
                        tab.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.1,
                          color: colour,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
