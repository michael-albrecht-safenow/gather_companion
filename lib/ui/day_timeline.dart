/// One day, drawn as a timeline instead of a list.
///
/// A list of events answers "what is on" but hides "when am I free" — the question you
/// actually ask before blocking time with someone. This widget draws the day to scale:
/// a 15-minute grid with hourly labels, each event a block sized to its length, and
/// double-bookings side by side. The open gaps are the point — a short one stays
/// proportional so a 30-minute slot is judgeable by eye, a long one collapses to a
/// short faded band so a free afternoon costs a label, not half a screen.
///
/// All the arithmetic — windowing, overlap lanes, which gaps collapse — is done in
/// [layoutDay] (`lib/src/day_timeline_layout.dart`); this file only turns its [Band]s
/// into pixels. Both the Plans tab and the colleague sheet feed it the same way, each
/// supplying its own [blockBuilder] for what a block looks like.
library;

import 'package:flutter/material.dart';

import '../src/day_timeline_layout.dart';
import '../theme/gather_theme.dart';

/// Vertical pixels per minute. An hour is ~56px, so a quarter-hour is a comfortable
/// 14px — tight enough that a full day of gaps still fits, loose enough that a 30-minute
/// meeting is a real block and not a sliver.
const double _pxPerMin = 56 / 60;

/// A block never draws shorter than this however brief the event, so a 10-minute hold
/// stays legible and tappable.
const double _minBlockHeight = 26;

/// The least time a block visually occupies, derived from [_minBlockHeight] over
/// [_pxPerMin] (26 / 0.933 ≈ 28 min, rounded up). [layoutDay] uses it to lane-pack so
/// two back-to-back short events land side by side instead of overlapping in one lane —
/// the callers pass it straight through, keeping the layout maths free of pixel units.
const Duration kTimelineMinSlot = Duration(minutes: 28);

/// A collapsed free band's fixed height — enough for its "3h free" label and the fade,
/// regardless of how many hours it actually swallows.
const double _collapsedHeight = 44;

/// The left column that carries the hour labels, shared by every band so the times line
/// up down the day.
const double _gutterWidth = 44;

/// The gap between two side-by-side lanes in a double-booked cluster.
const double _laneGap = 4;

/// Draws one day from the [Band]s [layoutDay] produced, with [allDay] banners above the
/// grid. [blockBuilder] renders the body of one timed or all-day item; this widget owns
/// everything around it — position, height, lane width, the free-time bands.
class DayTimeline extends StatelessWidget {
  const DayTimeline({
    super.key,
    required this.bands,
    required this.allDay,
    required this.blockBuilder,
  });

  final List<Band> bands;
  final List<TimelineItem> allDay;
  final Widget Function(BuildContext context, TimelineItem item) blockBuilder;

  @override
  Widget build(BuildContext context) {
    // A day with nothing on it at all — no timed events, no all-day banners — is the
    // happy answer to "are they free?", so it says so plainly rather than drawing an
    // empty grid.
    if (bands.isEmpty && allDay.isEmpty) return const _FreeAllDay();

    return Padding(
      padding: const EdgeInsets.fromLTRB(kTextGutter, 2, kTextGutter, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in allDay)
            _AllDayBanner(child: blockBuilder(context, item)),
          for (var i = 0; i < bands.length; i++)
            _band(context, bands[i],
                isLeading: i == 0, isTrailing: i == bands.length - 1),
        ],
      ),
    );
  }

  Widget _band(BuildContext context, Band band,
          {required bool isLeading, required bool isTrailing}) =>
      switch (band) {
        BusyBand() => _BusyGrid(band: band, blockBuilder: blockBuilder),
        // A free band can be both first and last on a one-gap day, but that only
        // happens with no busy band at all, which [DayTimeline] draws as "Free for the
        // day" before it ever reaches here — so leading wins the tie harmlessly.
        FreeBand() => _Free(band: band, isLeading: isLeading, isTrailing: isTrailing),
      };
}

