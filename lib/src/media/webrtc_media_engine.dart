/// The one file in the app that touches WebRTC.
///
/// Everything else talks to [MediaEngine]. Keeping the plugin import in a single
/// place is what lets `AppState` and the call logic be tested on a machine with
/// no camera, and it is the same discipline `DirectCollector`'s connect-seam
/// follows for the socket.
///
/// ## What `flutter_webrtc` is left to do
///
/// Audio session management is **not** hand-configured here. Since 1.5.0 the
/// Darwin implementation runs on AVAudioEngine with Apple's platform voice
/// processing — acoustic echo cancellation, noise suppression, automatic gain —
/// and that is materially better than anything worth writing by hand. Taking it
/// over is an option the plugin offers and a decision this app has no reason to
/// make.
///
/// Output *routing* is the one exception, and it is a different thing. Left to
/// the plugin defaults, remote audio comes out of the earpiece — right for a
/// phone held to the ear, wrong for a companion app set down on a desk, where you
/// then hear nobody. So [prepareAudioSession] sets the loudspeaker as the default
/// (and auto-selects a headset when one is in), through the plugin's own
/// `setAppleAudioIOMode` / `setAndroidAudioConfiguration` / `setSpeakerphoneOn`.
/// Those set category, mode and route; they do **not** switch off the voice
/// processing above, so the two stances do not contradict.
///
/// Mute happens at the **audio device**, not on the track, and the platform mute
/// sound is accepted rather than avoided.
///
/// `track.enabled = false` is the obvious alternative and the wrong one here. It
/// stops the frames while the capture session keeps running, which means iOS
/// keeps its orange microphone indicator lit for the whole time you are muted —
/// and somebody watching that dot will reasonably conclude they are still being
/// listened to. Being quietly wrong about whether a microphone is live is not a
/// thing this app should do.
///
/// So mute goes through `Helper.setMicrophoneMuted`, in
/// [MicrophoneMuteMode.voiceProcessing]. That mode plays the platform's
/// mute/unmute sound on every toggle. That is Apple's deliberate affordance, not
/// a defect, and it comes with the thing that makes it worth having: **muted
/// talker detection**, the system noticing when you are speaking while muted.
/// Every call app eventually grows a "you're on mute" tap on the shoulder; this
/// one gets it from the platform.
///
/// The two silent modes exist and are the trade to make if the sound ever becomes
/// the complaint: [MicrophoneMuteMode.inputMixer] is fast and silent but keeps the
/// session running, and [MicrophoneMuteMode.restartEngine] is silent and actually
/// stops capture, at the price of a slower unmute.
///
/// Because the device switch is **global rather than per-track**, the state below
/// is read back with `isMicrophoneMuted()` after every change rather than
/// assumed. Assuming would let the UI and the hardware drift apart, and the
/// direction that drift goes — showing "muted" while live — is the bad one.
///
/// **Unverified on hardware.** The justification above rests on iOS treating a
/// voice-processing mute as "not recording" and dropping the orange indicator,
/// which is the behaviour the API exists to provide. It has not been watched on a
/// real device yet. If the dot stays lit while muted, the reasoning for choosing
/// this over `track.enabled` collapses and the choice should be revisited rather
/// than kept for its own sake.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'capture_engine.dart';
import 'media_engine.dart';

/// Capture constraints, tuned for a proximity call rather than a broadcast.
///
/// 640×480 at 24fps is what Gather's own client settles on for its lowest
/// simulcast layer, and on a phone in someone's hand it is indistinguishable from
/// more. `facingMode: user` because a video call is a face.
const _videoConstraints = <String, dynamic>{
  'mandatory': {
    'minWidth': '320',
    'minHeight': '240',
    'minFrameRate': '15',
  },
  'facingMode': 'user',
  'optional': [
    {'maxWidth': '640'},
    {'maxHeight': '480'},
    {'maxFrameRate': '24'},
  ],
};

class WebrtcMediaEngine implements CaptureEngine {
  WebrtcMediaEngine({void Function(String)? log, this._manageAudioRoute = true})
      : _log = log ?? _noop;

  static void _noop(String _) {}

  final void Function(String) _log;

  /// Whether this engine forces the output route itself, or leaves it to the OS.
  ///
  /// True on Android, where the app is the only thing routing call audio. False
  /// on iOS once CallKit is in the picture: CallKit owns the `AVAudioSession` and
  /// the route picker lives in the system call sheet, so forcing the speaker from
  /// here (`setSpeakerphoneOn`) and re-forcing it on every device change would
  /// fight the system — the very AVAudioSession contention that froze the media
  /// check. When false, [prepareAudioSession] still sets the call *category* (so
  /// there is a call session at all) but installs no device-change override, and
  /// [setSpeakerOn] is a no-op — the in-app button that drove it is hidden on iOS.
  final bool _manageAudioRoute;

