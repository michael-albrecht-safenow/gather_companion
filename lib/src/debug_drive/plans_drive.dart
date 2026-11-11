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
///
/// ## The editor's levers (Phase 5, #108)
///
///  * `plans.list` — the raw records, soonest first, past included: what
///    [AppState.plannedMeetings] holds, with `mirrored` per plan and the mirror
///    setting. `plans.state` is the timeline; this is the store.
///  * `plans.add {title, startsAt, durationMinutes?, roomStableId?,
///    remindMinutesBefore?, id?}` — [AppState.addMeeting], with the record built
///    by [composePlannedMeeting], the function the editor's Save builds from, so
///    the room's label and floor are resolved off the live map exactly as the
///    sheet resolves them. A `roomStableId` the map cannot resolve is
///    `refused('no_such_room')`, not saved as a plan with no place — the sheet's
///    picker can only offer rooms that resolve.
///  * `plans.update {id, …any add field}` — [AppState.updateMeeting] over the
///    stored plan with the given fields replaced; `roomStableId: null` clears the
///    place, as "No place" does. An unknown id is `refused('no_such_plan')`:
///    `updateMeeting` would quietly *add* it, which is not what an edit asked for.
///  * `plans.delete {id}` — [AppState.deleteMeeting]; unknown id refused likewise
///    (`deleteMeeting` answers success for one that is not there).
///  * `plans.google.status` — whether this build has a Google client, whether it
///    is connected, how many events it mirrored, and the shared-calendar *names*
///    the Dial matches colleagues on. No token, no calendar id.
///
/// **Why none of these is outward.** A plan lives in this phone's keychain
/// ([CalendarStore]) and raises a local notification; Gather has no calendar API
/// and the game socket carries no scheduled event, so nobody in the space can see
/// one. The one road out is the device-calendar mirror ([CalendarMirror]): with a
/// mirror calendar chosen, a write lands in a calendar that may sync to a
/// Google/Outlook account colleagues see. This build wires only the no-op mirror
/// and no UI chooses a calendar, so that road is closed today — but should it open,
/// `add`/`update`/`delete` on `boot: "live"` with mirroring on are
/// `refused('calendar_mirror_on', {mirrorCalendarId})` unless the args carry
/// `"confirm": true`, the same consent rule as the registry's outward gate (the
/// test space does not lift it: a calendar is not in a space).
///
/// Args are read strictly: an unknown key (a typo of `startsAt`) is
/// `invalidParams` rather than a plan saved without the field the caller meant.
library;

import '../app_state.dart';
import '../calendar.dart';
import '../day_timeline_layout.dart';
import '../plans_timeline.dart';
import 'debug_drive.dart';
import 'drive_result.dart';

