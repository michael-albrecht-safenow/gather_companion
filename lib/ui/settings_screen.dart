/// Everything the app can tell you about itself, and the two switches it owns.
///
/// This was a `PopupMenuButton` with two items hidden behind an overflow icon on
/// the feed. That was the right size for it when there was one screen and no
/// room, but a menu is a bad place for anything you might want to *read* — it
/// closes when you look away, and it can only hold verbs. The state that
/// actually matters here is nouns: whether Gather is connected, which space you
/// are in, which computer is paired, whether that computer can still wake the
/// app for a notification. None of that fitted in a menu, so none of it was
/// shown anywhere.
///
/// Nothing on this screen is a preference. The two real preferences the app has
/// — `Notifier.notifyOnFollow` and `Notifier.notifyOnGather` — are deliberately
/// absent, because they are plain fields with no persistence behind them: a
/// switch wired to one would forget itself on the next launch, which is worse
/// than not offering it. Persisting them is the change that earns them a row.
library;

import 'package:flutter/material.dart';

import '../src/app_state.dart';
import '../src/link_status.dart';
import '../src/push.dart';
import '../theme/gather_theme.dart';
import 'call_screen.dart';
import 'gameboy_theme.dart';
import 'media_check_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.state, required this.onUnpair});

  final AppState state;
  final VoidCallback onUnpair;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final link = state.link;
    final space = state.spaceName;

    // Read *above* the `Scaffold`, exactly as the activity tab does and for the
    // same reason: the shell puts the dock's height into the bottom padding, and
    // `Scaffold` is entitled to take that off its body — so a `SafeArea` inside
    // one adds nothing at all. Read there, the last row of this list sat under
    // the dock and could not be tapped, which is how a test caught it.
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    // Four states, four sentences. `needsPairing` is kept apart from `retrying`
    // for the same reason the link strip keeps them apart: one asks you to wait
    // and the other asks you to act.
    final (status, detail, tint) = link.needsPairing
        ? ('Signed out', 'Gather signed this device out. Pair again to reconnect.', t.danger)
        : switch (link.state) {
            LinkState.live => ('Connected', space == null ? 'Talking to Gather.' : 'To $space.', t.ok),
            LinkState.connecting => ('Connecting', 'Opening a connection to Gather.', t.warn),
            LinkState.retrying => ('Reconnecting', link.detail ?? 'The connection dropped. Trying again.', t.danger),
            LinkState.offline => ('No connection', link.detail ?? 'No network. Waiting for a connection.', t.danger),
            LinkState.idle => ('Not connected', 'Nothing is listening to Gather right now.', t.faint),
          };

    // What the computer can actually do for us, as last *tested* rather than as
    // inferred from whether an address happens to be stored. Six answers because
    // six different things go wrong and they are fixed in six different places;
    // one boolean sent people looking at their network when the real problem was a
    // missing service account, or at Firebase when the phone had simply never
    // handed its token over.
    //
    // The computer name stays untinted for every degraded state: `tint` colours the
    // whole row, and an orange hostname reads as the computer being the wrong one
    // rather than as it being out of reach. The sentence carries that.
    final computer = state.bridgeName ?? 'This Mac';
    final (wakeTitle, wakeDetail, wakeTint, wakeIcon) = switch (state.pushReach.reach) {
      PushReach.pending => (computer, 'Checking whether it can still reach you…', null, Icons.computer_rounded),
      PushReach.armed => (computer, 'Can wake this app when something happens.', t.ok, Icons.computer_rounded),
      PushReach.unreachable => (computer, "Can't reach it right now. Notifications wait until it is back.", null, Icons.computer_rounded),
      PushReach.noCredential => (computer, 'Reachable, but it has no push credentials yet. Run `gather-app-bridge push setup` on it.', null, Icons.key_off_rounded),
      PushReach.denied => (computer, 'Notifications are turned off for this app in iOS Settings.', null, Icons.notifications_off_rounded),
      PushReach.noToken => (computer, 'iOS has not issued a push token, so nothing can wake the app.', null, Icons.notifications_off_rounded),
      // The state this whole card exists to stop misreporting. It used to say
      // "Unreachable", which sent you to look at a computer that was fine.
      PushReach.unpaired => ('No computer paired', "Notifications can't reach you while the app is closed. Pair again from the QR code.", t.warn, Icons.phonelink_off_rounded),
    };

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(backgroundColor: t.background, title: const Text('Settings'), titleTextStyle: Theme.of(context).textTheme.titleLarge),
      // Not a `SafeArea`: see [bottomInset] above. The list runs under the dock
      // and the padding below is what lets the last row be scrolled clear of it.
      //
      // A live call reserves a strip above the settings rather than floating over
      // them — the list stays fully readable while a call is on.
      body: Column(children: [
        CallBannerHeader(state: state),
        Expanded(
          child: ListView(
            padding: EdgeInsets.only(bottom: bottomInset + 24),
            children: [
          const _SectionLabel('Gather'),
          _Card(
            children: [
              _Row(icon: link.isLive ? Icons.cloud_done_rounded : Icons.cloud_off_rounded, tint: tint, title: status, subtitle: detail),
              _Row(icon: Icons.refresh_rounded, title: 'Reconnect', subtitle: 'Drop the connection and open it again.', onTap: state.reconnect),
              _PartyRow(state: state),
            ],
          ),
          SizedBox(height: 8),
          const _SectionLabel('This phone'),
          _Card(
            children: [
              _Row(
                icon: Icons.mic_rounded,
                title: 'Mic, camera & sound',
                subtitle: 'Check they work before your next meeting.',
                goes: true,
                // Pushed, never a tab: the check opens the hardware in
                // `initState` and holds it until it is disposed, so it has to be
                // a screen you leave rather than one that sits behind another.
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MediaCheckScreen(state: state))),
              ),
            ],
          ),
          SizedBox(height: 8),
          const _SectionLabel('Appearance'),
          _Card(
            children: [
              _GameboyRow(state: state),
              // Only while the handheld is on — the theme has nothing to skin when
              // the office wears its normal interface, so an always-present row
              // would be an orphan control.
              if (state.gameboyMode) _GameboyThemeRow(state: state),
              _SoundEffectsRow(state: state),
            ],
          ),
          SizedBox(height: 8),
          // Not 'Paired computer': that asserted a pairing as the *label*, above a
          // sentence that then had to argue with it. The card is about what the
          // computer's one remaining job gets you.
          const _SectionLabel('Push notifications'),
          _Card(
            children: [_Row(icon: wakeIcon, title: wakeTitle, tint: wakeTint, subtitle: wakeDetail)],
          ),
          SizedBox(height: 8),
          // Last, alone, and red: the way out of the app does not share a card
          // with anything you might tap on the way past.
          const _SectionLabel('Connection'),
          _Card(
            children: [_Row(icon: Icons.link_off_rounded, title: 'Forget this computer', subtitle: 'Sign out of Gather.', tint: t.danger, onTap: onUnpair)],
          ),
            ],
          ),
        ),
      ]),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      // Text outside a card indents to `kTextGutter` so it lines up with the
      // carded content rather than with the screen edge.
      padding: const EdgeInsets.fromLTRB(kTextGutter, 8, kTextGutter, 8),
      // The same voice as the activity tab's day headers — one screen away is
      // too close for the app to have two ways of labelling a section.
      child: Text(
        text.toUpperCase(),
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: t.mutedForeground),
      ),
    );
  }
}

