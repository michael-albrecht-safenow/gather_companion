/// Does the microphone work, does the camera work, does sound come out, and do
/// you look right?
///
/// The first thing the media stack needed was somewhere to prove it runs at all
/// on a real device — permissions granted, a capture session opened, frames
/// arriving. That is worth keeping rather than throwing away once calls work: a
/// device check before you join something is a normal thing for a call app to
/// have, and it answers "is it me or is it them" without dragging a colleague
/// into the experiment.
///
/// It checks the whole path a meeting uses: the camera preview, a microphone
/// that lights up when it hears you, the speaker/earpiece route, and a sound to
/// send out of it. Nothing here talks to Gather. It opens the hardware, draws it,
/// and lets go.
///
/// ## Two modes, one framework at a time
///
/// There are two honest things a person might want to check, and on iOS they
/// cannot run at once — so a toggle picks one and the other is fully torn down.
///
///  - **Device** exercises the raw hardware the lightest way: the `camera` plugin
///    for the preview (opened **`enableAudio: false`**, so it never touches the
///    audio session) and `record` for a live "we can hear you" light read
///    straight off the microphone, the way a device-setup screen in Teams or Zoom
///    does. One owner of the camera, one of the audio session, nothing to fight.
///
///  - **Call pipeline** exercises the WebRTC capture path with the real
///    [WebrtcMediaEngine] — the pre-branch check, restored: a plain
///    `startCapture()` with mic/camera/switch and real mute (`setAudioEnabled`),
///    but **no** `prepareAudioSession`, route toggle or test sound. Forcing a
///    route on this standalone capture (no SFU transport connected) drives the
///    voice-processing reconfiguration loop that lagged the screen; a real call
///    tolerates it because its transport is live. The mic shows a plain
///    live/muted status rather than a level — WebRTC gives no local audio level
///    without a connection, and the loopback that used to fake one is exactly
///    what froze this screen.
///
/// Why the split at all: `flutter_webrtc` forces the shared `AVAudioSession` into
/// `videoChat` mode whenever it holds the camera, while `record` has to activate
/// that same session for the meter. Run together they flap the voice-processing
/// I/O unit hundreds of times a second and freeze the device. Kept apart — each
/// mode in its own child widget, so switching unmounts and disposes the other —
/// neither ever contends for the session.
///
/// ## Decisions are the controller's, lifetimes are the widget's
///
/// The check sequence, the failure split, the mic light and the mode live in
/// [MediaCheckController] (`../src/media/media_check_controller.dart`), so they
/// are testable without a device and readable by the debug drive
/// (`mediaCheck.*`). What stays here is what is genuinely the widget's: the
/// `RTCVideoRenderer` (texture initialised before use, `srcObject` cleared before
/// the engine stops the tracks under it), the camera preview it draws, and the
/// app lifecycle, which it forwards — iOS reclaims the camera in the background,
/// so the device check drops it on `paused` and reopens it on `resumed`. Each
/// mode's child opens its check in `initState` and releases it in `dispose`,
/// which is what keeps the one-framework-at-a-time teardown order exactly what
/// it was when all of this lived in `State`.
library;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../src/app_state.dart';
import '../src/media/media_check_controller.dart';
import '../src/media/media_check_hardware.dart';
import '../src/media/media_engine.dart';
import '../src/media/webrtc_media_engine.dart';
import '../theme/gather_theme.dart';

class MediaCheckScreen extends StatefulWidget {
  const MediaCheckScreen({super.key, required this.state, this.controller});

  /// Carried only to read two switches when the speaker test fires: whether
  /// sound effects are on at all, and whether Gameboy mode wants the chime in
  /// the handheld's square-wave voice instead of the plain sine.
  final AppState state;

  /// A seam for tests: the controller to run, with fake hardware behind it.
  /// Null builds the real one ([hardwareMediaCheck]). The screen disposes
  /// whichever it runs.
  final MediaCheckController? controller;

  @override
  State<MediaCheckScreen> createState() => _MediaCheckScreenState();
}

