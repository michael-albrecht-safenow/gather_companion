/// The maths behind the Plans timeline, with no Flutter in sight.
///
/// The Plans tab and the colleague-peek sheet both want to show a day not as a list
/// but as a *shape*: when someone is busy, and — the part a list cannot show — when
/// they are free. That shape is all arithmetic on start/end instants: which events
/// overlap, how they stack into side-by-side lanes, and where the open gaps fall. None
/// of it needs a widget, so none of it lives in one. [DayTimeline] (in `lib/ui`) only
/// turns the [Band]s this file emits into pixels.
///
/// Keeping it here buys two things: the overlap/lane/gap logic is unit-tested without
/// pumping a widget, and the same output drives both views unchanged.
library;

/// One thing on a single day's timeline, reduced to the four facts layout needs: when
/// it runs, whether it is an all-day banner (which never enters the grid), and an
/// opaque [key] the caller maps back to its own event to build the block.
///
/// [start]/[end] are assumed already clipped to the day being laid out — an event that
/// crosses midnight is the caller's to split, since only it knows which day is being
/// drawn. A zero-length item (start == end) is legal; the widget gives it a floor
/// height so it stays visible.
class TimelineItem {
  const TimelineItem({
    required this.start,
    required this.end,
    required this.key,
    this.allDay = false,
  });

  final DateTime start;
  final DateTime end;
  final Object key;
  final bool allDay;

  Duration get duration => end.difference(start);
}

/// One vertical slice of the rendered day, in order top to bottom. The day is exactly a
/// run of these: busy clusters with gaps ([FreeBand]s) between and around them. There
/// is no fixed 24-hour axis — a leading gap runs from the day's start to the first
/// event and a trailing gap from the last event to the day's end (each collapsed when
/// long, so an empty morning or evening costs a label not a screen).
sealed class Band {
  const Band(this.start, this.end);

  final DateTime start;
  final DateTime end;

  Duration get duration => end.difference(start);
}

/// A contiguous cluster of timed items — everything whose busy spans chain together
/// without a real gap — already packed into side-by-side lanes. Drawn as a grid sized
/// to [duration], with each [PackedItem] positioned by its own start and lane.
class BusyBand extends Band {
  const BusyBand(super.start, super.end, this.items);

  final List<PackedItem> items;

  /// The widest the cluster gets — how many lanes the grid must divide into. Every item
  /// already carries this as [PackedItem.columnCount]; surfaced here so the widget can
  /// size the grid without walking the items.
  int get lanes =>
      items.isEmpty ? 1 : items.map((i) => i.columnCount).reduce((a, b) => a > b ? a : b);
}

/// Open time: the space before the first event, after the last, or between two
/// clusters. [collapsed] marks a gap long enough that drawing it to scale would just be
/// wasted screen — the widget renders those short and faded with a "3h free" label,
/// while a short gap stays proportional so a bookable slot is judgeable by eye.
class FreeBand extends Band {
  const FreeBand(super.start, super.end, {required this.collapsed});

  final bool collapsed;
}

/// A timed item placed in a lane: [column] is its 0-based lane and [columnCount] is how
/// many lanes its overlap run needs, so the widget draws it at `column/columnCount`
/// across the grid width. A lone event is `column 0 of 1` — full width.
class PackedItem {
  const PackedItem({required this.item, required this.column, required this.columnCount});

  final TimelineItem item;
  final int column;
  final int columnCount;
}