  final _states = StreamController<LocalMediaState>.broadcast();
  LocalMediaState _state = const LocalMediaState();

  MediaStream? _stream;

  /// The person's standing choice, or null to follow the default — loudspeaker
  /// unless a headset is in. A tap pins it; a headset plugged or pulled clears it
  /// back to the default, so AirPods grab the audio and unplugging falls back to
  /// the speaker rather than the earpiece.
  bool? _speakerOverride;

  /// So [prepareAudioSession] configures the platform once and installs the
  /// device-change listener once, however many times it is called.
  bool _sessionReady = false;

  /// The in-flight route change, so overlapping ones serialise rather than
  /// interleave their enumerate / set / read-back. Null when none is running.
  Future<void>? _routing;

  /// A route request that arrived while one was in flight. Collapses a burst — a
  /// tap landing during a device-change — into a single trailing re-run on the
  /// latest [_speakerOverride], rather than one run per call.
  bool _routeDirty = false;

  /// The outputs last seen by the device-change listener. Setting the route is
  /// itself a device-change on iOS, so re-applying the route on *every*
  /// device-change is a feedback loop: setSpeakerphoneOn → route change →
  /// ondevicechange → setSpeakerphoneOn, which pins the audio session at dozens of
  /// reconfigurations a second and starves the media pipeline. We re-apply only
  /// when this set actually changes — a headset genuinely coming or going — which a
  /// self-induced route flip never does, because the *available* outputs are the
  /// same whichever one is currently active.
  Set<AudioOutput>? _knownOutputs;

  /// The last route we asked for, so a re-apply that would not change anything is
  /// skipped rather than written again. A redundant [Helper.setSpeakerphoneOn]
  /// still emits a route change, so this is the second guard against the loop.
  bool? _appliedSpeaker;

  @override
  Stream<LocalMediaState> get states => _states.stream;

  @override
  LocalMediaState get state => _state;

  /// The live capture, for the widget that draws it and the session that
  /// publishes it.
  ///
  /// Deliberately not on [MediaEngine]: a `MediaStream` crossing that interface
  /// would drag the plugin into every file that imports it, and the fake could no
  /// longer stand in. It lives on [CaptureEngine] instead — the narrower
  /// interface for the two callers that genuinely need the native handle.
  @override
  MediaStream? get localStream => _stream;

