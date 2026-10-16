/// Being audible and visible in the room, as the rest of the app sees it.
///
/// [MediaEngine] is the hardware and [SfuSession] is the wire; this is the pair
/// of them, driven by the two buttons a person actually presses. Splitting it out
/// is what keeps `AppState` free of `flutter_webrtc` — the same discipline that
/// put the capture behind [MediaEngine] in the first place, one level up.
///
/// ## Why mute is two things at once
///
/// Turning the microphone off does both a device mute and a `produce-pause`, and
/// neither is redundant. The device mute is what makes iOS drop its recording
/// indicator, so the phone stops claiming to listen. The pause is what makes a
/// colleague's client draw the crossed-out microphone beside your name. Doing
/// only the first leaves everyone else believing you are live; doing only the
/// second leaves the orange dot lit while you are muted, which is the worse of
/// the two lies.
///
/// ## Why the producers are kept while muted
///
/// A producer is an ICE and DTLS negotiation. Closing it on every mute would make
/// unmuting take a second or more, in the one moment where a person has decided
/// to speak — so muting pauses and unmuting resumes, and the transport is built
/// once.
library;

import 'media_engine.dart';

/// What the call is doing, on top of what the hardware is doing.
///
/// [LocalMediaState] answers "is the camera on"; this adds "does anybody else
/// receive it", which are different questions and fail separately — a phone can
/// be capturing perfectly while the SFU has refused us.
class CallState {
  const CallState({
    this.media = const LocalMediaState(),
    this.publishingAudio = false,
    this.publishingVideo = false,
    this.publishingScreen = false,
    this.participants = const [],
    this.connecting = const {},
    this.detail,
  });

  final LocalMediaState media;

  /// Everybody else we are receiving, in no particular order.
  ///
  /// Deliberately free of `MediaStream`: a native handle here would drag the
  /// WebRTC plugin into every file that reads call state, and the fake engine
  /// could no longer stand in. The screen that draws video reaches for
  /// `LiveCall.streamFor` instead, which is the same split `localStream` uses.
  final List<CallParticipant> participants;

  /// srcIds of peers the SFU is still placing — subscribed, no media address
  /// yet. Not participants (they carry no track), and not the same as somebody
  /// sitting silent: these are mid-connect. The tiles for them read
  /// "connecting…" so a walk-up colleague is not mistaken for a quiet one and
  /// nobody restarts waiting on a peer the session is already chasing. Sourced
  /// from `SfuSession.connectingPeers`.
  final Set<String> connecting;

  /// Whether the room is actually receiving each track, as opposed to us merely
  /// having it open.
  final bool publishingAudio;
  final bool publishingVideo;

  /// Whether the room is receiving our screen share. Separate from the capture
  /// flag in [media]: the broadcast can be running on the device while the SFU
  /// has not picked the producer up yet, exactly as [publishingVideo] is separate
  /// from the camera being open.
  final bool publishingScreen;

  /// What went wrong, if the last thing asked for did not happen. A sentence, for
  /// putting in front of a person.
  final String? detail;

  bool get micOn => media.capturing && media.audioEnabled;
  bool get cameraOn => media.hasVideo;

  /// Whether the screen share is live, as the button reflects it. Driven off the
  /// capture flag so the tap registers the instant the broadcast starts, the same
  /// way [cameraOn] follows the camera rather than the producer.
  bool get screenOn => media.hasScreen;

  /// Where the sound is coming out, for the button that switches it.
  AudioOutput get audioOutput => media.audioOutput;

  /// Whether anybody else is on the other end. A call of one is a rehearsal.
  bool get hasCompany => participants.isNotEmpty;

  /// Whether the hardware is open at all — false before the first tap, which is
  /// what makes the bar honest about not holding the camera until asked.
  bool get live => media.capturing;

  CallState copyWith({
    LocalMediaState? media,
    bool? publishingAudio,
    bool? publishingVideo,
    bool? publishingScreen,
    List<CallParticipant>? participants,
    Set<String>? connecting,
    String? detail,
    bool clearDetail = false,
  }) =>
      CallState(
        media: media ?? this.media,
        publishingAudio: publishingAudio ?? this.publishingAudio,
        publishingVideo: publishingVideo ?? this.publishingVideo,
        publishingScreen: publishingScreen ?? this.publishingScreen,
        participants: participants ?? this.participants,
        connecting: connecting ?? this.connecting,
        detail: clearDetail ? null : (detail ?? this.detail),
      );

  @override
  String toString() => 'CallState(mic: $micOn, camera: $cameraOn, '
      'publishing: ${[
        if (publishingAudio) 'audio',
        if (publishingVideo) 'video',
        if (publishingScreen) 'screen',
      ].join('+')})';
}

/// Somebody else in the call, as the UI needs to know them.
///
/// Identified by `srcId` — their `UserAccount.id`, which is what the media plane
/// speaks — and **not** by `SpaceUser.id`, which is what the roster speaks. Any
/// screen that wants to put a name to a tile has to bridge the two through
/// `RosterRow.userAccountId`; the two planes genuinely disagree about what a
/// person is called.
class CallParticipant {
  const CallParticipant({
    required this.srcId,
    this.hasAudio = false,
    this.hasVideo = false,
    this.audioPaused = false,
    this.videoPaused = false,
    this.sharingScreen = false,
  });

  final String srcId;
  final bool hasAudio;
  final bool hasVideo;

  /// *Their* mute, not ours. The track is still subscribed and will start again
  /// without renegotiating, so a paused person is present, not gone.
  final bool audioPaused;
  final bool videoPaused;
  final bool sharingScreen;

