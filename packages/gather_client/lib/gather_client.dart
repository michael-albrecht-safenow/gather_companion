/// Gather V2's game protocol, spoken directly from the app.
///
/// The bridge used to be the only thing that talked to Gather; the phone read a
/// digest of it over the LAN. This package is that conversation, ported — so the
/// app holds its own connection and the bridge is needed only for pairing and for
/// pushes while the app is asleep.
library;

export 'src/activity_feed.dart';
export 'src/avatar.dart';
export 'src/backend_config.dart';
export 'src/collector.dart';
export 'src/direct_collector.dart';
export 'src/game_protocol.dart';
export 'src/gather_auth.dart';
export 'src/meeting_link.dart';
export 'src/msgpack.dart';
export 'src/otp_login.dart';
export 'src/party.dart';
export 'src/profile_photos.dart';
export 'src/presence_tracker.dart';
export 'src/sfu_signalling.dart';
export 'src/space_art.dart';
export 'src/space_map.dart';
export 'src/walk.dart';