/// The same surface the media check draws its preview on: card fill, hairline
/// border, `t.radius`, clipped so the rows' ink stays inside the corners.
class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: kGutter),
      decoration: BoxDecoration(
        color: t.card,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(t.radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[if (i > 0) Divider(color: t.border, height: 1, thickness: 1), children[i]],
        ],
      ),
    );
  }
}

/// One line of the list, in three kinds: a fact, an action, and a way out of
/// here.
///
/// The chevron marks only the third. It was on every tappable row first, which
/// put one next to "Reconnect" and one next to "Forget this computer" — neither
/// of which goes anywhere, and a chevron is a promise of somewhere to go. The
/// verbs carry those two on their own.
class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, required this.subtitle, this.onTap, this.tint, this.goes = false, this.trailing});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Color? tint;

  /// Whether the tap opens another screen, rather than doing something here.
  final bool goes;

  /// A control at the end of the row — the party switch is the only one so far.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final colour = tint ?? t.mutedForeground;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(icon, size: 20, color: colour),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: tint ?? t.foreground),
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle, style: TextStyle(fontSize: 12.5, height: 1.35, color: t.faint)),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
              if (goes) ...[const SizedBox(width: 8), Icon(Icons.chevron_right_rounded, size: 20, color: t.faint)],
            ],
          ),
        ),
      ),
    );
  }
}

