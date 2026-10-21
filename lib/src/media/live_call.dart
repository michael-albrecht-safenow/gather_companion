/// [Call], actually connected: the capture session, the SFU, and the order the
/// two have to happen in.
///
/// ## Capture is exactly what was asked for, and restarting is the price
///
/// [MediaEngine.startCapture] takes the tracks it wants once and returns early if
/// a session is already open, so a microphone-only capture cannot grow a camera
/// later. The obvious workaround — always capture both and leave the video track
/// disabled — is the one thing this must not do: `track.enabled = false` stops
/// the frames while the capture session keeps running, so iOS keeps the camera
/// indicator lit and the phone claims to be watching the room when it is not.
/// `webrtc_media_engine.dart` makes the same argument about the microphone.
///
/// So the session is opened with precisely the tracks in use, and turning the
/// camera on for the first time *restarts* it. That costs a moment of audio and
/// a republish, and it happens at most once per call, which is a better trade
/// than a camera light nobody asked for.
///
/// ## The SFU is connected when there is somebody to hear, not at join
///
/// Steps 1–4 of `SfuSession` (assignment, connection, capabilities) are being
/// *ready* rather than publishing, and the desktop client does them at space
/// join — `docs/gather-api.md` is explicit that "a client that defers opening the
/// SFU socket until a cluster forms is doing something the real client does not".
///
/// This connects on the first *conversation* instead. Waiting for a tap, which is
/// what it used to do, had a consequence worth stating plainly: a phone could not
/// hear anybody until it started talking, because nothing opened the socket that
/// carries other people's audio. Walking up to a group and listening — the
/// ordinary thing to do in an office — was the one thing the app could not do.
///
/// Standing alone still costs nothing. An empty cluster opens no socket, and a
/// phone in a pocket in an empty room is exactly where it was before.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gather_client/gather_client.dart';

import 'call.dart';
import 'capture_engine.dart';
import 'media_engine.dart';
import 'sfu_session.dart';
import 'voice_activity.dart';
import 'webrtc_media_engine.dart';

class LiveCall implements Call {
  LiveCall({
    required GatherAuth auth,
    required String spaceId,
    required String srcId,
    CaptureEngine? engine,
    SfuSession Function()? buildSfu,
    VoiceActivity? voice,
    void Function(String)? log,
  })  : _auth = auth,
        _voice = voice ?? VoiceActivity(),
        _log = log ?? _noop,
        _engine = engine ?? WebrtcMediaEngine(log: log),
        _buildSfu = buildSfu ??
            (() => SfuSession(
                  auth: auth,
                  spaceId: spaceId,
                  srcId: srcId,
                  log: log,
                )) {
    _engineSub = _engine.states.listen((media) {
      _emit(_state.copyWith(media: media));
      _noticeScreenEnded(media);
    });
  }

  /// The OS owns the "Stop" control for a system broadcast, so a share can end
  /// without a tap in this app: the engine reports the screen capture gone while
  /// [_wantScreen] still believes it is on. Catch that, drop the producer, and
  /// clear the intent so the button falls back rather than offering to "stop" a
  /// share that is already over.
  void _noticeScreenEnded(LocalMediaState media) {
    if (!_wantScreen || media.hasScreen) return;
    _log('call: the screen share ended outside the app; dropping the producer');
    unawaited(_serialise(() async {
      _wantScreen = false;
      await _sfu?.unpublish(SfuTag.screen);
      _emit(_state.copyWith(publishingScreen: false));
      return null;
    }));
  }

  static void _noop(String _) {}

  /// Held so the bad-auth heal can force a fresh ID token before a rebuild — the
  /// `_buildSfu` closure captures it too, but a reconnect with the *same* cached
  /// token the SFU just refused loops forever (#84).
  final GatherAuth _auth;
  final void Function(String) _log;
  final CaptureEngine _engine;
  final SfuSession Function() _buildSfu;

  StreamSubscription<LocalMediaState>? _engineSub;
  StreamSubscription<List<RemoteMedia>>? _remoteSub;
  StreamSubscription<SfuNotification>? _noticeSub;
  StreamSubscription<void>? _republishSub;
  SfuSession? _sfu;

  /// Let go of a session's streams before it is thrown away.
  Future<void> _detach() async {
    await _remoteSub?.cancel();
    _remoteSub = null;
    await _noticeSub?.cancel();
    _noticeSub = null;
    await _republishSub?.cancel();
    _republishSub = null;
  }

  /// Who we want to hear, held here rather than only in the session.
  ///
  /// The cluster can change while the SFU is not connected — a colleague walks
  /// over before anyone has tapped anything — and the desired set has to survive
  /// that so the session can be brought up to date once it exists.
  Set<String> _listeningTo = const {};

