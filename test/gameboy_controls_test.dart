/// The handheld's key table and Select-menu cursor, without a widget: every row
/// of what A, B, Start and the D-pad mean, B's one-step decision (above all that
/// no first tap ever opens the mic while a wave is possible), and the cursor's
/// open/clamp/choose rules.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart' show settableAvailabilities;
import 'package:gather_companion/src/gameboy_controls.dart';

void main() {
  group('GameboyMenu', () {
    test('opens on the status row, its cursor on the status you are', () {
      final menu = GameboyMenu();
      final busy = settableAvailabilities.last;
      expect(menu.toggle(busy), isTrue);
      expect(menu.row, GameboyMenu.rowStatus);
      expect(menu.status, settableAvailabilities.indexOf(busy));
      expect(menu.choice, isA<GbChooseStatus>().having((c) => c.availability, 'availability', busy));
    });

    test('unknown status opens on Active; one not in the list on the first', () {
      final menu = GameboyMenu()..toggle(null);
      expect(settableAvailabilities[menu.status], 'Active');
      menu
        ..close()
        ..toggle('Nonsense');
      expect(menu.status, 0);
    });

    test('Select again closes; a close of a closed menu reports nothing to close', () {
      final menu = GameboyMenu()..toggle('Active');
      expect(menu.toggle('Active'), isFalse);
      expect(menu.isOpen, isFalse);
      expect(menu.close(), isFalse);
      menu.toggle('Active');
      expect(menu.close(), isTrue);
    });

    test('Up/Down walk the rows and clamp at both ends, reporting a vertical move', () {
      final menu = GameboyMenu()..toggle('Active');
      expect(menu.move('Up'), isTrue);
      expect(menu.row, 0, reason: 'clamped at the top');
      for (var i = 0; i < 20; i++) {
        menu.move('Down');
      }
      expect(menu.row, GameboyMenu.rowCount - 1, reason: 'clamped at the bottom');
      expect(menu.choice, isA<GbChooseTab>().having((c) => c.tab, 'tab', GbTab.settings));
    });

    test('Left/Right move inside the status and emote rows only, and survive leaving them', () {
      final menu = GameboyMenu()..toggle(settableAvailabilities.first);
      expect(menu.move('Right'), isFalse);
      expect(menu.status, 1);
      menu
        ..move('Down') // camera
        ..move('Right'); // inert on a single-target row
      expect(menu.status, 1);
      expect(menu.emote, 0);
      menu
        ..move('Down') // emotes
        ..move('Right')
        ..move('Right');
      expect(menu.choice, isA<GbChooseEmote>().having((c) => c.emote, 'emote', gbEmotes[2]));
      for (var i = 0; i < 20; i++) {
        menu.move('Right');
      }
      expect(menu.emote, gbEmotes.length - 1, reason: 'clamped at the end of the strip');
      menu
        ..move('Up')
        ..move('Up');
      expect(menu.status, 1, reason: 'the status cursor survived the trip');
    });

    test('every row chooses what it says', () {
      final menu = GameboyMenu()..toggle('Active');
      final choices = <Map<String, Object?>>[];
      for (var r = 0; r < GameboyMenu.rowCount; r++) {
        menu.row = r;
        choices.add(menu.choice.toJson());
      }
      expect(choices.map((c) => c['kind']), ['status', 'camera', 'emote', 'tab', 'tab', 'tab', 'tab']);
      expect(choices.skip(3).map((c) => c['tab']), ['dial', 'activity', 'plans', 'settings']);
    });
  });

  group('gameboyButtons', () {
    GbButtonMap keys({bool menuOpen = false, bool inCall = false, bool micOn = false, bool waveReady = false, bool canWalk = true}) =>
        gameboyButtons(menuOpen: menuOpen, inCall: inCall, micOn: micOn, waveReady: waveReady, canWalk: canWalk);

    test('the open menu owns every key, whatever else is true', () {
      final k = keys(menuOpen: true, inCall: true, micOn: true, waveReady: true, canWalk: false);
      expect(k.a, GbAAction.confirm);
      expect(k.b, GbBAction.inert);
      expect(k.start, GbStartAction.closeMenu);
      expect(k.dpad, GbDpadAction.cursor);
      expect(k.dpadEnabled, isTrue, reason: 'the cursor moves even where you cannot walk');
    });

    test('A opens the call during one, latches the cart otherwise', () {
      expect(keys(inCall: true).a, GbAAction.openCall);
      expect(keys().a, GbAAction.boost);
    });

    test('B is a plain mic toggle alone, a mute-or-wave live, an unmute-or-wave muted', () {
      expect(keys(micOn: true).b, GbBAction.toggleMic);
      expect(keys(waveReady: true, micOn: true).b, GbBAction.muteOrWave);
      expect(keys(waveReady: true).b, GbBAction.unmuteOrWave);
    });

    test('Start goes home and the D-pad walks, dimmed when there is nowhere to walk', () {
      final k = keys(canWalk: false);
      expect(k.start, GbStartAction.goHome);
      expect(k.dpad, GbDpadAction.walk);
      expect(k.dpadEnabled, isFalse);
      expect(k.toJson()['select'], 'toggleMenu');
    });
  });

  group('decideBTap', () {
    GbBStep b({bool waveReady = true, bool muteArmed = false, bool micOn = false, bool unmutePending = false}) =>
        decideBTap(waveReady: waveReady, muteArmed: muteArmed, micOn: micOn, unmutePending: unmutePending);

    test('the table, row by row', () {
      expect(b(waveReady: false, micOn: true, muteArmed: true, unmutePending: true), GbBStep.toggleMic);
      expect(b(muteArmed: true), GbBStep.restoreMicAndWave);
      expect(b(micOn: true), GbBStep.muteAndArm);
      expect(b(unmutePending: true), GbBStep.cancelUnmuteAndWave);
      expect(b(), GbBStep.deferUnmute);
    });

    test('the armed mute is read before the mic: a second tap after the async mute still waves', () {
      // First tap muted; by the second the call state already reads mic off.
      expect(b(muteArmed: true, micOn: false), GbBStep.restoreMicAndWave);
    });

    test('with a wave possible, no first tap ever opens the mic at once', () {
      for (final micOn in [true, false]) {
        final step = b(micOn: micOn);
        expect(step, isNot(GbBStep.toggleMic));
        if (!micOn) expect(step, GbBStep.deferUnmute, reason: 'an unmute waits out the window');
      }
    });
  });
}