class _MediaCheckScreenState extends State<MediaCheckScreen> {
  late final MediaCheckController _controller = widget.controller ??
      hardwareMediaCheck(
        soundEffects: () => widget.state.soundEffects,
        gameboyMode: () => widget.state.gameboyMode,
      );

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    if (kDebugMode) mediaCheckDebugActive = _controller;
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    if (kDebugMode && identical(mediaCheckDebugActive, _controller)) {
      mediaCheckDebugActive = null;
    }
    _controller.removeListener(_onChanged);
    // After the children: their `dispose` (which releases each check) runs
    // before this one's, so the controller outlives every check it opened.
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final mode = _controller.mode;

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        title: const Text('Check your setup'),
        titleTextStyle: Theme.of(context).textTheme.titleLarge,
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(kGutter, kGutter, kGutter, 4),
              child: SegmentedButton<MediaCheckMode>(
                segments: const [
                  ButtonSegment(
                    value: MediaCheckMode.device,
                    icon: Icon(Icons.devices_rounded, size: 18),
                    label: Text('Device'),
                  ),
                  ButtonSegment(
                    value: MediaCheckMode.callPipeline,
                    icon: Icon(Icons.hub_rounded, size: 18),
                    label: Text('Call pipeline'),
                  ),
                ],
                selected: {mode},
                showSelectedIcon: false,
                onSelectionChanged: (s) => _controller.setMode(s.first),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(kGutter, 0, kGutter, 0),
              child: Text(
                mode == MediaCheckMode.device
                    ? 'The raw hardware — lightest path, with a live mic light.'
                    : 'The WebRTC capture path — camera and mute.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: t.mutedForeground),
              ),
            ),
            Expanded(
              // A keyed swap: picking the other mode unmounts this child, whose
              // `dispose` tears its framework down before the other's comes up —
              // which is the whole reason the two never share the audio session.
              child: mode == MediaCheckMode.device
                  ? _DeviceCheck(key: const ValueKey('device'), controller: _controller)
                  : _MeetingCheck(key: const ValueKey('meeting'), controller: _controller),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Device mode: camera plugin + record. No WebRTC, no audio-session fight.
// ---------------------------------------------------------------------------

class _DeviceCheck extends StatefulWidget {
  const _DeviceCheck({super.key, required this.controller});

  final MediaCheckController controller;

  @override
  State<_DeviceCheck> createState() => _DeviceCheckState();
}

class _DeviceCheckState extends State<_DeviceCheck> with WidgetsBindingObserver {
  late final DeviceCheck _check;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check = widget.controller.openDevice()..addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _check.appLifecycleChanged(state);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _check.removeListener(_onChanged);
    widget.controller.release(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final check = _check;
    final camera = check.camera;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kGutter),
      child: Column(
        children: [
          Expanded(
            child: _DevicePreview(
              camera: camera is PluginCheckCamera ? camera.controller : null,
              starting: check.starting,
              videoOn: check.videoOn,
              micLive: check.micLive,
              failure: check.failure,
              onRetry: check.retry,
            ),
          ),
          if (check.showControls) _MicStatus(live: check.micLive, hearing: check.hearing),
          if (check.showControls)
            _Controls(
              micLive: check.micLive,
              videoOn: check.videoOn,
              speaker: check.speaker,
              frontCamera: check.frontCamera,
              hasCamera: camera != null,
              canSwitch: check.canSwitch,
              onToggleMic: () => check.setMicLive(!check.micLive),
              onToggleVideo: () => check.setVideoOn(!check.videoOn),
              onSwitchCamera: check.switchCamera,
              onToggleSpeaker: () => check.setSpeaker(!check.speaker),
              onPlayTone: check.playTone,
            ),
          const SizedBox(height: kGutter),
        ],
      ),
    );
  }
}

class _DevicePreview extends StatelessWidget {
  const _DevicePreview({
    required this.camera,
    required this.starting,
    required this.videoOn,
    required this.micLive,
    required this.failure,
    required this.onRetry,
  });