  /// Who may consume us — everybody in range, not just the conversation.
  Set<String> _visibleTo = const {};

  /// The streams behind [CallState.participants], by `srcId`.
  final Map<String, Map<SfuTag, MediaStream>> _remoteStreams = {};

  final _states = StreamController<CallState>.broadcast();
  CallState _state = const CallState();

  final _speaking = StreamController<bool>.broadcast();

  /// The thresholds and the hold. Injectable so a test can ask about the
  /// *plumbing* — that the poll starts on an unmuted publish and stops on a mute
  /// — in one beat, instead of waiting out a hold tuned for human speech. The
  /// tuning itself is asserted directly, in `voice_activity_test.dart`.
  final VoiceActivity _voice;
  Timer? _voicePoll;

  /// Whether a sample is still in flight. `getStats` crosses a platform channel
  /// and can take longer than the interval below, and without this a slow device
  /// would queue samples behind each other and then answer them all at once —
  /// which reads to [VoiceActivity] as a burst of identical measurements at the
  /// wrong times.
  bool _sampling = false;

  /// What the person has asked for, which is not the same as what is running.
  /// A tap that fails must not leave the button showing the state it failed to
  /// reach, and these are what the retry on the next tap is judged against.
  bool _wantMic = false;
  bool _wantCamera = false;
  bool _wantScreen = false;

  /// Reentrancy guard for the bad-auth token heal in [_publish]. A stale SFU
  /// token (after a transport change the socket slept through) is refused with
  /// `TokenVerificationFailed`; the heal rebuilds the session to mint a fresh
  /// one and retries the publish exactly once. Without this flag a token that is
  /// still bad after the rebuild would rebuild-and-retry forever (#57).
  bool _authHealing = false;

  /// Watches for a wanted track that has not reached the room for 5s, after
  /// which it sets [CallState.needsHandoff] and the "Pull session over" banner
  /// appears (issue #67). A single-device takeover does not latch `displaced`
  /// until the third flapping notice, so this timer is what catches the ordinary
  /// one-takeover case — and any other stall — before the sticky flag ever sets.
  Timer? _handoffTimer;

  /// Serialises the whole thing. Two taps in quick succession would otherwise
  /// interleave a capture restart with a publish and produce on a dead track.
  Future<void> _work = Future.value();

  @override
  Stream<CallState> get states => _states.stream;

  @override
  CallState get state => _state;

  @override
  Stream<bool> get speaking => _speaking.stream;

  @override
  bool get isSpeaking => _voice.speaking;

  /// The live capture, for the widget that draws the preview. Concrete on
  /// purpose — a `MediaStream` cannot cross [Call] without dragging the plugin
  /// with it.
  MediaStream? get localStream => _engine.localStream;

  @override
  Future<String?> setMicOn(bool on) => _serialise(() async {
        _wantMic = on;
        if (!on) {
          // Device first, so the indicator goes out at the moment of the tap
          // rather than after a round trip to the SFU.
          await _engine.setAudioEnabled(false);
          _sfu?.pause(SfuTag.audio);
          // A mute is not a stuck publish: drop any pending watch so it cannot
          // raise the banner over a microphone the person turned off themselves.
          _maybeClearHandoffWatch();
          _emit(_state.copyWith(publishingAudio: false, clearDetail: true));
          return null;
        }

        await _ensureCapture();
        await _engine.setAudioEnabled(true);
        final detail = await _publish(SfuTag.audio);
        await _republishOthers(SfuTag.audio);
        // Again, now that there is a sender.
        //
        // `setMicrophoneMuted` drives the audio *device module*, not the track,
        // and the module is only running once something is actually capturing
        // for a peer connection. Unmuting before that can be applied to an
        // engine that is then rebuilt underneath it, which leaves the producer
        // live and the microphone silent — signalling all green, nothing
        // audible. Idempotent, so it costs nothing when the first one took.
        await _engine.setAudioEnabled(true);
        return detail;
      });

  @override
  Future<String?> setCameraOn(bool on) => _serialise(() async {
        _wantCamera = on;
        if (!on) {
          await _engine.setVideoEnabled(false);
          _sfu?.pause(SfuTag.video);
          _maybeClearHandoffWatch();
          _emit(_state.copyWith(publishingVideo: false, clearDetail: true));
          return null;
        }

        await _ensureCapture();
        await _engine.setVideoEnabled(true);
        final detail = await _publish(SfuTag.video);
        await _republishOthers(SfuTag.video);
        return detail;
      });

