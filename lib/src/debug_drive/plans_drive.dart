/// `ext.gc.plans.state`: what the Plans tab shows, read off the same decisions the
/// tab draws from (plan task 4.3).
///
/// The Plans timeline exists to make *free* time visible — a clear day reads "Free
/// for the day", the gap between two meetings is a band you can judge by eye — and
/// until the day maths moved into `../plans_timeline.dart` the only way to check it
/// was a screenshot of a scrolled list. This readout runs [splitPlans] and
/// [planDays] — the functions `CalendarScreen` builds from — on [AppState]'s plans
/// and mirrored Google events, so "tomorrow is free", "these two overlap into two
/// lanes" and "the meeting across midnight sits on both days" are JSON assertions.
///
/// It needs no screen: the Plans tab draws from [AppState] alone, so the readout is
/// the same whether the tab is on display or not, and does not pretend otherwise
/// (`screenless: true`). Its "now" is the wall clock, as the live tab's is.
///
/// What it answers:
///
///  * `googleAvailable` / `googleConnected` / `showConnect` — whether this build has
///    a Google client, whether one is connected, and so whether the tab offers the
///    "Connect Google Calendar" banner. With Google not connected there are no
///    mirrored events *because* it is not connected, which is what these say.
///  * `counts`, and `empty` — no entries at all is the tab's "No plans yet".
///  * `upcoming` — every entry not yet ended, by start, each with its `key` (the
///    index the day sections refer to), `source` `plan`|`google`, title, times,
///    `live`, `place`, and for a Google event `canGoToMeeting` (the peek's walk).
///  * `days` — one per section the timeline draws: `date`, `free` (nothing at all
///    on it, timed or all-day — exactly when the timeline draws "Free for the
///    day"; an OOO or holiday banner alone is not free), `noTimed` (no timed entry,
///    whatever the all-day banners say), the `allDay` keys, and the `bands` top to bottom —
///    `busy` (with each item's key, clipped times and lane) or `free` (with
///    `collapsed` for a long gap drawn short). Empty when nothing is upcoming.
///  * `past` — the dimmed EARLIER list, most recent first, at most `pastMax`
///    (default 20), with `pastTruncated`.
///
/// Read-only and not outward. Titles and places are the user's own plans and
/// calendar, shown on this phone's screen already; no credential is touched.
library;

import '../app_state.dart';
import '../day_timeline_layout.dart';
import '../plans_timeline.dart';
import 'debug_drive.dart';
import 'drive_result.dart';

/// `ext.gc.plans.state {pastMax?}`.
DriveFeature plansFeature({
  required AppState Function() app,
  required String Function() boot,
  DateTime Function() clock = DateTime.now,
}) =>
    DriveFeature('plans', [
      DriveAction('state', (args) async {
        final pastMax = args.optionalInt('pastMax', min: 0, max: 200) ?? 20;
        return DriveResult.ok(plansReadout(app(), now: clock(), boot: boot(), pastMax: pastMax));
      }),
    ]);

/// The `plans.state` readout on its own.
Map<String, Object?> plansReadout(AppState state, {required DateTime now, required String boot, int pastMax = 20}) {
  final (:all, :upcoming, :past) = splitPlans(state.plannedMeetings, state.googleEvents, now);
  final days = planDays(upcoming, now);
  return {
    'boot': boot,
    'screenless': true,
    'now': now.toIso8601String(),
    'googleAvailable': state.googleAvailable,
    'googleConnected': state.googleConnected,
    'showConnect': state.googleAvailable && !state.googleConnected,
    'counts': {
      'plans': state.plannedMeetings.length,
      'googleEvents': state.googleEvents.length,
      'upcoming': upcoming.length,
      'past': past.length,
    },
    'empty': all.isEmpty,
    'upcoming': [for (var i = 0; i < upcoming.length; i++) _entry(state, upcoming[i], now, key: i)],
    'days': [for (final d in days) _day(d)],
    'past': [for (final e in past.take(pastMax)) _entry(state, e, now)],
    'pastTruncated': past.length > pastMax,
  };
}

Map<String, Object?> _entry(AppState state, PlanEntry e, DateTime now, {int? key}) => {
      'key': ?key,
      ...switch (e) {
        OwnPlanEntry(:final meeting) => {
            'source': 'plan',
            'id': meeting.id,
            'title': meeting.title,
            'place': (meeting.roomName?.isNotEmpty ?? false) ? meeting.roomName : null,
            'roomStableId': meeting.roomStableId,
            'remindMinutesBefore': meeting.remindMinutesBefore,
          },
        GoogleEntry(:final event) => {
            'source': 'google',
            'id': event.id,
            'title': event.title,
            'place': (event.location?.isNotEmpty ?? false) ? event.location : null,
            'canGoToMeeting': state.canGoToMeeting(event),
          },
      },
      'startsAt': e.startsAt.toIso8601String(),
      'endsAt': e.endsAt.toIso8601String(),
      'allDay': e.allDay,
      'live': e.liveAt(now),
    };

Map<String, Object?> _day(PlanDay d) => {
      'date': '${d.day.year.toString().padLeft(4, '0')}-${d.day.month.toString().padLeft(2, '0')}-'
          '${d.day.day.toString().padLeft(2, '0')}',
      // The same condition `DayTimeline` draws "Free for the day" on
      // (lib/ui/day_timeline.dart): an all-day banner alone is not a free day.
      'free': d.bands.isEmpty && d.allDay.isEmpty,
      'noTimed': d.bands.isEmpty,
      'allDay': [for (final i in d.allDay) i.key],
      'bands': [
        for (final b in d.bands)
          switch (b) {
            BusyBand(:final items) => {
                'kind': 'busy',
                'start': b.start.toIso8601String(),
                'end': b.end.toIso8601String(),
                'lanes': b.lanes,
                'items': [
                  for (final p in items)
                    {
                      'key': p.item.key,
                      'start': p.item.start.toIso8601String(),
                      'end': p.item.end.toIso8601String(),
                      'column': p.column,
                      'columnCount': p.columnCount,
                    },
                ],
              },
            FreeBand(:final collapsed) => {
                'kind': 'free',
                'start': b.start.toIso8601String(),
                'end': b.end.toIso8601String(),
                'minutes': b.duration.inMinutes,
                'collapsed': collapsed,
              },
          },
      ],
    };