  bool get videoLive => hasVideo && !videoPaused;
  bool get muted => !hasAudio || audioPaused;

  @override
  String toString() => 'CallParticipant($srcId, '
      '${[if (hasAudio) 'audio', if (videoLive) 'video'].join('+')})';
}

/// How much of the screen somebody's video is getting.
///
/// The names are sizes rather than layer numbers on purpose: the screen knows
/// how big it is drawing a face, and only [LiveCall] needs to know that Gather
/// spells that as a simulcast spatial layer between 0 and 2.
enum VideoQuality {
  /// Nobody is looking. Also what everyone off-screen gets.
  thumbnail,

  /// Sharing the screen with one or two others.
  half,

  /// Filling it.
  full;

  /// Gather's spatial layer, as `consume-set-spatial` wants it.
  int get spatialLayer => switch (this) {
        VideoQuality.thumbnail => 0,
        VideoQuality.half => 1,
        VideoQuality.full => 2,
      };
}

/// The two buttons, and what it takes to honour them.
///
/// Every method is safe to call in any order and at any time: the first one that
/// needs hardware opens it, and the first one that needs the SFU connects to it.
/// Nothing is opened before it is asked for, which is the whole reason a phone
/// can sit on the map screen without its camera light on.
abstract class Call {
  Stream<CallState> get states;
  CallState get state;

  /// Whether we are talking right now, as often as that answer changes.
  ///
  /// On this interface rather than on [CallState] because it is not call state:
  /// it changes several times a minute while nothing about the call does, and
  /// folding it in would republish the whole thing — and rebuild every screen
  /// listening — on every pause between sentences.
  ///
  /// Nothing in the media plane produces this. Gather's speaking ring comes off
  /// the *game* socket, from `SpaceUser.speaking`, which its clients set with
  /// `startSpeaking`/`stopSpeaking`; the SFU carries the audio and says nothing
  /// about whether anybody is using it. So this is measured here — from the
  /// microphone's own level — and `AppState` is what puts it on the wire.
  Stream<bool> get speaking;

  /// The current answer, for a screen that starts listening mid-sentence.
  bool get isSpeaking;

  /// Turns the microphone on or off, opening the hardware the first time.
  ///
  /// Returns null when it took, or a sentence explaining why it did not — the
  /// same contract as `AppState.setPartyMode`, because it ends up in the same
  /// snack bar.
  Future<String?> setMicOn(bool on);

  Future<String?> setCameraOn(bool on);

  /// Starts or stops sharing the phone's screen into the room, as a producer
  /// separate from the camera. Opens the system broadcast picker the first time.
  /// Same null-or-a-sentence contract as [setMicOn].
  Future<String?> setScreenShareOn(bool on);

  /// Sends the sound to the loudspeaker (`true`) or back to the earpiece —
  /// or to a headset if one is connected. Same null-or-a-sentence contract as
  /// [setMicOn].
  Future<String?> setSpeakerOn(bool on);

  /// Front to back and back again. A no-op with no camera running.
  Future<void> switchCamera();

  /// Who is allowed to see and hear **us**, by `UserAccount.id`.
  ///
  /// A separate, wider set than [setListeningTo], and separate for the reason the
  /// desktop client keeps them separate: this one is everybody *in range*, and it
  /// is what makes your camera appear in a circle over your avatar for anyone
  /// standing near you. Without it, publishing video reaches nobody — the SFU
  /// answers their `consume` with `consume-not-allowed`.
  Future<void> setVisibleTo(Set<String> srcIds);

  /// Who we should be receiving, by `UserAccount.id`.
  ///
  /// The whole desired set every time rather than joins and leaves, because that
  /// is the shape the cluster arrives in and diffing in one place is the only way
  /// to be sure somebody who vanished between two rosters is actually let go.
  ///
  /// **A non-empty set connects the media plane**, without waiting for anybody to
  /// press anything. That is what the desktop client does — it holds both media
  /// sockets from the moment it joins the space — and it is what lets you hear a
  /// conversation you have walked into without first announcing yourself by
  /// unmuting.
  Future<void> setListeningTo(Set<String> srcIds);

  /// Which conversation we are in, by Gather's own `clusterId`.
  ///
  /// Passed straight through to `set-player-conversation-metadata`. Null when
  /// standing alone, which is a thing worth saying rather than a thing to omit.
  Future<void> setConversation(String? clusterId);

  /// Who is on screen, most important first, and how big they are drawn.
  ///
  /// Peers left out get the smallest layer. An empty list therefore means "nobody
  /// is looking at video", which is the normal state of a companion app: the map
  /// draws no faces, so the call screen being closed should cost the room's
  /// uplink nothing.
  Future<void> setWatching(List<String> srcIds, {required VideoQuality quality});

  /// Puts the hardware down and stops publishing. The call can be restarted.
  Future<void> hangUp();

  /// Throws away the current media session and builds a fresh one, putting back
  /// whatever we were listening to and publishing.
  ///
  /// For the case a socket close never signals: an external device on this same
  /// account (the desktop client, issue #41) locks or sleeps, and the server tears
  /// our shared media session down with it — but this session can still believe it
  /// is connected, so pointing it at the cluster again would re-subscribe onto a
  /// dead session and wait out the deaf-timer. A rebuild is the recovery a dropped
  /// socket gets, fired without waiting for the person to tap anything.
  Future<void> rebuild();

  Future<void> dispose();
}