/// The grid for one busy cluster: faint quarter-hour lines, hour labels down the gutter,
/// and the events positioned by start and lane. Sized to the cluster's own span, so a
/// 10:00–11:30 run is exactly 1.5 hours tall and the next cluster starts right below.
class _BusyGrid extends StatelessWidget {
  const _BusyGrid({required this.band, required this.blockBuilder});

  final BusyBand band;
  final Widget Function(BuildContext context, TimelineItem item) blockBuilder;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // The grid is at least its own span tall, but never shorter than the lowest block
    // reaches: a brief event floors to [_minBlockHeight], so a lone 15-minute hold would
    // otherwise overflow a 14px band and clip its own title. Take the furthest block
    // bottom so every block fits.
    final span = band.duration.inMinutes * _pxPerMin;
    final lowest = band.items.fold<double>(span, (lo, p) {
      final bottom =
          p.item.start.difference(band.start).inMinutes * _pxPerMin + _blockHeight(p.item);
      return bottom > lo ? bottom : lo;
    });

    return SizedBox(
      height: lowest,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final laneArea = constraints.maxWidth - _gutterWidth;
          final laneWidth = laneArea / band.lanes;
          return Stack(
            children: [
              // Gridlines and hour labels sit behind the blocks.
              Positioned.fill(
                child: CustomPaint(
                  painter: _GridPainter(
                    start: band.start,
                    end: band.end,
                    gutter: _gutterWidth,
                    line: t.border,
                  ),
                ),
              ),
              for (final tick in _hourTicks(band.start, band.end))
                Positioned(
                  left: 0,
                  width: _gutterWidth - 6,
                  // Centred on the hour line, but clamped inside the band so the first
                  // label never pokes up into the free band above nor the last below —
                  // the overlap that read as two times stacked on top of each other.
                  top: (((tick.difference(band.start).inMinutes * _pxPerMin) - 6)
                      .clamp(0.0, (lowest - 13).clamp(0.0, lowest))),
                  child: Text(
                    _hm(tick),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: t.faint,
                      fontSize: 11,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              for (final packed in band.items)
                Positioned(
                  top: (packed.item.start.difference(band.start).inMinutes * _pxPerMin),
                  left: _gutterWidth + packed.column * laneWidth,
                  width: laneWidth - _laneGap,
                  height: _blockHeight(packed.item),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(t.radius),
                    child: blockBuilder(context, packed.item),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  double _blockHeight(TimelineItem item) {
    final raw = item.duration.inMinutes * _pxPerMin;
    return raw < _minBlockHeight ? _minBlockHeight : raw;
  }
}

/// Open time between or before events. A short gap is drawn to scale — a thin rail with
/// the minutes free, so the eye can measure it. A long gap would waste the screen drawn
/// to scale, so it collapses to a fixed height that fades out, labelled with how much
/// time it stands for.
class _Free extends StatelessWidget {
  const _Free({required this.band, required this.isLeading, required this.isTrailing});

  final FreeBand band;
  final bool isLeading;
  final bool isTrailing;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Leading and trailing gaps name the edge they open onto — "free till the first
    // thing", "free after the last" — while a gap between two events just names how
    // long it is, since both its ends are already on screen.
    final label = isLeading
        ? 'Free till ${_hm(band.end)}'
        : isTrailing
            ? 'Free after ${_hm(band.start)}'
            : '${_gapLabel(band.duration)} free';

    if (band.collapsed) {
      return Container(
        height: _collapsedHeight,
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(t.radius),
          // A green wash, the theme's "available" colour, fading top-to-bottom to
          // nothing so a long open stretch reads as "this just keeps going" — and
          // distinct from the brand-blue busy blocks at a glance.
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [t.ok.withValues(alpha: 0.16), t.ok.withValues(alpha: 0.0)],
          ),
        ),
        child: _freeBody(t, label, strong: true),
      );
    }

    // A short proportional gap: its real height, the same green open-lane rail, and the
    // free minutes once there is room to show them.
    final height = band.duration.inMinutes * _pxPerMin;
    return SizedBox(
      height: height,
      child: height >= 18 ? _freeBody(t, height >= 20 ? label : '', strong: false) : null,
    );
  }

  /// The shared innards of a free band: a green rail where the open lane would be,
  /// aligned under the busy grid's blocks, with the label beside it. [strong] brightens
  /// it for the collapsed band, which carries more visual weight than a thin gap.
  Widget _freeBody(GatherTokens t, String label, {required bool strong}) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(width: _gutterWidth),
          Container(
            width: 3,
            margin: const EdgeInsets.symmetric(vertical: 3),
            decoration: BoxDecoration(
              color: t.ok.withValues(alpha: strong ? 0.6 : 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                style: TextStyle(
                  color: t.ok.withValues(alpha: strong ? 1.0 : 0.85),
                  fontSize: strong ? 12 : 11,
                  fontWeight: strong ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      );
}

/// A banner for an all-day event, full width above the grid — it has no hour to sit on
/// and no length to size to, so it does not belong in the lanes.
class _AllDayBanner extends StatelessWidget {
  const _AllDayBanner({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(left: _gutterWidth, bottom: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(t.radius),
        child: child,
      ),
    );
  }
}

/// Shown for a day with nothing on it — the clean "they're free" answer.
class _FreeAllDay extends StatelessWidget {
  const _FreeAllDay();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kTextGutter, 8, kTextGutter, 12),
      child: Row(
        children: [
          Icon(Icons.wb_sunny_outlined, size: 16, color: t.faint),
          const SizedBox(width: 8),
          Text('Free for the day',
              style: TextStyle(color: t.mutedForeground, fontSize: 13)),
        ],
      ),
    );
  }
}

/// Paints the quarter-hour rules behind a busy band: a faint line at every 15 minutes,
/// a touch stronger on the hour, across the lane area only (not the label gutter).
class _GridPainter extends CustomPainter {
  _GridPainter({required this.start, required this.end, required this.gutter, required this.line});

  final DateTime start;
  final DateTime end;
  final double gutter;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    final faint = Paint()
      ..color = line.withValues(alpha: 0.35)
      ..strokeWidth = 0.5;
    final hour = Paint()
      ..color = line.withValues(alpha: 0.7)
      ..strokeWidth = 0.5;

    for (final tick in _quarterTicks(start, end)) {
      final y = tick.difference(start).inMinutes * _pxPerMin;
      canvas.drawLine(
          Offset(gutter, y), Offset(size.width, y), tick.minute == 0 ? hour : faint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.start != start || old.end != end || old.line != line;
}

// ---- time helpers ----------------------------------------------------------

/// Every whole hour from [start] (inclusive if on the hour, else the next one) up to but
/// not including [end] — a label exactly on the band's bottom edge would spill past it
/// into whatever follows, so the closing hour is left unlabelled.
Iterable<DateTime> _hourTicks(DateTime start, DateTime end) sync* {
  var tick = start.minute == 0
      ? start
      : DateTime(start.year, start.month, start.day, start.hour + 1);
  while (tick.isBefore(end)) {
    yield tick;
    tick = tick.add(const Duration(hours: 1));
  }
}

/// Every 15-minute mark from the first quarter at or after [start] to [end].
Iterable<DateTime> _quarterTicks(DateTime start, DateTime end) sync* {
  final rem = start.minute % 15;
  var tick = rem == 0
      ? start
      : start.add(Duration(minutes: 15 - rem)).copyWithSeconds0();
  while (!tick.isAfter(end)) {
    yield tick;
    tick = tick.add(const Duration(minutes: 15));
  }
}

String _hm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// A loose "2h 30m" / "45m" for a free gap's label.
String _gapLabel(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}

extension on DateTime {
  /// Drops any seconds the quarter-tick rounding left on, so lines land on clean marks.
  DateTime copyWithSeconds0() => DateTime(year, month, day, hour, minute);
}
