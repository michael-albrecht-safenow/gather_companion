import 'package:shared_preferences/shared_preferences.dart';

/// The handful of look-and-feel switches that are the app's own, kept in
/// [SharedPreferences] rather than the keychain.
///
/// The pairing records live in the keychain because they have to *survive* a
/// reinstall (see [BridgeSettingsStore]); a preference about how the office is
/// drawn is the opposite — it is cheap to lose, carries nothing dangerous, and
/// is read on the hot path at boot, so plain preferences are exactly right.
///
/// Every call is wrapped: a simulator with no preferences plugin, or a platform
/// that fails the channel, should fall back to the default look rather than take
/// the app down on launch.
class UiPreferences {
  // ignore: prefer_initializing_formals
  UiPreferences({SharedPreferences? prefs}) : _prefs = prefs;

  /// Cached after the first touch so repeated reads do not re-enter the plugin.
  SharedPreferences? _prefs;

  static const _gameboyKey = 'ui.gameboyMode';
  static const _gameboyThemeKey = 'ui.gameboyTheme';
  static const _soundEffectsKey = 'ui.soundEffects';

  Future<SharedPreferences?> _store() async {
    if (_prefs != null) return _prefs;
    try {
      return _prefs = await SharedPreferences.getInstance();
    } on Object {
      return null;
    }
  }

  /// Whether the office tab wears the retro handheld shell. Off by default: the
  /// normal interface is what somebody who has never heard of the mode should
  /// see first.
  Future<bool> loadGameboyMode() async {
    try {
      return (await _store())?.getBool(_gameboyKey) ?? false;
    } on Object {
      return false;
    }
  }

  Future<void> saveGameboyMode(bool on) async {
    try {
      await (await _store())?.setBool(_gameboyKey, on);
    } on Object {
      /* nothing useful to do; the next toggle writes it again */
    }
  }

  /// Which hardware skin the handheld wears, as a [GameboyThemeId.id] string.
  /// Defaults to `'purple'` — the look someone who has never picked gets. A pure
  /// look preference like [loadGameboyMode], so it lives here, not the keychain.
  Future<String> loadGameboyThemeId() async {
    try {
      return (await _store())?.getString(_gameboyThemeKey) ?? 'purple';
    } on Object {
      return 'purple';
    }
  }

  Future<void> saveGameboyThemeId(String id) async {
    try {
      await (await _store())?.setString(_gameboyThemeKey, id);
    } on Object {
      /* nothing useful to do; the next pick writes it again */
    }
  }

  /// Whether the app's sound effects play. On by default — the blips and chimes
  /// are the expected behaviour, and this switch is how somebody turns them off,
  /// not how they opt in. Never touches in-call voice; it gates UI sound only.
  Future<bool> loadSoundEffects() async {
    try {
      return (await _store())?.getBool(_soundEffectsKey) ?? true;
    } on Object {
      return true;
    }
  }

  Future<void> saveSoundEffects(bool on) async {
    try {
      await (await _store())?.setBool(_soundEffectsKey, on);
    } on Object {
      /* nothing useful to do; the next toggle writes it again */
    }
  }
}