/// Party mode, as a row of the Gather card: the one thing on this screen that
/// *does* something to the space rather than reporting on it.
///
/// It renders [AppState.partyMode] — the snapshot — never a local flag. The
/// bridge stops the party by itself: on its own 15-minute timer, when it loses
/// Gather, when the daemon exits. A switch holding local state would keep
/// glowing through all three. It lived on the activity tab as a spinning
/// gradient card for a while; a switch is what it always was, and this screen
/// is where the app keeps its switches.
class _PartyRow extends StatelessWidget {
  const _PartyRow({required this.state});

  final AppState state;

  Future<void> _toggle(BuildContext context) async {
    if (state.partyPending) return;
    // Both captured before the await: the row may be gone by the time the
    // bridge answers.
    final messenger = ScaffoldMessenger.of(context);
    // Lifted over the nav rail by hand. A floating snackbar measures itself
    // against the bottom of the nearest `Scaffold`, and this screen's one knows
    // nothing about a rail floating above it in the shell — so the one message
    // this row can show would appear underneath it.
    final margin = EdgeInsets.fromLTRB(kGutter, 0, kGutter, kRailInset + MediaQuery.paddingOf(context).bottom + 8);
    final error = await state.setPartyMode(!state.partyMode);
    if (error == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(error), margin: margin));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final on = state.partyMode;
    final party = state.party;

    // While it is hopping, a reason means it is *not* hopping this moment — a
    // corner it has been backed into rather than a fault. Standing still is the
    // correct behaviour there, so it is reported plainly instead of as an error.
    final subtitle = switch ((on, party.detail)) {
      (true, final String why) => why,
      (true, _) when party.hops > 0 => 'Hopping four times a second — ${party.hops} hops',
      (true, _) => 'Hopping four times a second',
      (false, final String why) => why,
      _ => 'Teleport around the map!',
    };

    return Semantics(
      toggled: on,
      child: _Row(
        icon: Icons.celebration_rounded,
        // On is a state, and states are allowed a colour — the media check's
        // toggles set this precedent.
        tint: on ? t.brand : null,
        title: 'Party mode',
        subtitle: subtitle,
        onTap: () => _toggle(context),
        trailing: _PartySwitch(on: on, pending: state.partyPending),
      ),
    );
  }
}

/// Gameboy mode, as a row of the Appearance card. Unlike party mode it is a pure
/// look-and-input switch — it changes which controls the office tab wears, never
/// the space — so it owns a plain bool on [AppState] and has no refusal to show.
class _GameboyRow extends StatelessWidget {
  const _GameboyRow({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final on = state.gameboyMode;

    return Semantics(
      toggled: on,
      child: _Row(
        icon: Icons.videogame_asset_rounded,
        tint: on ? t.brand : null,
        title: 'Gameboy mode',
        subtitle: on ? 'The office, played as a handheld.' : 'Play the office like a handheld.',
        onTap: () => state.setGameboyMode(!on),
        trailing: _PartySwitch(on: on, pending: false),
      ),
    );
  }
}

/// The hardware theme picker, below Gameboy mode in the Appearance card and shown
/// only while the mode is on. A pure look choice — it skins the handheld's plastic
/// and nothing else — so like the mode above it there is no refusal to show; a tap
/// on a thumbnail sets the theme at once.
///
/// Laid out as a header line that names the one you are on, over a full-width
/// horizontal strip of handheld thumbnails. A single colour swatch could not say
/// what a theme *is* — the whole point is the moulded shell — so each entry is a
/// little picture of the handheld in that plastic, and the strip scrolls because
/// more skins are coming than a row would hold.
class _GameboyThemeRow extends StatelessWidget {
  const _GameboyThemeRow({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final active = themeById(state.gameboyTheme);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The same left column as a `_Row`, minus the tap target — the strip below
        // is the control, so this line only titles the choice and names the pick.
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          child: Row(
            children: [
              Icon(Icons.palette_rounded, size: 20, color: t.mutedForeground),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Theme',
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: t.foreground)),
                    const SizedBox(height: 2),
                    Text('The handheld in ${active.label}.',
                        style: TextStyle(fontSize: 12.5, height: 1.35, color: t.faint)),
                  ],
                ),
              ),
            ],
          ),
        ),
        _ThemeThumbnails(state: state),
        const SizedBox(height: 14),
      ],
    );
  }
}

