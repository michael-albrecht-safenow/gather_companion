/// The things you can do about yourself, gathered into one island over the floor.
///
/// Gather's own client puts these across the bottom of the office — who you are,
/// whether you are available, your microphone, your camera, and a row of
/// reactions — and that is the right place for them, because they are all
/// answers to "what am I doing in this room" rather than places to go. The rail
/// underneath is navigation; this is participation, and keeping the two as
/// separate islands is what stops a person hunting for the mute button among the
/// tabs.
///
/// ## What is here, and what is deliberately not
///
/// Gather's bar also carries a screen-share button. It does not survive the trip
/// to a phone: there is nothing on a phone worth sharing a window of.
///
/// Gather's door does survive, and it is **one** door, as it is on the desktop.
/// This bar briefly had three ways out — a desk button, a *leave* button beside it
/// while you were in a conversation, and a third meaning for that leave button on
/// the call screen — and three buttons for one intention is two too many. There is
/// one door now, [_doorButton], drawn with the `logout` glyph — a door with the
/// way out marked on it — and what it does depends on
/// where you are: in a conversation it leaves it and walks you home; away from
/// your desk it walks you home; at your desk with nobody around it is dim, because
/// you are already where the door leads. It never leaves the *space*: the socket
/// this app holds **is** the presence everything else in it reports, so a door out
/// of the space would switch the product off.
///
/// The two chevrons beside Gather's microphone and camera open device pickers.
/// A phone has one microphone and two cameras, and the second is a button rather
/// than a menu, so those are gone too.
///
/// ## What red means, and the one control that is dimmed
///
/// Red used to be the mute state: a crossed-out microphone painted in
/// [GatherTokens.danger]. It is not any more, because the glyph had already said
/// it. `mic_off` *is* a microphone with a line through it — the shape carries the
/// state — and painting it red as well spent the bar's one alarming colour on the
/// most ordinary thing a person does in a meeting. Off is now the same grey every
/// other resting icon is, and [GatherTokens.brand] marks the two controls that are
/// actually broadcasting.
///
/// Red is spent instead on the door, where it says something no glyph can: there
/// is somewhere you are not — you are in a conversation, or you are not where the
/// office has you filed. The D-pad's rule — pressed is a step of opacity, never a
/// different paint — is about a control being *pushed*, and still holds for the
/// press itself.
///
/// The door is also the one control here that is ever greyed out, against the
/// standing rule that a button which can do nothing is absent rather than dimmed.
/// The rule is right for the others: the camera flip appears when there is a
/// camera to flip and is gone when there is not, and its absence costs the reader
/// nothing. Being at your own desk is different. It is the answer to "where am I",
/// it is the state a person opens the bar to check, and a button that has vanished
/// cannot tell anybody they have arrived. So the door is absent only when Gather
/// has given you no desk *and* there is no conversation to leave, and dim when you
/// are already sitting at your desk with nobody around you.
library;

import 'package:flutter/material.dart';
// For [RenderProxyBox] — `material.dart` does not re-export the render tree, and
// [_NoWidthOpinion] needs one box that measures itself differently.
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../src/app_state.dart';
import '../src/media/media_engine.dart';
import '../theme/gather_theme.dart';
import 'call_screen.dart';
import 'person_avatar.dart';
import 'status_sheet.dart';

/// The eight, in Gather's own order.
///
/// The codepoints matter and are not decorative: two of these carry a variation
/// selector (`❤️` is `U+2764 U+FE0F`, `👍️` is `U+1F44D U+FE0F`) and Gather echoes
/// the string back to every other client exactly as sent. Dropping the selector
/// produces a different character, which renders as a dingbat heart on somebody
/// else's screen rather than the red one they expected.
const _emotes = ['👋', '❤️', '🎉', '👍️', '🤣', '👏', '💯', '🔥'];

/// The controls' row. The nav row below is taller — it carries labels under its
/// icons — but both are rows of the same island, which is what keeps them one
/// system.
const double _barHeight = 56;

/// How much taller the dock is while the office is carrying these.
///
/// The shell already hands every tab the rail's height as bottom padding, which
/// is why the D-pad and the legend needed no changes to clear it. This is the
/// same trick one layer in: the map tab gets this row on top, so its overlays
/// lift above the whole dock without knowing it has more than one row.
///
/// The row plus the hairline under it, and no gap — the two rows are attached.
/// The reaction tray is not counted: it is up for about a second, and reserving
/// permanent floor for it would cost the office a strip all day.
const double kControlBarInset = _barHeight + 1;