  final CameraController? camera;
  final bool starting;
  final bool videoOn;
  final bool micLive;
  final MediaCheckFailure? failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final controller = camera;
    final showOff =
        !videoOn || controller == null || !controller.value.isInitialized;

    return _previewCard(
      context,
      failure: failure,
      failTitle: 'No camera',
      settingsBody: 'Gather Companion needs the camera. Turn it on in Settings, '
          'then come back.',
      starting: starting,
      startingBody: 'Opening the camera.',
      showOff: showOff,
      offTitle: controller == null ? 'No camera' : 'Camera off',
      offBody: micLive ? 'Your microphone is live.' : 'Your microphone is muted.',
      onRetry: onRetry,
      live: () => _CameraCover(controller: controller!),
    );
  }
}

/// A camera preview scaled to fill its frame rather than letterbox inside it.
///
/// `CameraPreview` reports its size in the sensor's landscape orientation, so on
/// a portrait phone the width and height are swapped before the `BoxFit.cover`
/// does its work — otherwise the preview comes out sideways and squashed.
class _CameraCover extends StatelessWidget {
  const _CameraCover({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.previewSize;
    if (size == null) return CameraPreview(controller);

    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: size.height,
            height: size.width,
            child: CameraPreview(controller),
          ),
        ),
      ),
    );
  }
}


// ---------------------------------------------------------------------------
// Call-pipeline mode: the pre-branch WebRTC check — plain capture, mic/camera/
// switch, no route forcing (that forcing is what lagged the screen).
// ---------------------------------------------------------------------------

class _MeetingCheck extends StatefulWidget {
  const _MeetingCheck({super.key, required this.controller});

  final MediaCheckController controller;

  @override
  State<_MeetingCheck> createState() => _MeetingCheckState();
}

class _MeetingCheckState extends State<_MeetingCheck> {
  final _renderer = RTCVideoRenderer();
  late final PipelineCheck _check;

  @override
  void initState() {
    super.initState();
    _check = widget.controller.openPipeline(PreviewBinding(
      initialize: _renderer.initialize,
      attach: (stream) => _renderer.srcObject = stream,
    ))
      ..addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _check.removeListener(_onChanged);
    // The renderer lets go first, then the check stops the tracks under it.
    _renderer.srcObject = null;
    _renderer.dispose();
    widget.controller.release(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final check = _check;
    final state = check.state;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kGutter),
      child: Column(
        children: [
          Expanded(
            child: _MeetingPreview(
              renderer: _renderer,
              state: state,
              starting: check.starting,
              onRetry: check.retry,
            ),
          ),
          if (check.showControls) _MicStatus(live: state.audioEnabled),
          if (check.showControls)
            _Controls(
              micLive: state.audioEnabled,
              videoOn: state.videoEnabled,
              // No route toggle and no test sound: the pre-branch check forced
              // neither, and forcing a route here is what lagged the screen. The
              // speaker flag stays at its unused default.
              frontCamera: state.frontCamera,
              hasCamera: true,
              canSwitch: check.canSwitch,
              onToggleMic: () => check.setMicLive(!state.audioEnabled),
              onToggleVideo: () => check.setVideoOn(!state.videoEnabled),
              onSwitchCamera: check.switchCamera,
              onToggleSpeaker: null,
              onPlayTone: null,
            ),
          const SizedBox(height: kGutter),
        ],
      ),
    );
  }
}


class _MeetingPreview extends StatelessWidget {
  const _MeetingPreview({
    required this.renderer,
    required this.state,
    required this.starting,
    required this.onRetry,
  });

  final RTCVideoRenderer renderer;
  final LocalMediaState state;
  final bool starting;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final failure = state.failure;