  @override
  Future<String?> setScreenShareOn(bool on) => _serialise(() async {
        _wantScreen = on;
        if (!on) {
          // Unpublish before stopping the capture: the producer should go off the
          // wire while its track is still alive, rather than the SFU holding a
          // sender onto a track that is being torn down underneath it.
          await _sfu?.unpublish(SfuTag.screen);
          await _engine.stopScreenCapture();
          _maybeClearHandoffWatch();
          _emit(_state.copyWith(publishingScreen: false, clearDetail: true));
          return null;
        }

        // A second, independent capture — the system picker — that does not touch
        // the camera/mic session. On denial the engine throws and the button
        // falls back, the same shape as a refused camera.
        try {
          await _engine.startScreenCapture();
        } on MediaFailure catch (failure) {
          _wantScreen = false;
          return _fail(SfuTag.screen, failure.message);
        }
        return _publishScreen();
      });

  /// Puts the screen-share track on the wire, from its own capture stream.
  ///
  /// The twin of [_publish], but it pulls the track from [CaptureEngine.screenStream]
  /// rather than the camera/mic `localStream` — the whole point of a separate
  /// capture is a separate track, published as its own [SfuTag.screen] producer.
  Future<String?> _publishScreen() async {
    final stream = _engine.screenStream;
    final track = stream?.getVideoTracks().firstOrNull;
    if (stream == null || track == null) {
      _wantScreen = false;
      return _fail(SfuTag.screen, 'The screen share did not open.');
    }

    try {
      final sfu = await _sfuOrStart();
      if (sfu.publishing(SfuTag.screen)) {
        sfu.resume(SfuTag.screen);
      } else {
        await sfu.publish(track, stream, tag: SfuTag.screen);
      }
    } on Object catch (error) {
      _log('call: publishing the screen failed: $error');
      if (_sfu?.displaced ?? false) _emit(_state.copyWith(needsHandoff: true));
      // The broadcast is live and only the wire failed, so the button stays on
      // and the sentence says the room cannot see it yet — same stance as a
      // camera that captured but did not reach the SFU.
      _armHandoffWatch();
      return _fail(SfuTag.screen,
          'You are sharing, but Gather has not picked up the screen yet.');
    }

    _maybeClearHandoffWatch();
    _emit(_state.copyWith(publishingScreen: true, clearDetail: true));
    return null;
  }

  /// Put back whatever a capture restart took with it.
  ///
  /// [_ensureCapture] closes both producers before it reopens the hardware,
  /// because they are about to point at tracks that no longer exist — and the
  /// tap that caused it only ever republishes its own. So turning the camera on
  /// while talking used to close the audio producer and never reopen it: the
  /// camera came on and you went silent, with every button still saying you
  /// were live.
  Future<void> _republishOthers(SfuTag just) async {
    final sfu = _sfu;
    if (sfu == null) return;
    if (_wantMic && just != SfuTag.audio && !sfu.publishing(SfuTag.audio)) {
      await _publish(SfuTag.audio);
    }
    if (_wantCamera && just != SfuTag.video && !sfu.publishing(SfuTag.video)) {
      await _publish(SfuTag.video);
    }
    // The screen rides its own capture, untouched by a camera restart, so this is
    // only reached when the heal is for something else — but it belongs here for
    // the same reason the others do: a republish that forgets a tag drops it.
    if (_wantScreen &&
        just != SfuTag.screen &&
        !sfu.publishing(SfuTag.screen)) {
      await _publishScreen();
    }
  }

  @override
  Future<String?> setSpeakerOn(bool on) => _serialise(() async {
        // Serialised so it cannot land between a capture restart's stop and
        // start, where the session it reaches for is momentarily gone. The new
        // route reaches the UI through the engine-state subscription, not here.
        await _engine.setSpeakerOn(on);
        return null;
      });

  @override
  Future<void> switchCamera() => _engine.switchCamera();

  /// Opens a capture session holding exactly the tracks in use, restarting it if
  /// the set has grown.
  ///
  /// Only *growing* forces a restart. Turning the camera off leaves its track
  /// captured and disabled, because the alternative — tearing the session down to
  /// drop one track — would cut the audio mid-sentence every time somebody turns
  /// their camera off.
  Future<void> _ensureCapture() async {
    final media = _engine.state;
    final needsVideo = _wantCamera && media.videoTrackId == null;

    if (media.capturing && !needsVideo) return;

    if (media.capturing && needsVideo) {
      _log('call: restarting capture to add the camera');
      // The producers are about to be pointing at tracks that no longer exist.
      await _sfu?.unpublish(SfuTag.audio);
      await _sfu?.unpublish(SfuTag.video);
      _emit(_state.copyWith(publishingAudio: false, publishingVideo: false));
      await _engine.stopCapture();
    }

    // The session and its loudspeaker default, before the capture it will carry.
    // Idempotent, so the first talker and the first listener can both ask.
    await _engine.prepareAudioSession();

    // Audio unconditionally: a capture session with no microphone in it would
    // have to be torn down again the moment the mic is unmuted, and the mic is
    // the one people reach for.
    await _engine.startCapture(audio: true, video: _wantCamera);

    // `startCapture` opens every track it was given. Anything not asked for is
    // put back down immediately rather than left running.
    if (!_wantMic) await _engine.setAudioEnabled(false);
    if (!_wantCamera) await _engine.setVideoEnabled(false);
  }