/// Turn one day's timed items into the band sequence the timeline draws.
///
/// All-day items must be filtered out by the caller first — they have no position and
/// render as banners above the grid, so passing them here would distort the window.
///
/// Items whose busy spans touch or overlap (within [joinTolerance] — 0 means only a
/// real overlap or exact back-to-back joins) collapse into one [BusyBand], lane-packed
/// by [packLanes]. The space between clusters, the leading gap from the day's start to
/// the first event, and the trailing gap from the last event to the day's end all
/// become [FreeBand]s; one longer than [collapseThreshold] is flagged [collapsed].
///
/// An empty input yields no bands; the widget reads that as "free for the day".
List<Band> layoutDay(
  List<TimelineItem> timed, {
  Duration collapseThreshold = const Duration(minutes: 90),
  Duration joinTolerance = Duration.zero,
  Duration minItemDuration = Duration.zero,
}) {
  final items = [for (final i in timed) if (!i.allDay) i]
    ..sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      if (byStart != 0) return byStart;
      // Longer first on a tie, so the item that spans more sits in lane 0 and the
      // shorter ones stack to its right — reads more naturally than the reverse.
      return b.end.compareTo(a.end);
    });
  if (items.isEmpty) return const [];

  // Cluster by a running "furthest end so far": an item that starts at or before that
  // end (plus tolerance) belongs to the current cluster and may push the end out; one
  // that starts after it opens a new cluster.
  final clusters = <List<TimelineItem>>[];
  var current = <TimelineItem>[items.first];
  var clusterEnd = items.first.end;
  for (final item in items.skip(1)) {
    if (!item.start.isAfter(clusterEnd.add(joinTolerance))) {
      current.add(item);
      if (item.end.isAfter(clusterEnd)) clusterEnd = item.end;
    } else {
      clusters.add(current);
      current = [item];
      clusterEnd = item.end;
    }
  }
  clusters.add(current);

  // Weave bands: a leading free gap before the first cluster, then each cluster, with a
  // free gap inserted wherever two clusters do not touch.
  final bands = <Band>[];
  DateTime? prevEnd;
  for (final cluster in clusters) {
    final start = cluster.first.start;
    final end = cluster.map((i) => i.end).reduce((a, b) => a.isAfter(b) ? a : b);
    if (prevEnd != null && start.isAfter(prevEnd)) {
      bands.add(FreeBand(prevEnd, start,
          collapsed: start.difference(prevEnd) > collapseThreshold));
    }
    bands.add(BusyBand(start, end, packLanes(cluster, minItemDuration: minItemDuration)));
    prevEnd = end;
  }

  // The day is bracketed by its own open time: a leading gap from midnight to the first
  // event, and a trailing gap from the last event to midnight. The leading one reads
  // "Free till HH:MM", the trailing one "Free after HH:MM" — the two answers to "when
  // can I grab them" that a list can never show. Neither is pinned to an event's hour
  // (which would swallow the gap whenever an event sat exactly on the hour); a long
  // bracket simply collapses to a faded band instead of a wall of empty grid, so the
  // day stays compact either way.
  final firstStart = clusters.first.first.start;
  final dayTop = DateTime(firstStart.year, firstStart.month, firstStart.day);
  // Next local calendar midnight, not +24h: on a daylight-saving fall-back day the day
  // is 25h long, so adding a fixed Duration would land at 23:00 and drop the final hour
  // from the trailing band; spring-forward would overshoot into tomorrow. Constructing
  // the next civil date lets DateTime pick the right wall-clock midnight either way.
  final dayEnd = DateTime(firstStart.year, firstStart.month, firstStart.day + 1);
  if (prevEnd != null && prevEnd.isBefore(dayEnd)) {
    bands.add(FreeBand(prevEnd, dayEnd,
        collapsed: dayEnd.difference(prevEnd) > collapseThreshold));
  }
  if (firstStart.isAfter(dayTop)) {
    bands.insert(
        0,
        FreeBand(dayTop, firstStart,
            collapsed: firstStart.difference(dayTop) > collapseThreshold));
  }
  return bands;
}

/// Pack one cluster's items into lanes so overlapping events sit side by side.
///
/// Classic interval-graph colouring: walk the items in start order and drop each into
/// the first lane whose last item has already ended; if none has, open a new lane. The
/// number of lanes alive at once is the cluster's width, and *every* item in the
/// cluster is told that width — so a 3-deep double-booking draws all its blocks at a
/// third width, lined up, rather than each guessing its own.
///
/// [minItemDuration] floors how much vertical room a lane reserves for an item: the
/// widget never draws a block shorter than a fixed pixel minimum, so two back-to-back
/// 15-minute events — which really do not overlap in time — would still collide on
/// screen if stacked in one lane. Treating each item as occupying at least this long
/// pushes such pairs into side-by-side lanes instead, matching what gets drawn. Zero
/// (the default) keeps pure time-overlap packing.
///
/// Expects a non-empty cluster already sorted by start (as [layoutDay] passes it).
List<PackedItem> packLanes(List<TimelineItem> cluster,
    {Duration minItemDuration = Duration.zero}) {
  // laneEnds[i] = when lane i's current occupant visually ends (its real end, or the
  // floored end if that reaches further); a free lane is reusable.
  final laneEnds = <DateTime>[];
  final laneOf = <int>[];
  for (final item in cluster) {
    final itemEnd =
        item.end.isAfter(item.start.add(minItemDuration)) ? item.end : item.start.add(minItemDuration);
    var lane = -1;
    for (var i = 0; i < laneEnds.length; i++) {
      // `!isAfter` so a 10:00–11:00 and an 11:00–12:00 share a lane — back-to-back is
      // not an overlap.
      if (!laneEnds[i].isAfter(item.start)) {
        lane = i;
        break;
      }
    }
    if (lane == -1) {
      lane = laneEnds.length;
      laneEnds.add(itemEnd);
    } else {
      laneEnds[lane] = itemEnd;
    }
    laneOf.add(lane);
  }

  // One cluster shares one width — the most lanes ever live at once. Because the whole
  // cluster is one contiguous busy run, a single count across it keeps the columns
  // aligned top to bottom even when the peak overlap is only in part of it.
  final count = laneEnds.length;
  return [
    for (var i = 0; i < cluster.length; i++)
      PackedItem(item: cluster[i], column: laneOf[i], columnCount: count),
  ];
}