/// The room a screen leaves at the bottom for a [DockIsland] holding only the
/// control row — the call screen's version of `kRailInset`, built the same way:
/// the row, the island's border, the gap under it and the same eight of air.
const double kControlDockInset = _barHeight + 2 + kRailGap + 8;

/// The floating island the dock's rows sit in.
///
/// Shared by the shell, which stacks the controls over the navigation, and by the
/// call screen, which carries the controls alone. One island and not two lookalikes,
/// so the bar you mute from on the faces is visibly the bar you mute from on the map.
///
/// ## Why the whole island is one width
///
/// [IntrinsicWidth] over a stretched column: the column takes the width of its
/// widest row, and every other row is stretched to match. Left to themselves the rows
/// would be different widths and the join would have a visible step in it.
/// [kRailMinWidth] puts a floor under that, so the island does not lurch sideways as
/// rows come and go.
///
/// ## Why it grows and shrinks rather than sliding
///
/// A row of one object leaving is honestly drawn as the object closing up over it.
/// [AnimatedSize] anchored at the bottom does that, and the reaction tray, which is a
/// row too, pushes the island upwards rather than floating over it.
class DockIsland extends StatelessWidget {
  const DockIsland({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: kRailGap),
        child: Center(
          child: Container(
            decoration: BoxDecoration(
              // Solid, unlike the legend it otherwise copies. The legend is a
              // hint that sits over floor and is allowed to let the floor
              // through; this is navigation, it sits wherever the office
              // happens to be busiest, and at 0.92 the desks and chairs came
              // through it and read as dirt on the glass.
              color: t.card,
              border: Border.all(color: t.border),
              borderRadius: BorderRadius.circular(t.radius + 10),
            ),
            // So a row on its way out is clipped by the island's own corners
            // rather than spilling past them mid-animation.
            clipBehavior: Clip.antiAlias,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              child: IntrinsicWidth(
                // Inside the IntrinsicWidth, so a control row that genuinely
                // outgrows the floor can still widen the whole island.
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: kRailMinWidth),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ControlBar extends StatefulWidget {
  const ControlBar({super.key, required this.state, this.onCallScreen = false});

  final AppState state;

  /// Whether this bar is already sitting on the faces, where a button leading to
  /// them would open the screen on top of itself.
  final bool onCallScreen;

  @override
  State<ControlBar> createState() => _ControlBarState();
}

class _ControlBarState extends State<ControlBar> {
  bool _tray = false;

  /// Puts a failure in front of the person, in the app's one existing way.
  ///
  /// Every action here returns null or a sentence — the contract `setPartyMode`
  /// set — so success is silent and only a refusal ever interrupts.
  Future<void> _run(Future<String?> Function() action) async {
    final failed = await action();
    if (!mounted || failed == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(failed)));
  }

  /// What the door does: leave the conversation, head back to your desk, and
  /// close the faces if they were open. Each only when there is one to do.
  ///
  /// Leaving and walking are one press because leaving alone is not actually a
  /// way out. Gather forms conversations by proximity, so stepping out of one
  /// while still standing in the middle of it is an invitation to be put straight
  /// back in — `leaveCluster` buys a few seconds, not a departure. Walking away is
  /// what ends it, and your own desk is the one place the app already knows how to
  /// send you. That is also what the desktop's door does, and one door doing the
  /// same thing in both clients is worth more than a phone-only distinction
  /// between leaving and going home.
  ///
  /// The walk is not conditional on the leave having worked. If Gather refused it,
  /// the walk is still the better answer — and arriving at your desk leaves the
  /// cluster by itself. Without a desk, the leave is all there is to do, and
  /// without a conversation the walk is.
  ///
  /// Popping last, and only on the way out of the call screen, so the map is the
  /// thing on screen while the walk happens — which is the point of asking for it.
  /// The desk walk raises a follow request that the office claims when it appears,
  /// so the camera rides along even though it was not built when the button was
  /// pressed.
  Future<void> _leave() async {
    final state = widget.state;
    final navigator = Navigator.of(context);

    if (state.inHuddle) {
      await _run(state.leaveHuddle);
      if (!mounted) return;
    }
    if (state.myDesk != null && !state.atMyDesk) {
      await _run(state.goToMyDesk);
      if (!mounted) return;
    }
    if (widget.onCallScreen && navigator.canPop()) navigator.pop();
  }

  void _toggleTray() {
    HapticFeedback.selectionClick();
    setState(() => _tray = !_tray);
  }

  /// Sends one and leaves the tray open.
  ///
  /// It used to close behind every pick, which made a second reaction — the 👏👏👏
  /// people actually send — a reopen per clap. The tray is a toggle now: open until
  /// the React button is pressed again.
  ///
  /// `sendEmoteLocalFirst`, so it appears on your own tile at the moment of the
  /// press. Gather does echo our own emotes back to us, but over the network,
  /// and the one reaction that should never wait for a round trip is the one
  /// whose button is still under your thumb.
  Future<void> _send(String emote) async {
    HapticFeedback.selectionClick();
    await _run(() => widget.state.sendEmoteLocalFirst(emote));
  }

  /// The one door out, in the four states it has.
  ///
  /// Gather's own toolbar button, transcribed — the shape of it is not ours:
  ///
  /// ```js
  /// onClick: hasDesk ? () => moveSpaceUserToDesk() : () => startGuidedClaimDeskFlow(),
  /// disabled: currentUserAtDesk
  /// ```
  ///
  /// with the conversation folded in, so that the same door reads *leave* while
  /// you are in one. What it says is what it will do: leave the conversation,
  /// walk back to your desk, or nothing because you are already there.
  ///
  /// The desktop offers to *claim* a desk when you have none. This cannot: claiming
  /// one is a guided flow over a map you cannot edit from a phone. So with no desk
  /// the door exists only while there is a conversation to leave — dimming it would
  /// tell somebody who has never had a desk that they are sitting at it.
  Widget _doorButton(BuildContext context, AppState state) {
    final hasDesk = state.myDesk != null;
    final inHuddle = state.inHuddle;
    if (!hasDesk && !inHuddle) return const SizedBox.shrink();
    final home = hasDesk && state.atMyDesk && !inHuddle;

    // The hairline travels with the door rather than sitting in the bar's own
    // row, so it exists exactly when the door does: a rule with nothing after it
    // would be a group with no members.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Rule(),
        _BarButton(
          icon: Icons.logout_rounded,
          label: inHuddle
              ? 'Leave the conversation'
              : home
                  ? 'You are at your desk'
                  : 'Back to my desk',
          // Red whenever pressing it goes somewhere. It was briefly two buttons
          // and two reds — one for the desk, one for the conversation — and
          // folding them settles which red the bar has: the door's.
          tint: home ? null : context.tokens.danger,
          onTap: home ? null : _leave,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final state = widget.state;
    final call = state.call;

    return Column(
      mainAxisSize: MainAxisSize.min,
      // The dock stretches this to the island's width; this passes that width on
      // to both rows, so the tray's eight reactions and the controls above the
      // navigation all divide the same span instead of each finding their own.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A row of the same island rather than a thing floating over it: the tray
        // pushes the dock upwards when it opens and lets it back down when the
        // React button closes it, so nothing ever overlaps anything.
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: _tray ? _Tray(onPick: _send) : const SizedBox(width: double.infinity),
        ),
        SizedBox(
          height: _barHeight,
          child: Row(
            // Spread across the dock's width rather than bunched at the left, so
            // the row reads as the island's contents and not as a strip taped to
            // one end of it.
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _SelfButton(state: state, onTap: () => showStatusSheet(context, state)),
              const _Rule(),
              _BarButton(
                icon: call.micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
                label: call.micOn ? 'Mute' : 'Unmute',
                // Brand while it is live, and the bar's ordinary resting grey once
                // it is not. See the header: the crossed-out glyph is the state.
                tint: call.micOn ? t.brand : t.mutedForeground,
                onTap: () => _run(() => state.setMicOn(!call.micOn)),
              ),
              _BarButton(
                icon: call.cameraOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                label: call.cameraOn ? 'Turn the camera off' : 'Turn the camera on',
                tint: call.cameraOn ? t.brand : t.mutedForeground,
                onTap: () => _run(() => state.setCameraOn(!call.cameraOn)),
              ),
              // Only on the faces, and only once there is a camera running to flip.
              // Flipping is something you do while looking at your own picture;
              // over the map there is no picture, so the button was a guess at
              // which way the camera now faced. Absent rather than dimmed, like
              // everything else here.
              if (call.cameraOn && widget.onCallScreen)
                _BarButton(
                  icon: Icons.cameraswitch_rounded,
                  label: 'Switch camera',
                  onTap: state.switchCamera,
                ),
              // The way to your own picture while nobody else is in the call.
              // Turning the camera on and having nowhere to see it reads as the
              // camera not working, which is exactly how this was first
              // reported. In a call the banner across the top of the shell is
              // the way to the faces instead, so this goes — two doors to one
              // room, one of them in the bar you are trying to mute from.
              if (call.cameraOn && !state.inCall && !widget.onCallScreen)
                _BarButton(
                  icon: Icons.groups_rounded,
                  label: 'See your camera',
                  onTap: () => openCallScreen(context, state),
                ),
              // The sound's way out. Present only while there is sound to route —
              // somebody else in the call, or your own hardware live. The
              // loudspeaker is the resting-on-a-desk default and wears the brand;
              // the earpiece is the ordinary grey. A headset, once it is in, owns
              // the route and the glyph, and a tap still forces the speaker over it.
              if (call.live || state.inCall)
                _BarButton(
                  icon: switch (call.audioOutput) {
                    AudioOutput.speaker => Icons.volume_up_rounded,
                    AudioOutput.earpiece => Icons.phone_in_talk_rounded,
                    AudioOutput.bluetooth => Icons.bluetooth_audio_rounded,
                    AudioOutput.wired => Icons.headset_rounded,
                  },
                  label: switch (call.audioOutput) {
                    AudioOutput.speaker => 'Use the earpiece',
                    AudioOutput.earpiece => 'Use the speaker',
                    AudioOutput.bluetooth => 'On Bluetooth — tap for the speaker',
                    AudioOutput.wired => 'On headphones — tap for the speaker',
                  },
                  tint: call.audioOutput == AudioOutput.speaker
                      ? t.brand
                      : t.mutedForeground,
                  onTap: () => _run(() =>
                      state.setSpeakerOn(call.audioOutput != AudioOutput.speaker)),
                ),
              const _Rule(),
              _BarButton(
                icon: Icons.add_reaction_outlined,
                label: 'React',
                on: _tray,
                onTap: _toggleTray,
              ),
              // Raising a hand is a meeting gesture, so it sits by React and shows
              // only while there is a meeting to raise it in — absent over the map
              // and in a call of one, like everything else here with nothing to act
              // on. `on` carries the raised state the same way Mute carries live:
              // the amber badge on the tile is the loud signal, this is the switch.
              // No `_run`: the hand is local-first and reports nothing to surface.
              if (state.inCall)
                _BarButton(
                  icon: state.myHandRaised
                      ? Icons.front_hand
                      : Icons.front_hand_outlined,
                  label: state.myHandRaised ? 'Lower hand' : 'Raise hand',
                  on: state.myHandRaised,
                  onTap: () => state.toggleHandRaised(),
                ),
              // Its own listener. Walking is deliberately not a `notifyListeners`
              // — movement must not wake the whole tree — and this is the one
              // control in the bar whose answer changes as you walk. Without it the
              // button stays red under the thumb that pressed it until something
              // unrelated happens to rebuild the bar. A conversation starting or
              // ending does notify, so that half of its answer needs no listener.
              ListenableBuilder(
                listenable: state.positions,
                builder: (context, _) => _doorButton(context, state),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// You: your own profile picture, with the dot that says how available you are —
/// the same dot the map draws over your head.
///
/// Gather shows your live camera here instead. This does not, and the reason is
/// not laziness: the preview would have to reach past [Call] for a `MediaStream`
/// and drag the WebRTC plugin into the widget layer. The picture you set is the
/// better thing to show anyway, because it is there before the camera is on and
/// stays there after it goes off.
class _SelfButton extends StatelessWidget {
  const _SelfButton({required this.state, required this.onTap});

  final AppState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final me = state.mePerson;
    final label = me?.label ?? 'You';
    final id = me?.id ?? 'me';

    return Semantics(
      button: true,
      label: 'You — ${availabilityLabel(state.myAvailability ?? 'Active')}. '
          'Set your status',
      child: Tooltip(
        message: 'Your status',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(t.radius + 4),
            child: SizedBox(
              width: 48,
              height: 44,
              child: Center(
                child: PersonAvatar(
                  id: id,
                  label: label,
                  photoUrl: state.photoUrlFor(id),
                  size: 34,
                  availability: state.myAvailability ?? 'Active',
                  // Ringed in the dock's own fill, so the dot reads as sitting on
                  // the picture rather than cut into it.
                  dotRing: t.card,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One control: a glyph on a plate that fills in while it is on.
///
/// The same plate as the rail's destinations, one radius step inside the island
/// that holds it, so the two bars are visibly the same furniture.
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.on = false,
    this.tint,
  });

  final IconData icon;
  final String label;

  /// Null for a control that is present but cannot be pressed — see the header for
  /// why exactly one of these is allowed to exist.
  final VoidCallback? onTap;

  /// Whether this is a control that is currently *in* a state, as opposed to one
  /// that merely does something when pressed.
  final bool on;

  /// Overrides the colour entirely, for the controls that are painted by what they
  /// are reporting rather than by whether they are pressed.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Concentric with the island, like the nav plates below: the dock's corner
    // minus the inset to here. See `_NavItem` in home_shell.dart.
    final radius = BorderRadius.circular(t.radius + 4);
    // Dimmed rather than recoloured, so a control that has gone quiet is plainly
    // the same control. `tint` is ignored here on purpose: red means "go back", and
    // a faded red would read as a warning being whispered rather than withdrawn.
    final colour = onTap == null
        ? t.mutedForeground.withValues(alpha: 0.38)
        : tint ?? (on ? t.brand : t.mutedForeground);

    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            // A null callback is what makes the plate inert: no splash, no
            // highlight, no tap.
            onTap: onTap,
            borderRadius: radius,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: 46,
              height: 44,
              decoration: BoxDecoration(
                color: on ? t.secondary : Colors.transparent,
                borderRadius: radius,
              ),
              child: TweenAnimationBuilder<Color?>(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                tween: ColorTween(end: colour),
                builder: (context, colour, _) => Icon(icon, size: 22, color: colour),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The hairline between groups: "me", "my hardware", "the room", and the door out
/// of it. The last one is drawn by [_ControlBarState._doorButton] itself, so it
/// comes and goes with the door.
class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 24,
        margin: const EdgeInsets.symmetric(horizontal: 5),
        color: context.tokens.border,
      );
}

/// The eight reactions, as the dock's top row.
///
/// Undecorated: the dock paints the island, and a second bordered box inside it
/// would read as a dialog sitting on a bar rather than as the bar having grown a
/// row.
///
/// ## Why the eight divide the width instead of setting it
///
/// The whole dock is sized by an [IntrinsicWidth] over its rows, so anything with
/// an opinion about its own width can move the island. Eight 40-point reactions
/// have a very firm one — 328 points, eight past the [kRailMinWidth] floor the two
/// permanent rows settle on — and the island grew by those eight points every time
/// the tray opened and shrank back every time a reaction was picked. Nothing was
/// wrong with the tray; the dock was being asked a question by a row that is only
/// up for a second.
///
/// So the tray answers zero when asked how wide it wants to be ([_NoWidthOpinion])
/// and divides whatever it is handed between the eight ([Expanded]). The closed
/// tray already worked this way by accident: a childless `SizedBox(width:
/// double.infinity)` reports an intrinsic width of zero, which is exactly the
/// "fill it, don't set it" this needed all along.
class _Tray extends StatelessWidget {
  const _Tray({required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return _NoWidthOpinion(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.border)),
        ),
        child: Row(
          children: [
            for (final emote in _emotes)
              Expanded(
                child: Semantics(
                  button: true,
                  label: 'Send $emote',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => onPick(emote),
                      borderRadius: BorderRadius.circular(t.radius + 4),
                      child: SizedBox(
                        height: 40,
                        child: Center(
                          child: Text(emote, style: const TextStyle(fontSize: 21)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A child that takes the width it is given and asks for none of its own.
///
/// [RenderProxyBox] passes layout, painting and hit-testing straight through and
/// forwards every intrinsic measurement to the child; this overrides the two
/// horizontal ones to zero and leaves the vertical pair alone, because the dock
/// genuinely does need the tray's height to animate to. See [_Tray].
class _NoWidthOpinion extends SingleChildRenderObjectWidget {
  const _NoWidthOpinion({required Widget super.child});

  @override
  RenderProxyBox createRenderObject(BuildContext context) => _RenderNoWidthOpinion();
}

class _RenderNoWidthOpinion extends RenderProxyBox {
  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;
}