    return _previewCard(
      context,
      failure: failure == null ? null : MediaCheckFailure.fromMedia(failure),
      failTitle: 'No camera or microphone',
      settingsBody: 'Gather Companion needs the microphone and camera. Turn them '
          'on in Settings, then come back.',
      starting: starting,
      startingBody: 'Opening the microphone and camera.',
      showOff: !state.hasVideo,
      offTitle: state.capturing ? 'Camera off' : 'Not capturing',
      offBody: state.audioEnabled
          ? 'Your microphone is live.'
          : 'Your microphone is muted.',
      onRetry: onRetry,
      live: () => RTCVideoView(
        renderer,
        mirror: state.frontCamera,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared bits.
// ---------------------------------------------------------------------------

/// The card the preview and its messages sit in, identical across both modes.
Widget _frame(BuildContext context, Widget child) {
  final t = context.tokens;
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.symmetric(vertical: kGutter),
    decoration: BoxDecoration(
      color: t.card,
      border: Border.all(color: t.border),
      borderRadius: BorderRadius.circular(t.radius),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

/// The failure → starting → off → live ladder both previews walk, in one place.
///
/// The two modes differ only in their copy and their live child — the shape is
/// identical, and keeping it identical is what stops one mode's permission screen
/// drifting from the other's. Each maps its own state onto one [MediaCheckFailure]
/// and a handful of strings; the branching lives here.
Widget _previewCard(
  BuildContext context, {
  required MediaCheckFailure? failure,
  required String failTitle,
  required String settingsBody,
  required bool starting,
  required String startingBody,
  required bool showOff,
  required String offTitle,
  required String offBody,
  required VoidCallback onRetry,
  required Widget Function() live,
}) {
  if (failure != null) {
    final settings = failure.needsSettings;
    return _frame(
      context,
      _Message(
        icon: settings ? Icons.lock_outline_rounded : Icons.videocam_off_outlined,
        title: settings ? 'Permission needed' : failTitle,
        body: settings ? settingsBody : failure.message,
        action: settings ? null : ('Try again', onRetry),
      ),
    );
  }

  if (starting) {
    return _frame(
      context,
      _Message(
        icon: Icons.hourglass_empty_rounded,
        title: 'Starting',
        body: startingBody,
      ),
    );
  }

  if (showOff) {
    return _frame(
      context,
      _Message(
        icon: Icons.videocam_off_outlined,
        title: offTitle,
        body: offBody,
      ),
    );
  }

  return _frame(context, live());
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final act = action;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(kTextGutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: t.faint),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: t.mutedForeground),
            ),
            if (act != null) ...[
              const SizedBox(height: 14),
              TextButton(onPressed: act.$2, child: Text(act.$1)),
            ],
          ],
        ),
      ),
    );
  }
}

/// The microphone status, as a light beside a line of words.
///
/// Two shapes behind one widget, picked by whether a live level is available:
///
///  - **Device mode** passes [hearing] — there is a real meter — so this is a
///    light that comes on when it hears you: live and picking you up (green), live
///    and quiet (grey, "say something"), or muted. The same decision the call's
///    speaking ring makes drives the colour, so a mic that lights
///    [GatherTokens.ok] green here is a mic the room will see light up too.
///  - **Call-pipeline mode** passes `null` — WebRTC gives no local level without a
///    connection, and the loopback that faked one is what froze this screen — so
///    it is honest about what it knows: live (green) or muted, no quiet state.
///
/// Either way, muted says so in words, because a dark light with no explanation
/// reads as a broken one.
class _MicStatus extends StatelessWidget {
  const _MicStatus({required this.live, this.hearing});

  final bool live;