  /// Puts one track on the wire, connecting to the SFU if this is the first.
  Future<String?> _publish(SfuTag tag) async {
    final stream = _engine.localStream;
    final track = switch (tag) {
      SfuTag.audio => stream?.getAudioTracks().firstOrNull,
      SfuTag.video => stream?.getVideoTracks().firstOrNull,
      // Screen capture is a separate stream with its own publish path
      // ([_publishScreen]); it never comes through here.
      SfuTag.screen => null,
    };
    if (stream == null || track == null) {
      return _fail(tag, 'The ${tag == SfuTag.audio ? 'microphone' : 'camera'} '
          'did not open.');
    }

    try {
      final sfu = await _sfuOrStart();
      if (sfu.publishing(tag)) {
        sfu.resume(tag);
      } else {
        await sfu.publish(track, stream, tag: tag);
      }
    } on Object catch (error) {
      _log('call: publishing ${tag.wire} failed: $error');
      if (_sfu?.displaced ?? false) {
        // Sticky takeover: the banner's immediate trigger. The 5s watch is only
        // for the case `displaced` has not latched yet.
        _emit(_state.copyWith(needsHandoff: true));
        return _fail(
          tag,
          'Your Mac keeps taking this call back. Quit Gather there, then turn '
          'your microphone on again here.',
        );
      }
      // Not displaced, but the wire refused: arm the stuck-watch so a publish
      // that never recovers raises the banner after the grace window.
      _armHandoffWatch();
      // A stale SFU token — the socket slept through a transport change and the
      // server now refuses every produce `bad auth / TokenVerificationFailed`,
      // which no restart-free path recovers on its own (#57). Rebuild the
      // session to mint a fresh token and retry the publish once. The guard
      // stops a token that is still bad after the rebuild from looping; it falls
      // through to the ordinary failure message instead.
      if (_isStaleAuth(error) && !_authHealing) {
        _authHealing = true;
        _log('call: SFU refused bad-auth — minting a fresh token and rebuilding (#57/#84)');
        try {
          // Drop the cached token first. The rebuild re-opens the socket, which
          // asks `GatherAuth.idToken` for a credential — but that hands back the
          // *same* cached token until it is near clock-expiry, and the SFU has
          // just refused it after a suspend. Without this, the rebuild presents
          // the rejected token again and loops forever (#84).
          await _auth.invalidateIdToken();
          // `_rebuild`, not the public `rebuild`: we are already inside the
          // serialise job, so taking the lock again would deadlock. It republishes
          // this tag onto the fresh session itself, so we return *that* result —
          // a second `_publish(tag)` here would be a duplicate produce the fresh
          // session also refuses on a still-bad token.
          return await _rebuild(report: tag);
        } finally {
          _authHealing = false;
        }
      }
      // The hardware is live and only the wire failed, so the button stays on:
      // the person is unmuted, and the sentence says the room cannot hear them
      // yet. Silently flipping it back would read as the tap not registering.
      return _fail(tag, 'You are unmuted, but Gather has not picked up the '
          '${tag == SfuTag.audio ? 'audio' : 'video'} yet.');
    }

    // The track reached the room, so there is nothing to hand off: cancel the
    // watch and take the banner down if it was up.
    _maybeClearHandoffWatch();
    _emit(_state.copyWith(
      publishingAudio: tag == SfuTag.audio ? true : null,
      publishingVideo: tag == SfuTag.video ? true : null,
      clearDetail: true,
    ));
    return null;
  }

  /// A produce refusal that means the SFU token is stale, not that the track or
  /// the transport is wrong. The server sends `bad auth` with
  /// `{reason: TokenVerificationFailed}`, which `SfuSignalling` surfaces as the
  /// message of an [SfuException]. Keyed on both strings because only the reason
  /// is stable across Gather's error shapes.
  bool _isStaleAuth(Object error) =>
      error is SfuException &&
      (error.message.contains('TokenVerificationFailed') ||
          error.message.contains('bad auth'));