/// The horizontal strip of theme thumbnails, one per entry in [kGameboyThemes].
/// It scrolls so the picker holds more skins than fit the card width, and bleeds
/// the first and last thumbnails to the card edges (the `14` padding matches a
/// `_Row`'s) so a half-cut thumbnail at the margin hints there is more to scroll.
class _ThemeThumbnails extends StatelessWidget {
  const _ThemeThumbnails({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final selected = state.gameboyTheme;
    return SizedBox(
      height: _ThemeThumb.totalHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: kGameboyThemes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final theme = kGameboyThemes[i];
          return _ThemeThumb(
            theme: theme,
            selected: theme.id == selected,
            onTap: () => state.setGameboyTheme(theme.id),
          );
        },
      ),
    );
  }
}

/// One handheld in the strip: a little DMG drawn in the theme's own plastic ramp,
/// its label beneath. Not a photo of the real shell — a readable caricature (body
/// gradient, dark LCD well, a hint of D-pad and buttons) so the eye reads "the
/// handheld, but blue" at a glance. The selected one wears the brand ring and a
/// bold label; the rest sit quiet.
class _ThemeThumb extends StatelessWidget {
  const _ThemeThumb({required this.theme, required this.selected, required this.onTap});

  final GameboyTheme theme;
  final bool selected;
  final VoidCallback onTap;

  static const double _w = 72;
  static const double _bodyH = 84;

  /// The strip sizes itself to the thumbnail plus its label line.
  static const double totalHeight = _bodyH + 6 + 18;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hw = theme.hardware;
    return Semantics(
      button: true,
      selected: selected,
      label: '${theme.label} theme',
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: _w,
              height: _bodyH,
              decoration: BoxDecoration(
                // The body's own two plastic values, lit from the top-left like the
                // real shell's housing gradient.
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [hw.hw600, hw.hw700],
                ),
                // The DMG's bottom-right corner is cut deeper than the rest.
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(10),
                  topRight: Radius.circular(10),
                  bottomLeft: Radius.circular(10),
                  bottomRight: Radius.circular(22),
                ),
                border: Border.all(
                  color: selected ? t.brand : t.border,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The LCD well: a near-black screen with a hairline bezel, the
                    // same dark the real shell sinks its screen into.
                    Container(
                      height: 32,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0E1012),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: hw.hw900, width: 1),
                      ),
                    ),
                    const Spacer(),
                    // A hint of the controls: a D-pad cross left, two button domes
                    // right — drawn in the moulded-dark and catch-light values so
                    // they read as parts of this shell, not stickers on it.
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _MiniDpad(color: hw.hw900),
                        Row(
                          children: [
                            _MiniKey(color: hw.hw500),
                            const SizedBox(width: 3),
                            _MiniKey(color: hw.hw500),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              theme.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? t.foreground : t.mutedForeground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The thumbnail's D-pad: a plus of two crossed bars, flat (the shell's no-blur
/// grammar), in the moulded-dark plastic value.
class _MiniDpad extends StatelessWidget {
  const _MiniDpad({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: 14,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(width: 14, height: 5, color: color),
          Container(width: 5, height: 14, color: color),
        ],
      ),
    );
  }
}

/// A thumbnail's A/B button: a small round dome in the catch-light value.
class _MiniKey extends StatelessWidget {
  const _MiniKey({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// The sound-effects switch, beside Gameboy mode in the Appearance card. Gates
/// the app's UI sounds — the handheld's blips, the boot jingle, the speaker-test
/// chime — and nothing else; in-call voice is never a sound effect. On by
/// default, so this is the off switch, not the opt-in.
class _SoundEffectsRow extends StatelessWidget {
  const _SoundEffectsRow({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final on = state.soundEffects;

    return Semantics(
      toggled: on,
      child: _Row(
        icon: on ? Icons.volume_up_rounded : Icons.volume_off_rounded,
        tint: on ? t.brand : null,
        title: 'Sound effects',
        subtitle: on ? 'Clicks and chimes play.' : 'The app is silent, bar calls.',
        onTap: () => state.setSoundEffects(!on),
        trailing: _PartySwitch(on: on, pending: false),
      ),
    );
  }
}

/// A switch drawn by hand rather than a `Switch`, so it speaks the card's own
/// vocabulary — brand for on, like the media check's toggles — instead of
/// Material's track colours.
class _PartySwitch extends StatelessWidget {
  const _PartySwitch({required this.on, required this.pending});

  final bool on;

  /// A tap that has not reached the computer yet. Shown as a dimmed knob so the
  /// switch reads as "heard you" rather than as finished.
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: 44,
      height: 26,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: on ? t.brand : t.secondary,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: on ? t.brand : t.border),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Opacity(
          opacity: pending ? 0.55 : 1,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(color: on ? Colors.white : t.faint, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}
