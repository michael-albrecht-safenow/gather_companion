/// `ext.gc.activity.*`: Gather's own activity feed, as the Activity tab reads it
/// and through the same two levers the tab pulls (plan Phase 5, #108).
///
/// The feed is server-side — the same list the desktop client shows — topped by
/// the waves seen on the socket since the last fetch. Whether a wave landed, a
/// refresh replaced the live rows rather than doubling them, or "mark all read"
/// flipped the badge used to be a screenshot of the tab; these make it JSON.
///
///  * `list {max?}` — [AppState.activity] newest first, `unread`
///    ([AppState.unreadActivityCount], the badge), `loading`, `fetched` and the
///    last `error`. An empty list says why: `not_signed_in`, `no_space`,
///    `not_fetched` (the tab's skeleton), `fetch_failed` or `nothing_yet` — only
///    the last is a checked "nothing happened".
///  * `refresh` — an op over [AppState.refreshActivity], the tab's
///    pull-to-refresh. `op.result` is the `list` readout, or
///    `refused('fetch_failed', {error})` when Gather refused.
///  * `markRead {ids: [...]}` or `{all: true}` — an op over
///    [AppState.markActivityRead], the row tap and the "mark all read" button.
///    Items that cannot be marked (the chat-backed kinds) or are already read are
///    reported as `skipped`, as the method skips them; nothing left to mark is
///    `refused('nothing_to_mark')`, an id not in the feed `refused('no_such_item')`.
///    The flip is optimistic; a Gather refusal puts the rows back, which the op
///    answers as `refused('mark_failed', {error})`.
///
/// Both levers are refused up front with [AppState.activityUnavailable]
/// (`not_signed_in`, `no_space`), since the methods themselves return quietly
/// there and a quiet `ok` would claim a fetch that never happened; `refresh` also
/// refuses `already_loading`.
///
/// **Not outward.** `refresh` is a read. `markRead` writes, but only the user's
/// own read cursor — it clears their desktop badge too, which is the point — and
/// nobody else in the space can see it. Messages and meeting titles are the
/// user's own feed, already on this phone's screen; an unknown kind's raw
/// payload is not echoed, only its `kind`.
library;

import 'package:gather_client/gather_client.dart';

import '../app_state.dart';
import 'debug_drive.dart';
import 'drive_ops.dart';
import 'drive_result.dart';

/// `ext.gc.activity.{list, refresh, markRead}`.
DriveFeature activityFeature({
  required AppState Function() app,
  required String Function() boot,
  required DriveOps ops,
}) =>
    DriveFeature('activity', [
      DriveAction('list', (args) async {
        final max = args.optionalInt('max', min: 0, max: 1000) ?? 200;
        return DriveResult.ok(activityReadout(app(), boot: boot(), max: max));
      }),
      DriveAction('refresh', (args) async {
        final state = app();
        final unavailable = state.activityUnavailable;
        if (unavailable != null) return DriveResult.refused(unavailable);
        if (state.isLoadingActivity) return const DriveResult.refused('already_loading');
        final id = ops.start('activityRefresh', _refresh(state, boot));
        return DriveResult.ok({'id': id});
      }),
      DriveAction('markRead', (args) async {
        final selection = _selection(args);
        final state = app();
        final unavailable = state.activityUnavailable;
        if (unavailable != null) return DriveResult.refused(unavailable);
        final items = state.activity;
        final List<ActivityItem> chosen;
        if (selection == null) {
          chosen = items;
        } else {
          final byId = {for (final item in items) item.id: item};
          final missing = [for (final id in selection) if (!byId.containsKey(id)) id];
          if (missing.isNotEmpty) return DriveResult.refused('no_such_item', {'missing': missing});
          chosen = [for (final id in selection) byId[id]!];
        }
        // The same filter markActivityRead applies, so `skipped` says what it will skip.
        final markable = [for (final i in chosen) if (i.canMarkRead && !i.isRead) i.id];
        final skipped = [
          for (final i in chosen)
            if (!i.canMarkRead || i.isRead) {'id': i.id, 'why': i.isRead && i.canMarkRead ? 'already_read' : 'cannot_mark'},
        ];
        if (markable.isEmpty) return DriveResult.refused('nothing_to_mark', {'skipped': skipped});
        final id = ops.start('activityMarkRead', _markRead(state, boot, chosen, markable, skipped));
        return DriveResult.ok({'id': id, 'marking': markable, 'skipped': skipped});
      }),
    ]);