  /// The live meter's answer, or null when there is no meter (call-pipeline). A
  /// null reads as "working" for the colour, so a connected-but-level-less mic is
  /// green rather than stuck on the quiet grey.
  final bool? hearing;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final metered = hearing != null;
    final working = live && (hearing ?? true);
    final colour = !live
        ? (metered ? t.faint : t.mutedForeground)
        : (working ? t.ok : t.mutedForeground);
    final label = !live
        ? 'Microphone muted'
        : metered
            ? (hearing!
                ? 'We can hear you'
                : 'Say something — the light comes on when it hears you')
            : 'Microphone is live — capturing through the call engine';

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: working ? t.ok.withValues(alpha: 0.15) : t.secondary,
            ),
            child: Icon(
              live ? Icons.mic_rounded : Icons.mic_off_rounded,
              size: 22,
              color: colour,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: TextStyle(fontSize: 13, color: colour)),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.micLive,
    required this.videoOn,
    required this.frontCamera,
    required this.hasCamera,
    required this.canSwitch,
    required this.onToggleMic,
    required this.onToggleVideo,
    required this.onSwitchCamera,
    required this.onToggleSpeaker,
    required this.onPlayTone,
    this.speaker = false,
  });

  final bool micLive;
  final bool videoOn;

  /// Which way the test sound goes. Only read when [onToggleSpeaker] is non-null;
  /// the call pipeline forces no route, hides the toggle, and leaves this at its
  /// unused default.
  final bool speaker;
  final bool frontCamera;
  final bool hasCamera;
  final bool canSwitch;
  final VoidCallback onToggleMic;
  final VoidCallback onToggleVideo;
  final VoidCallback onSwitchCamera;
  final VoidCallback? onToggleSpeaker;

  /// A tap plays a chime out the current route. Null hides the button — the
  /// call pipeline can't play a chime without reconfiguring the AVAudioSession
  /// the engine owns (the old category-thrash), so it leaves the speaker test
  /// to Device mode.
  final VoidCallback? onPlayTone;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    // The label names where a tap sends the sound, not where it is now: the
    // button is a switch, and the brand tint already says when the speaker is
    // the live one.
    final routeLabel = speaker ? 'Earpiece' : 'Speaker';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _Toggle(
              on: micLive,
              onIcon: Icons.mic_rounded,
              offIcon: Icons.mic_off_rounded,
              label: micLive ? 'Mic on' : 'Muted',
              onTap: onToggleMic,
            ),
            _Toggle(
              on: videoOn,
              onIcon: Icons.videocam_rounded,
              offIcon: Icons.videocam_off_rounded,
              label: videoOn ? 'Camera on' : 'Camera off',
              onTap: hasCamera ? onToggleVideo : null,
            ),
            _Toggle(
              on: true,
              onIcon: Icons.cameraswitch_rounded,
              offIcon: Icons.cameraswitch_rounded,
              label: frontCamera ? 'Front' : 'Back',
              onTap: canSwitch ? onSwitchCamera : null,
              tint: t.mutedForeground,
            ),
            // Where the test sound comes out: the loudspeaker wears the brand
            // like a live control, the earpiece the resting grey. Absent when
            // no route is forced (the call pipeline).
            if (onToggleSpeaker != null)
              _Toggle(
                on: speaker,
                onIcon: speaker ? Icons.volume_up_rounded : Icons.phone_in_talk_rounded,
                offIcon: speaker ? Icons.volume_up_rounded : Icons.phone_in_talk_rounded,
                label: routeLabel,
                tint: speaker ? t.brand : t.mutedForeground,
                onTap: onToggleSpeaker,
              ),
          ],
        ),
        if (onPlayTone != null) ...[
          const SizedBox(height: 8),
          // Hear it for yourself: a short chime out of whatever the route above
          // says, so the speaker test needs no second person on the line.
          TextButton.icon(
            onPressed: onPlayTone,
            icon: const Icon(Icons.graphic_eq_rounded, size: 18),
            label: const Text('Play a test sound'),
          ),
        ],
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.on,
    required this.onIcon,
    required this.offIcon,
    required this.label,
    required this.onTap,
    this.tint,
  });

  final bool on;
  final IconData onIcon;
  final IconData offIcon;
  final String label;
  final VoidCallback? onTap;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final enabled = onTap != null;
    final colour = !enabled ? t.faint : (tint ?? (on ? t.brand : t.danger));

    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(t.radius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(on ? onIcon : offIcon, color: colour, size: 26),
              const SizedBox(height: 6),
              Text(label, style: TextStyle(fontSize: 12, color: t.mutedForeground)),
            ],
          ),
        ),
      ),
    );
  }
}