/// `ext.gc.plans.state {pastMax?}` and the editor's levers (see the library doc).
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
      DriveAction('list', (args) async {
        _onlyKeys(args, const {});
        return DriveResult.ok(plansList(app(), boot: boot()));
      }),
      DriveAction('add', (args) async {
        _onlyKeys(args, const {'id', 'title', 'startsAt', 'durationMinutes', 'roomStableId', 'remindMinutesBefore'});
        final state = app();
        final title = _title(args);
        final startsAt = _instant(args, 'startsAt');
        final minutes = args.optionalInt('durationMinutes', min: _minMinutes, max: _maxMinutes) ?? 30;
        final remind = args.optionalInt('remindMinutesBefore', min: 0, max: _maxRemind) ?? 5;
        final roomStableId = _optionalString(args, 'roomStableId');
        final id = _optionalString(args, 'id');
        if (id != null && state.plannedMeetings.any((m) => m.id == id)) {
          return DriveResult.refused('plan_exists', {'id': id});
        }
        final room = resolvePlanRoom(state.plannableRooms, roomStableId);
        if (roomStableId != null && room == null) return _noSuchRoom(state, roomStableId);
        if (_mirrorRefusal(state, boot(), args) case final refused?) return refused;

        final meeting = composePlannedMeeting(
          existing: null,
          newId: id ?? newPlanId(),
          title: title,
          start: startsAt,
          durationMinutes: minutes,
          roomStableId: roomStableId,
          room: room,
          liveFloorId: state.map?.floorId,
          remindMinutes: remind,
        );
        final error = await state.addMeeting(meeting);
        if (error != null) return DriveResult.refused('save_failed', {'message': error});
        return DriveResult.ok(_written(state, boot(), meeting.id));
      }),
      DriveAction('update', (args) async {
        _onlyKeys(args, const {'id', 'title', 'startsAt', 'durationMinutes', 'roomStableId', 'remindMinutesBefore'});
        final state = app();
        final id = args.requireString('id');
        final title = args.containsKey('title') ? _title(args) : null;
        final startsAt = args.containsKey('startsAt') ? _instant(args, 'startsAt') : null;
        final minutes = args.optionalInt('durationMinutes', min: _minMinutes, max: _maxMinutes);
        final remind = args.optionalInt('remindMinutesBefore', min: 0, max: _maxRemind);
        final clearsRoom = args.containsKey('roomStableId') && args['roomStableId'] == null;
        final newRoomId = clearsRoom ? null : _optionalString(args, 'roomStableId');

        final existing = _find(state, id);
        if (existing == null) return DriveResult.refused('no_such_plan', {'id': id});
        final roomStableId = clearsRoom ? null : (newRoomId ?? existing.roomStableId);
        final room = resolvePlanRoom(state.plannableRooms, roomStableId);
        // An id the map cannot resolve is kept only when it is the one already saved
        // (composePlannedMeeting's rule — the map may simply be gone); a new one that
        // does not resolve is a typo.
        if (room == null && roomStableId != null && roomStableId != existing.roomStableId) {
          return _noSuchRoom(state, roomStableId);
        }
        if (_mirrorRefusal(state, boot(), args) case final refused?) return refused;

        final meeting = composePlannedMeeting(
          existing: existing,
          newId: existing.id,
          title: title ?? existing.title,
          start: startsAt ?? existing.startsAt,
          // The plan's own length when not given, unclamped: the editor clamps what
          // it *opens on*, but an edit that did not touch the length must not change it.
          durationMinutes: minutes ?? existing.endsAt.difference(existing.startsAt).inMinutes,
          roomStableId: roomStableId,
          room: room,
          liveFloorId: state.map?.floorId,
          remindMinutes: remind ?? existing.remindMinutesBefore,
        );
        final error = await state.updateMeeting(meeting);
        if (error != null) return DriveResult.refused('save_failed', {'message': error});
        return DriveResult.ok(_written(state, boot(), id));
      }),
      DriveAction('delete', (args) async {
        _onlyKeys(args, const {'id'});
        final state = app();
        final id = args.requireString('id');
        if (_find(state, id) == null) return DriveResult.refused('no_such_plan', {'id': id});
        if (_mirrorRefusal(state, boot(), args) case final refused?) return refused;
        final error = await state.deleteMeeting(id);
        if (error != null) return DriveResult.refused('delete_failed', {'message': error});
        return DriveResult.ok({
          'boot': boot(),
          'deleted': id,
          'count': state.plannedMeetings.length,
        });
      }),
      DriveAction('google.status', (args) async {
        _onlyKeys(args, const {});
        return DriveResult.ok(googleStatus(app(), boot: boot()));
      }),
    ]);

/// The editor's length range (`initialPlanMinutes` clamps to it) and a day's
/// worth of reminder lead.
const _minMinutes = 5;
const _maxMinutes = 480;
const _maxRemind = 1440;

/// Refuses any key outside [allowed] (plus `confirm`, which the gate reads).
void _onlyKeys(Map<String, Object?> args, Set<String> allowed) {
  final unknown = [
    for (final k in args.keys)
      if (k != 'confirm' && !allowed.contains(k)) k,
  ];
  if (unknown.isNotEmpty) {
    throw DriveInvalidParams('unknown field${unknown.length == 1 ? '' : 's'} ${unknown.map((k) => '"$k"').join(', ')}');
  }
}

/// The title, trimmed, non-empty — the editor's "Give the meeting a name."
String _title(Map<String, Object?> args) {
  final value = args['title'];
  if (value is String && value.trim().isNotEmpty) return value.trim();
  throw DriveInvalidParams(value == null ? '"title" is required' : '"title" must be a non-empty string');
}

/// [key] as a non-empty string, or null when absent or JSON null.
String? _optionalString(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value == null) return null;
  if (value is String && value.isNotEmpty) return value;
  throw DriveInvalidParams('"$key" must be a non-empty string');
}