Future<DriveResult> _refresh(AppState state, String Function() boot) async {
  await state.refreshActivity();
  final error = state.activityError;
  if (error != null) return DriveResult.refused('fetch_failed', {'error': '$error'});
  return DriveResult.ok(activityReadout(state, boot: boot()));
}

Future<DriveResult> _markRead(
  AppState state,
  String Function() boot,
  List<ActivityItem> chosen,
  List<String> marking,
  List<Map<String, Object?>> skipped,
) async {
  final before = state.activityError;
  await state.markActivityRead(chosen);
  final after = state.activityError;
  if (after != null && !identical(after, before)) {
    return DriveResult.refused('mark_failed', {'error': '$after', 'marking': marking});
  }
  return DriveResult.ok({'marked': marking, 'skipped': skipped, ...activityReadout(state, boot: boot())});
}

/// `{all: true}` → null (everything); `{ids: [...]}` → those ids.
List<String>? _selection(Map<String, Object?> args) {
  final all = args['all'];
  final ids = args['ids'];
  if (all != null && all is! bool) throw const DriveInvalidParams('"all" must be a boolean');
  if (all == true && ids != null) throw const DriveInvalidParams('pass "ids" or "all": true, not both');
  if (all == true) return null;
  if (ids == null) throw const DriveInvalidParams('"ids" is required (or "all": true)');
  if (ids is! List || ids.isEmpty) throw const DriveInvalidParams('"ids" must be a non-empty list of strings');
  return [
    for (final id in ids)
      if (id is String && id.isNotEmpty) id else throw const DriveInvalidParams('"ids" must be a non-empty list of strings'),
  ];
}

/// The `activity.list` readout on its own.
Map<String, Object?> activityReadout(AppState state, {required String boot, int max = 200}) {
  final items = state.activity;
  final error = state.activityError;
  return {
    'boot': boot,
    'spaceId': state.snapshot.self.spaceId,
    'unavailable': state.activityUnavailable,
    'fetched': state.activityFetched,
    'loading': state.isLoadingActivity,
    'error': error == null ? null : '$error',
    'count': items.length,
    'unread': state.unreadActivityCount,
    'items': [for (final item in items.take(max)) _item(state, item)],
    'truncated': items.length > max,
    if (items.isEmpty)
      'empty': state.activityUnavailable ??
          (error != null
              ? 'fetch_failed'
              : state.activityFetched
                  ? 'nothing_yet'
                  : 'not_fetched'),
  };
}

Map<String, Object?> _item(AppState state, ActivityItem item) {
  final actor = item.actorSpaceUserId;
  return {
    'id': item.id,
    'kind': switch (item) {
      WaveActivity() => 'wave',
      MentionActivity() => 'mention',
      ReactionActivity() => 'reaction',
      ReplyActivity() => 'reply',
      MeetingArtifactActivity() => 'meetingArtifact',
      OnboardingActivity() => 'onboarding',
      UnknownActivity() => 'unknown',
    },
    'at': item.at?.toUtc().toIso8601String(),
    'isRead': item.isRead,
    'canMarkRead': item.canMarkRead,
    'actorId': actor,
    'actorName': actor == null ? null : state.nameFor(actor),
    ...switch (item) {
      MentionActivity(:final message) || ReactionActivity(:final message) || ReplyActivity(:final message) => {
          'message': message,
        },
      MeetingArtifactActivity() => {
          'meetingId': item.meetingId,
          'meetingTitle': item.meetingTitle,
          'hasMeetingMemo': item.hasMeetingMemo,
          'hasVideoRecording': item.hasVideoRecording,
          'participantCount': item.participantCount,
        },
      OnboardingActivity(:final kind) => {'onboardingKind': kind},
      UnknownActivity(:final kind) => {'unknownKind': kind},
      WaveActivity() => const <String, Object?>{},
    },
  };
}