  /// The connected session, connecting it if this is the first thing to need one.
  ///
  /// Single-flight. Two things can now ask for a session at once — a tap on the
  /// microphone and a colleague walking into the cluster — and without this they
  /// would each build one, leaving the loser's sockets open with nothing reading
  /// them and its producers publishing into a session nobody consults.
  Future<SfuSession> _sfuOrStart() {
    final existing = _sfu;
    if (existing != null && existing.ready) return Future.value(existing);
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<SfuSession>? _starting;

  Future<SfuSession> _start() async {
    final existing = _sfu;
    if (existing != null) {
      // Started once and did not finish — a half-open session is worse than none.
      // Disposed rather than stopped: it is being thrown away, and `stop` leaves
      // its stream controllers open with nothing left to feed them.
      await _detach();
      await existing.dispose();
    }
    // The audio session, before the peer connection that will carry the remote
    // sound. This is the listen-only path — you hear a conversation you walked
    // into without unmuting — and it is where the earpiece default bit hardest.
    await _engine.prepareAudioSession();
    final sfu = _sfu = _buildSfu();
    _remoteSub = sfu.remoteChanges.listen(_onRemotes);
    _noticeSub = sfu.notifications.listen(_onNotice);
    // A dropped socket or a drained node takes every producer with it, and only
    // this class holds the tracks to put back.
    _republishSub = sfu.needsRepublish.listen(_onNeedsRepublish);
    // Before `start()`, so the node replays it the moment it connects rather
    // than after the first track has already gone out unwatchable.
    sfu.setAllowed(_visibleTo);
    sfu.setConversation(clusterId: _clusterId);
    await sfu.start();

    // Whatever the room looked like while we were not connected is what it
    // should look like now. Without this, everybody who was already standing
    // there when the mic was first tapped would be silent.
    if (_listeningTo.isNotEmpty) await sfu.setSubscriptions(_listeningTo);
    if (_watching.isNotEmpty) {
      sfu.setWatching(_watching, layer: _quality.spatialLayer);
    }
    return sfu;
  }

  /// Put back whatever the person still wants, after the wire lost it.
  ///
  /// Queued behind anything already in flight rather than run inline: a
  /// reconnection can land in the middle of a tap, and republishing while
  /// `_ensureCapture` is restarting the session would produce on a track that is
  /// about to be stopped.
  void _onNeedsRepublish(void _) {
    if (!_wantMic && !_wantCamera && !_wantScreen) return;
    _log('call: the SFU lost our producers; putting them back');
    unawaited(_serialise(() async {
      if (_sfu == null) return null;
      if (_wantMic) await _publish(SfuTag.audio);
      if (_wantCamera) await _publish(SfuTag.video);
      if (_wantScreen) await _publishScreen();
      return null;
    }));
  }

  @override
  Future<void> setVisibleTo(Set<String> srcIds) async {
    if (_visibleTo.length == srcIds.length && _visibleTo.containsAll(srcIds)) {
      return;
    }
    _visibleTo = Set.unmodifiable(srcIds);
    // Worth a line of its own: an empty allow list is indistinguishable from a
    // working call right up until nobody can hear you, and it leaves no trace on
    // the wire — `consume-allow` is simply never sent.
    _log('call: ${srcIds.length} may consume us${srcIds.isEmpty ? ' — nobody can hear us' : ''}');
    // Held whether or not a session exists, and replayed by `start()`. Somebody
    // can walk up to you long before you tap anything, and the allow list has to
    // be right at the moment the first track goes out — not one roster later.
    _sfu?.setAllowed(_visibleTo);
  }

  @override
  Future<void> setListeningTo(Set<String> srcIds) async {
    if (_listeningTo.length == srcIds.length &&
        _listeningTo.containsAll(srcIds)) {
      return;
    }
    _listeningTo = Set.unmodifiable(srcIds);

    if (_listeningTo.isEmpty) {
      // Nobody left to hear. The session stays up if it exists — we may still be
      // publishing, and tearing it down over an empty cluster would cost a full
      // reconnection the moment somebody walks back.
      //
      // A screen share is the exception. Unlike the mic/camera it is a
      // heavyweight, user-visible system broadcast — the iOS red indicator, the
      // whole device captured — and it makes no sense to keep it running with
      // nobody watching. Walking out of the conversation should end it, exactly
      // as tapping Stop would; otherwise the broadcast keeps going back at your
      // desk. Mic/camera stay as they are, so walking back is still cheap.
      if (_wantScreen) await setScreenShareOn(false);
      final sfu = _sfu;
      if (sfu != null && sfu.ready) await sfu.setSubscriptions(const {});
      return;
    }

    try {
      // Connects if nothing has yet. Being in a conversation is reason enough:
      // the cluster is already debounced by 1.5 seconds upstream, so this is a
      // conversation somebody has actually stopped to have, not a passer-by.
      final sfu = await _sfuOrStart();
      await sfu.setSubscriptions(_listeningTo);
    } on Object catch (error) {
      // Deliberately quiet. Nobody pressed anything, so there is no button to
      // put back and no sentence anybody asked for; the next roster tries again.
      _log('call: could not join the conversation: $error');
    }
  }

  @override
  Future<void> setConversation(String? clusterId) async {
    if (clusterId == _clusterId) return;
    _clusterId = clusterId;
    _sfu?.setConversation(clusterId: clusterId);
  }

  @override
  Future<void> setWatching(
    List<String> srcIds, {
    required VideoQuality quality,
  }) async {
    _watching = List.unmodifiable(srcIds);
    _quality = quality;
    _sfu?.setWatching(_watching, layer: quality.spatialLayer);
  }

  String? _clusterId;
  List<String> _watching = const [];
  VideoQuality _quality = VideoQuality.thumbnail;

  /// The streams for one participant, for the widget that draws them.
  ///
  /// Concrete rather than on [Call], for the same reason [localStream] is: a
  /// `MediaStream` on the interface would drag the plugin into everything that
  /// reads call state.
  Map<SfuTag, MediaStream> streamFor(String srcId) =>
      _remoteStreams[srcId] ?? const {};

  /// The one server-pushed message a person needs to be told about.
  ///
  /// The phone and the desktop client are one `UserAccount`, so they are one
  /// `srcId` to the SFU. The phone keeps the call — you picked it up, so it is
  /// where you are — but the desktop letting go is the *server's* doing, not
  /// something this app can ask for: nothing in the protocol drops another
  /// client. So the honest thing is to name what is happening and what to do
  /// about it, rather than either going quiet or promising a handover we cannot
  /// perform.
  void _onNotice(SfuNotification n) {
    if (n.name != 'double-connected') return;
    final sfu = _sfu;

    if (sfu?.displaced ?? false) {
      // Sticky displaced has latched — raise the "Pull session over" banner now,
      // rather than waiting out the 5s stuck-watch the single-takeover case needs.
      _emit(_state.copyWith(
        publishingAudio: false,
        publishingVideo: false,
        needsHandoff: true,
        detail: 'Your Mac keeps taking this call back. Quit Gather there, then '
            'turn your microphone on again here. You can still see and hear '
            'everyone in the meantime.',
      ));
      return;
    }

    // The softer, first-notice advisory: Gather is merely also open on the Mac.
    // Not a handoff prompt — nothing is stuck yet. But a takeover can stop our
    // send without a produce attempt to re-arm the watch from, so arm it here
    // too; the 5s re-check reads the live producers, so a duplicate connection
    // that is still publishing fine stands it straight back down (issue #67).
    _armHandoffWatch();
    _emit(_state.copyWith(
      detail: 'Gather is open on your Mac too. Quit it there if the sound '
          'starts jumping between them.',
    ));
  }

  void _onRemotes(List<RemoteMedia> remotes) {
    _remoteStreams
      ..clear()
      ..addEntries(remotes.map((r) => MapEntry(r.srcId, r.streams)));

    _emit(_state.copyWith(
      participants: [
        for (final r in remotes)
          CallParticipant(
            srcId: r.srcId,
            hasAudio: r.streams.containsKey(SfuTag.audio),
            hasVideo: r.streams.containsKey(SfuTag.video),
            audioPaused: r.paused.contains(SfuTag.audio),
            videoPaused: r.paused.contains(SfuTag.video),
            sharingScreen: r.streams.containsKey(SfuTag.screen),
          ),
      ],
      // Peers the router has not placed yet, carried alongside the participants
      // they are not yet among. The session re-emits `remoteChanges` whenever
      // this set moves, so a tile flips to "connecting…" and back without ever
      // holding a stream of its own.
      connecting: _sfu?.connectingPeers ?? const {},
    ));
  }

  /// Start the 5s stuck-watch, unless it is already running (issue #67).
  ///
  /// Armed from every branch that fails to put a wanted track on the wire. The
  /// timer re-checks *current* state when it fires rather than the state that
  /// armed it — the same discipline as `SfuSession._scheduleSendHeal`, because a
  /// republish can succeed in the window and a snapshot would then raise the
  /// banner over a call that is already healthy again.
  void _armHandoffWatch() {
    if (_handoffTimer != null) return;
    _handoffTimer = Timer(const Duration(seconds: 5), () {
      _handoffTimer = null;
      if (_anyWantedTrackStuck() || (_sfu?.displaced ?? false)) {
        _emit(_state.copyWith(needsHandoff: true));
      }
    });
  }

  /// A wanted track that is not actually on the wire, read from the live SFU
  /// producers rather than the UI flags (issue #67).
  ///
  /// The `publishing*` flags describe the *last* result: a republish that fails
  /// leaves `publishingAudio` true from the prior success, so a snapshot of them
  /// cannot tell a stuck send from a healthy one. The producer map is the truth —
  /// `publishing(tag)` is only true while a producer is actually up on the node.
  bool _anyWantedTrackStuck() {
    final sfu = _sfu;
    if (sfu == null) return _wantMic || _wantCamera || _wantScreen;
    return (_wantMic && !sfu.publishing(SfuTag.audio)) ||
        (_wantCamera && !sfu.publishing(SfuTag.video)) ||
        (_wantScreen && !sfu.publishing(SfuTag.screen));
  }

  /// Lower the stuck-watch, but only when every wanted track is really on the
  /// wire and the session is not displaced (issue #67).
  ///
  /// Called from every publish success and every path that puts a wanted track
  /// down on purpose. A success on one track must not cancel the watch another
  /// track armed, and a mute/camera-off is a deliberate stand-down for *that*
  /// track only — so the decision is made against the live producers, not the
  /// one action that happened to call in.
  void _maybeClearHandoffWatch() {
    if (_anyWantedTrackStuck() || (_sfu?.displaced ?? false)) return;
    _handoffTimer?.cancel();
    _handoffTimer = null;
    if (_state.needsHandoff) _emit(_state.copyWith(needsHandoff: false));
  }

  String _fail(SfuTag tag, String sentence) {
    _emit(_state.copyWith(detail: sentence));
    return sentence;
  }

  @override
  Future<void> hangUp() async {
    _wantMic = false;
    _wantCamera = false;
    _wantScreen = false;
    _handoffTimer?.cancel();
    _handoffTimer = null;
    await _detach();
    await _sfu?.dispose();
    _sfu = null;
    _remoteStreams.clear();
    await _engine.releaseAudioSession();
    await _engine.stopScreenCapture();
    await _engine.stopCapture();
    // The desired set survives a hang-up: the cluster has not changed just
    // because we stopped listening to it, and the next tap should pick up the
    // same room rather than an empty one.
    _emit(const CallState());
  }

  @override
  Future<void> rebuild() async {
    // Serialised like every other session-touching path, so a rebuild landing in
    // the middle of a tap cannot interleave a capture restart with a produce.
    await _serialise(() async {
      await _rebuild();
      return null;
    });
  }

  @override
  Future<String?> pullSessionOver() => _serialise(() async {
        // Clear the sticky `displaced` stand-down so `publish` stops refusing,
        // then rebuild onto the current node and put our tracks back; the fresh
        // session is the deliberate "new session" the takeover can only be undone
        // by. The banner stays up throughout: `_publish` lowers it only once the
        // tracks are actually back (via `_maybeClearHandoffWatch`), so a reclaim
        // that fails leaves the button on screen to try again rather than a silent
        // dead call (issue #67).
        _sfu?.clearDisplaced();
        try {
          // On a clean rebuild `_publish` has already lowered the banner; on a
          // publish refusal it has re-armed the watch. Either way the result is
          // the sentence to surface (null on success).
          return await _rebuild();
        } on Object catch (error) {
          // `_start` threw before any republish could re-arm the watch — keep the
          // banner up so the person can try again, and report the failure rather
          // than letting the UI's `!mounted` check swallow it into a dead call.
          _log('call: pull-session-over rebuild failed: $error');
          if (!_state.needsHandoff) {
            _emit(_state.copyWith(needsHandoff: true));
          }
          return 'Could not reconnect to the room. Tap to try again.';
        }
      });

  /// The rebuild itself, already holding the queue.
  ///
  /// Split out from [rebuild] because the bad-auth heal in [_publish] runs
  /// *inside* a `_serialise` job already: calling the public [rebuild] from there
  /// would queue behind the job it is part of and deadlock. This takes no lock,
  /// so it may only be called from a path that already holds one.
  ///
  /// [report] names the track whose republish result the caller wants back — the
  /// bad-auth heal passes the tag it was trying to publish, because the republish
  /// below *is* its single retry: a second `_publish(tag)` on the fresh session
  /// would send a duplicate produce (refused twice on a still-bad token). Returns
  /// that tag's detail (`null` on success), or — when nobody names a tag (the
  /// reclaim path) — the first wanted track that could not be put back.
  Future<String?> _rebuild({SfuTag? report}) async {
    // Nothing to rebuild: no session, nobody to hear, nothing to send. The next
    // cluster or tap builds one from scratch, which is the right amount of work.
    if (_sfu == null &&
        _listeningTo.isEmpty &&
        !_wantMic &&
        !_wantCamera &&
        !_wantScreen) {
      return null;
    }
    _log('call: rebuilding the media session after an external teardown');
    // `_start` disposes the stale session, opens fresh transports, and replays
    // the allow list, the conversation and the subscriptions — but not our
    // producers, since only this class holds the tracks to put back.
    //
    // Published through the single-flight slot (issue #41): a recovery rebuild and
    // the 1.5s cluster debounce's `setListeningTo` can fire at the same instant, and
    // `setListeningTo`'s `_sfuOrStart` would otherwise see our not-yet-ready session
    // and launch a *second* `_start` that disposes the one this rebuild is standing
    // up — orphaning the producers we are about to republish. Forced (not `??=`)
    // because a rebuild must discard the stale session, not join an in-flight start
    // of it; a concurrent `_sfuOrStart` then awaits this start instead of racing one.
    await (_starting = _start().whenComplete(() => _starting = null));
    String? audioDetail;
    String? videoDetail;
    String? screenDetail;
    if (_wantMic) audioDetail = await _publish(SfuTag.audio);
    if (_wantCamera) videoDetail = await _publish(SfuTag.video);
    if (_wantScreen) screenDetail = await _publishScreen();
    return switch (report) {
      SfuTag.audio => audioDetail,
      SfuTag.video => videoDetail,
      SfuTag.screen => screenDetail,
      // No tag asked for (the reclaim path): surface the first track that could
      // not be put back, so a reclaim onto a session that still cannot publish
      // does not read as success (issue #67).
      null => audioDetail ?? videoDetail ?? screenDetail,
    };
  }

  @override
  Future<void> dispose() async {
    await _engineSub?.cancel();
    _engineSub = null;
    await _detach();
    await _sfu?.dispose();
    _sfu = null;
    _remoteStreams.clear();
    await _engine.dispose();
    _voicePoll?.cancel();
    _voicePoll = null;
    _handoffTimer?.cancel();
    _handoffTimer = null;
    if (!_states.isClosed) await _states.close();
    if (!_speaking.isClosed) await _speaking.close();
  }

  /// Runs [job] after everything already queued, and never lets one failure
  /// poison the queue for the next tap.
  Future<String?> _serialise(Future<String?> Function() job) {
    final next = _work.then((_) => job()).catchError((Object error) {
      _log('call: $error');
      return _fail(SfuTag.audio, 'That did not work: $error');
    });
    _work = next.then((_) {}, onError: (_) {});
    return next;
  }

  void _emit(CallState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
    // Every path that starts, pauses, resumes or drops the audio producer ends
    // here, which is what makes this the one place the poll has to be kept in
    // step with. Hooking the individual taps instead meant remembering to do it
    // in `hangUp`, in the republish after a reconnect, and in the capture
    // restart the camera forces — three places that each stop the microphone for
    // reasons that have nothing to do with speaking.
    _syncVoiceActivity();
  }

  /// How often the microphone level is read while somebody might be talking.
  ///
  /// Each poll is a `getStats` across the platform channel, so this is a cost
  /// and not a free timer. 200 ms against [VoiceActivity]'s 900 ms hold gives
  /// four or five samples inside the window that decides somebody has stopped —
  /// enough that one slow or missing answer changes nothing.
  static const _voiceInterval = Duration(milliseconds: 200);

  /// Runs the poll exactly when there is a live, unpaused microphone.
  ///
  /// Both halves are load-bearing. Polling a paused producer would read the
  /// device's own mute as silence and arrive at the right answer by luck; not
  /// polling at all while muted is the *reason* it is the right answer, and it
  /// also means a phone sitting on the map screen runs no timer.
  void _syncVoiceActivity() {
    final wanted = _wantMic && _state.publishingAudio;
    if (wanted == (_voicePoll != null)) return;

    if (!wanted) {
      _voicePoll?.cancel();
      _voicePoll = null;
      // Immediately, without waiting out the hold. Somebody who presses mute
      // mid-sentence should not keep a ring lit on everybody else's screen for
      // another second, and the hold exists for pauses in speech rather than for
      // decisions.
      if (_voice.silence()) _emitSpeaking();
      return;
    }
    _voicePoll = Timer.periodic(_voiceInterval, (_) => unawaited(_sample()));
  }

  Future<void> _sample() async {
    if (_sampling) return;
    _sampling = true;
    try {
      final level = await _sfu?.microphoneLevel();
      if (_voice.note(level, DateTime.now())) _emitSpeaking();
    } finally {
      _sampling = false;
    }
  }

  void _emitSpeaking() {
    // Worth a line each way, and worth keeping. Whether the room can see you
    // talking is the one claim in this app with no other evidence behind it:
    // `startSpeaking` is acknowledged privately, writes a field this client
    // never reads back for itself, and shows up as a ring on somebody else's
    // screen. Two lines per sentence is a cheap price for being able to answer
    // "did the phone ever say it was talking" without borrowing their laptop.
    _log('call: ${_voice.speaking ? 'talking' : 'quiet'}');
    if (!_speaking.isClosed) _speaking.add(_voice.speaking);
  }
}