/// `YYYY-MM-DD` then `T` (or a space) and `HH:MM`: a date *and* a time.
final _dateTimeHead = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?');

/// [key] as an ISO-8601 instant, in local time (what the editor's pickers make).
///
/// [DateTime.tryParse] alone is too forgiving to be the check: it rolls an
/// out-of-range field over rather than failing (`2026-02-30T10:00` is March 2nd,
/// `T25:00` is 1 am the next day) and takes a bare date as midnight. Either way a
/// plan would be saved at a moment the caller never named, and answered `ok`. So
/// the date and the time must both be written, and every field must be in range.
DateTime _instant(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value is! String) {
    throw DriveInvalidParams(value == null ? '"$key" is required' : '"$key" must be an ISO-8601 string');
  }
  final parsed = DateTime.tryParse(value);
  final head = _dateTimeHead.firstMatch(value);
  if (parsed == null || head == null) {
    throw DriveInvalidParams('"$key" is not an ISO-8601 date-time (YYYY-MM-DDTHH:MM…): $value');
  }
  final [y, mo, d, h, mi] = [for (var i = 1; i <= 5; i++) int.parse(head.group(i)!)];
  final s = int.parse(head.group(6) ?? '0');
  final asWritten = DateTime.utc(y, mo, d, h, mi, s);
  if (asWritten.month != mo || asWritten.day != d || h > 23 || mi > 59 || s > 59) {
    throw DriveInvalidParams('"$key" has a field out of range: $value');
  }
  return parsed.toLocal();
}

PlannedMeeting? _find(AppState state, String id) {
  for (final m in state.plannedMeetings) {
    if (m.id == id) return m;
  }
  return null;
}

DriveResult _noSuchRoom(AppState state, String stableId) => DriveResult.refused('no_such_room', {
      'roomStableId': stableId,
      // Why it did not resolve: no floor plan yet reads differently from a typo.
      'mapLoaded': state.map != null,
      'rooms': [
        for (final r in state.plannableRooms)
          if (r.stableId != null) {'stableId': r.stableId, 'name': r.name},
      ],
    });

/// The one road a plan has off this phone; see the library doc.
DriveResult? _mirrorRefusal(AppState state, String boot, Map<String, Object?> args) {
  final calendarId = state.mirrorCalendarId;
  if (calendarId == null || boot != 'live' || args['confirm'] == true) return null;
  return DriveResult.refused('calendar_mirror_on', {'mirrorCalendarId': calendarId});
}

Map<String, Object?> _written(AppState state, String boot, String id) => {
      'boot': boot,
      'plan': _plan(_find(state, id)!),
      'count': state.plannedMeetings.length,
    };

Map<String, Object?> _plan(PlannedMeeting m) => {
      'id': m.id,
      'title': m.title,
      'startsAt': m.startsAt.toIso8601String(),
      'endsAt': m.endsAt.toIso8601String(),
      'durationMinutes': m.endsAt.difference(m.startsAt).inMinutes,
      'roomStableId': m.roomStableId,
      'roomName': m.roomName,
      'floorId': m.floorId,
      'x': m.x,
      'y': m.y,
      'remindMinutesBefore': m.remindMinutesBefore,
      'mirrored': m.deviceEventId != null,
      'past': m.isPast,
    };

/// The `plans.list` readout on its own.
Map<String, Object?> plansList(AppState state, {required String boot}) {
  final plans = state.plannedMeetings;
  return {
    'boot': boot,
    'count': plans.length,
    // Says *why* nothing is mirrored: off, rather than "mirrored nowhere".
    'mirrorCalendarId': state.mirrorCalendarId,
    'mirroring': state.mirrorCalendarId != null,
    'plans': [for (final m in plans) _plan(m)],
  };
}

/// The `plans.google.status` readout on its own. No token, no calendar id.
Map<String, Object?> googleStatus(AppState state, {required String boot}) => {
      'boot': boot,
      'available': state.googleAvailable,
      'connected': state.googleConnected,
      'showConnect': state.googleAvailable && !state.googleConnected,
      // With `connected` false this is 0 *because* nothing is connected.
      'events': state.googleEvents.length,
      'sharedCalendars': state.sharedCalendarNames,
    };

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