  @override
  Future<void> startCapture({bool audio = true, bool video = true}) async {
    if (_stream != null) return;

    _emit(_state.copyWith(clearFailure: true));

    // Stated rather than inherited. `voiceProcessing` is the plugin's default
    // today, but a default that changes underneath us would silently swap the
    // platform mute sound and muted-talker detection for neither, and nothing
    // would fail — it would just quietly stop behaving as documented above.
    //
    // Android answers `notImplemented`, so this throws rather than doing nothing,
    // and is caught below. Only the *mode* is Darwin-only: `setMicrophoneMuted`
    // and `isMicrophoneMuted` both reach Android's audio device module, so
    // everything else in this file behaves the same on both. What Android does
    // not give back is the indicator going out while muted — it keeps recording
    // and discards the samples — which is the one thing the mode above was
    // chosen for.
    try {
      await Helper.setMicrophoneMuteMode(MicrophoneMuteMode.voiceProcessing);
    } on Object catch (error) {
      _log('media: could not set the mute mode: $error');
    }

    final MediaStream stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        'audio': audio,
        'video': video ? _videoConstraints : false,
      });
    } on Object catch (error) {
      final failure = _classify(error);
      _log('media: capture failed — ${failure.message}');
      _emit(_state.copyWith(capturing: false, failure: failure, clearTracks: true));
      throw failure;
    }

    _stream = stream;
    // Ask the tracks what we actually got rather than assuming we got what we
    // asked for: a device with no camera still returns a stream, just without a
    // video track in it.
    final videoTrack = stream.getVideoTracks().firstOrNull;
    final audioTrack = stream.getAudioTracks().firstOrNull;

    // The desktop client sets `contentHint` here — `'speech'` for the mic,
    // `'motion'` for the camera. We cannot: it is a browser API and
    // `webrtc_interface` does not surface it on `MediaStreamTrack`.
    //
    // For *these two* tracks that costs approximately nothing, because those two
    // values are already libwebrtc's defaults: audio processing on, and video
    // degrading by resolution before framerate. The hint only earns its keep when
    // you want to deviate — `'music'` to switch audio processing off, or
    // `'detail'`/`'text'` for a screen share, where dropping resolution to hold
    // framerate is what makes shared text unreadable.
    //
    // Both of those are reachable by other means when we need them: audio
    // processing through `getUserMedia` constraints (`echoCancellation`,
    // `noiseSuppression`, `autoGainControl`), and the video tradeoff through
    // `RTCRtpParameters.degradationPreference`
    // (`MAINTAIN_FRAMERATE` / `MAINTAIN_RESOLUTION`) on the sender. So this is a
    // note about where to look later, not a gap.

    _emit(LocalMediaState(
      capturing: true,
      audioEnabled: audioTrack != null,
      videoEnabled: videoTrack != null,
      frontCamera: true,
      videoTrackId: videoTrack?.id,
      audioTrackId: audioTrack?.id,
    ));
    _log('media: capturing '
        '${[if (audioTrack != null) 'audio', if (videoTrack != null) 'video'].join(' + ')}');

    // A fresh session does not imply a fresh device. Something else may hold the
    // mute switch — another app, or a previous run that died before releasing it
    // — so ask rather than open on an optimistic "unmuted".
    if (audioTrack != null) await _syncMuteFromDevice();
  }

  @override
  Future<void> stopCapture() async {
    final stream = _stream;
    _stream = null;

    // Leave the device as we found it. Device mute outlives this object — a
    // session ended while muted would otherwise start the *next* one muted, with
    // nothing on screen explaining why.
    if (stream != null) {
      try {
        await Helper.setMicrophoneMuted(false);
      } on Object {
        /* nothing to do but not leave it stuck */
      }
    }
    if (stream != null) {
      // Stopping each track *and* disposing the stream. Disposing alone leaves
      // the camera light on for a moment on iOS, which looks like a privacy bug
      // whether or not it is one.
      for (final track in [...stream.getTracks()]) {
        try {
          await track.stop();
        } on Object {
          /* already gone */
        }
      }
      try {
        await stream.dispose();
      } on Object {
        /* already gone */
      }
    }
    // Deliberately *not* releasing the audio session here: this also runs on a
    // mid-call capture restart (adding the camera), and the route must outlive it.
    _emit(const LocalMediaState());
  }

  /// Hands the audio session back: drops the device-change listener, forgets any
  /// forced route, and on Android clears the communication device so the next
  /// session is not pinned to this one's choice.
  @override
  Future<void> releaseAudioSession() async {
    if (!_sessionReady) return;
    _sessionReady = false;
    _speakerOverride = null;
    _knownOutputs = null;
    _appliedSpeaker = null;
    navigator.mediaDevices.ondevicechange = null;
    if (Platform.isAndroid) {
      try {
        await Helper.clearAndroidCommunicationDevice();
      } on Object catch (error) {
        _log('media: could not clear the communication device: $error');
      }
    }
  }

  @override
  Future<void> setAudioEnabled(bool enabled) async {
    if (_stream?.getAudioTracks().firstOrNull == null) return;

    try {
      await Helper.setMicrophoneMuted(!enabled);
    } on Object catch (error) {
      // Do not claim a state we failed to reach. A mute button that lies is
      // worse than one that visibly did nothing.
      _log('media: could not ${enabled ? 'unmute' : 'mute'} the device: $error');
      return;
    }

    await _syncMuteFromDevice();
  }

  /// Reads the device's own answer rather than trusting ours.
  ///
  /// `setMicrophoneMuted` is a global switch, so our idea of it can go stale for
  /// reasons that have nothing to do with this object. On a platform where the
  /// call is a no-op this correctly reports *unmuted*, because nothing was muted.
  Future<void> _syncMuteFromDevice() async {
    bool muted;
    try {
      muted = await Helper.isMicrophoneMuted();
    } on Object catch (error) {
      _log('media: could not read the device mute state: $error');
      return;
    }
    // Said out loud, because "the microphone is live" is the one claim in this
    // app that can be wrong without anything failing: the producer is accepted,
    // the colleague's client draws you unmuted, and the room hears silence.
    // Measured 2026-09-17: the phone sent 63 packets of 32 bytes in five
    // seconds, which is Opus DTX describing an empty room.
    final track = _stream?.getAudioTracks().firstOrNull;
    _log('media: the device reports the microphone '
        '${muted ? 'MUTED' : 'live'}, track.enabled=${track?.enabled}');
    _emit(_state.copyWith(audioEnabled: !muted));
  }

  @override
  Future<void> prepareAudioSession() async {
    if (_sessionReady) return;
    _sessionReady = true;

    // The platform session, set the plugin's own way. This is not the hand-rolled
    // AVAudioSession the header refuses: it sets category, mode and route, and
    // leaves Apple's voice processing (AEC/NS/AGC) exactly where it was.
    try {
      if (Platform.isIOS) {
        await Helper.setAppleAudioIOMode(AppleAudioIOMode.localAndRemote);
      } else if (Platform.isAndroid) {
        await Helper.setAndroidAudioConfiguration(
          AndroidAudioConfiguration.communication,
        );
      }
    } on Object catch (error) {
      _log('media: could not configure the audio session: $error');
    }

    // When the OS owns the route, stop here. The category above is set — there is
    // a call session — but nothing below forces a route or listens for headsets:
    // on iOS that is CallKit's job and the system call sheet's route picker, and
    // a second hand on the wheel is the AVAudioSession contention to avoid.
    if (!_manageAudioRoute) return;

    // One callback, owned here. A headset coming or going is a reason to redo the
    // default — not to honour a tap from before it was plugged in. Guarded by
    // [_knownOutputs] so the route change our own [_applyRouteOnce] causes does not
    // come straight back in as a device-change and loop.
    _knownOutputs = await _externalOutputs();
    navigator.mediaDevices.ondevicechange = (_) => unawaited(_onDeviceChange());

    await _applyRoute();
  }

  /// The *external* outputs — a headset or Bluetooth device — ignoring the
  /// built-in speaker/earpiece pair.
  ///
  /// iOS only enumerates the earpiece *while it is the active route*, so forcing
  /// earpiece makes it appear in [_outputs] and forcing speaker makes it vanish.
  /// Comparing the full set would therefore see every route flip we make
  /// ourselves as a hardware change — which both re-feeds the device-change loop
  /// and wipes the user's speaker/earpiece choice. Only an external device coming
  /// or going is a genuine reason to redo the default, and that set *is* stable
  /// under our own route flips.
  Future<Set<AudioOutput>> _externalOutputs() async => {
        for (final d in await _outputs())
          if (d == AudioOutput.bluetooth || d == AudioOutput.wired) d,
      };

  /// A headset plugged or pulled clears the override and redoes the default.
  /// Anything that leaves the set of *external* outputs unchanged — notably the
  /// built-in speaker/earpiece flip [_applyRouteOnce] itself just made — is
  /// ignored, which is what stops the device-change listener feeding back into
  /// itself and what lets an earpiece choice survive the route change it causes.
  Future<void> _onDeviceChange() async {
    final outputs = await _externalOutputs();
    final known = _knownOutputs;
    if (known != null &&
        known.length == outputs.length &&
        known.containsAll(outputs)) {
      return;
    }
    _knownOutputs = outputs;
    _speakerOverride = null;
    await _applyRoute();
  }

  @override
  Future<void> setSpeakerOn(bool on) async {
    // The OS owns the route here, so there is nothing to force. The in-app button
    // that would call this is hidden on iOS for the same reason; this guard is the
    // belt to that braces, so a stray call cannot start a fight over the session.
    if (!_manageAudioRoute) return;
    _speakerOverride = on;
    await _applyRoute();
  }

  /// Serialises route changes. Two overlapping runs — the device-change callback
  /// and a speaker tap, or a burst of taps — would interleave their enumerate /
  /// set / read-back and let a stale [_syncOutput] land last. So at most one runs;
  /// a request arriving mid-run is collapsed into a single trailing re-run that
  /// reads the latest [_speakerOverride].
  Future<void> _applyRoute() {
    if (_routing != null) {
      _routeDirty = true;
      return _routing!;
    }
    return _routing = _runRoute();
  }

  Future<void> _runRoute() async {
    try {
      do {
        _routeDirty = false;
        await _applyRouteOnce();
      } while (_routeDirty);
    } finally {
      _routing = null;
    }
  }

  /// Puts the route where [_speakerOverride] — or, failing that, the presence of
  /// a headset — says it should go, then reads back what actually happened.
  ///
  /// Enumerates *before* deciding so a headset already connected at startup wins
  /// the default rather than losing to a stale read.
  Future<void> _applyRouteOnce() async {
    final headset = (await _outputs())
        .any((d) => d == AudioOutput.bluetooth || d == AudioOutput.wired);
    final speaker = _speakerOverride ?? !headset;
    // A re-apply that would not change the route still emits a route change, so
    // skip the *write* — writing it anyway is what the loop feeds on. But the
    // published output still has to refresh: an external device can appear or
    // vanish (AirPods in or out) without changing this boolean, and the glyph
    // must follow the device even when the route write is a no-op. _syncOutput
    // only enumerates and emits — it never calls setSpeakerphoneOn — so it
    // cannot re-feed the device-change loop.
    if (speaker == _appliedSpeaker) {
      await _syncOutput();
      return;
    }
    try {
      // false does not mean earpiece: it releases the override and lets the
      // system pick, which is headset-if-present, earpiece otherwise.
      await Helper.setSpeakerphoneOn(speaker);
    } on Object catch (error) {
      _log('media: could not set the audio route: $error');
      return;
    }
    _appliedSpeaker = speaker;
    await _syncOutput();
  }

  /// Publishes the active route as [AudioOutput].
  ///
  /// Not read from [_outputs] ordering: iOS lists the synthetic `Speaker` first
  /// even while the earpiece is the active route, so `outputs.first` reported
  /// speaker for every route and pinned the UI there. An external device, when
  /// present, is always the active route; otherwise the route is exactly what
  /// [_applyRouteOnce] just set — speaker when [_appliedSpeaker], earpiece when
  /// not — which is the one signal that actually tracks the earpiece.
  Future<void> _syncOutput() async {
    final outputs = await _outputs();
    final external = [
      for (final d in outputs)
        if (d == AudioOutput.bluetooth || d == AudioOutput.wired) d,
    ];
    final next = external.isNotEmpty
        ? external.first
        : (_appliedSpeaker == false
            ? AudioOutput.earpiece
            : AudioOutput.speaker);
    _emit(_state.copyWith(audioOutput: next));
  }

  /// The current output route(s), newest-active-first, as [AudioOutput].
  ///
  /// iOS lists only the active port plus a synthetic `Speaker`; Android lists the
  /// available devices keyed by fixed strings. Both are mapped off `label` and
  /// `deviceId`, which is the only signal the plugin gives for kind.
  Future<List<AudioOutput>> _outputs() async {
    final List<MediaDeviceInfo> devices;
    try {
      devices = await navigator.mediaDevices.enumerateDevices();
    } on Object catch (error) {
      _log('media: could not read the audio outputs: $error');
      return const [];
    }
    return [
      for (final d in devices)
        if (d.kind == 'audiooutput') _classifyOutput(d),
    ].whereType<AudioOutput>().toList();
  }

  static AudioOutput? _classifyOutput(MediaDeviceInfo d) {
    final tag = '${d.deviceId} ${d.label}'.toLowerCase();
    if (tag.contains('bluetooth') || tag.contains('airpod')) {
      return AudioOutput.bluetooth;
    }
    if (tag.contains('wired') || tag.contains('headphone') ||
        tag.contains('headset')) {
      return AudioOutput.wired;
    }
    if (tag.contains('speaker')) return AudioOutput.speaker;
    if (tag.contains('earpiece') || tag.contains('receiver')) {
      return AudioOutput.earpiece;
    }
    return null;
  }

  @override
  Future<void> setVideoEnabled(bool enabled) async {
    final track = _stream?.getVideoTracks().firstOrNull;
    if (track == null) return;
    track.enabled = enabled;
    _emit(_state.copyWith(videoEnabled: enabled));
  }

  @override
  Future<void> switchCamera() async {
    final track = _stream?.getVideoTracks().firstOrNull;
    if (track == null) return;
    try {
      await Helper.switchCamera(track);
      _emit(_state.copyWith(frontCamera: !_state.frontCamera));
    } on Object catch (error) {
      _log('media: could not switch camera: $error');
    }
  }

  @override
  Future<void> dispose() async {
    await releaseAudioSession();
    await stopCapture();
    await _states.close();
  }

  void _emit(LocalMediaState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }
}

/// Turns the plugin's platform errors into something a screen can act on.
///
/// The strings differ per platform and per OS version, so this matches loosely
/// and falls back to [MediaFailureKind.unknown] rather than guessing — telling
/// someone to open Settings when the real fault was a busy camera sends them
/// somewhere that cannot help.
MediaFailure _classify(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('notallowed') ||
      text.contains('permission') ||
      text.contains('denied')) {
    return MediaFailure(
      MediaFailureKind.permissionDenied,
      'Gather Companion needs the microphone and camera.',
    );
  }
  if (text.contains('notfound') ||
      text.contains('no device') ||
      text.contains('notreadable') ||
      text.contains('could not start')) {
    return MediaFailure(
      MediaFailureKind.noDevice,
      'No microphone or camera is available right now.',
    );
  }
  return MediaFailure(MediaFailureKind.unknown, '$error');
}
