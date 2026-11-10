/// Which backends this phone knows, and which one it is pointed at now.
///
/// The app was born speaking only to Gather, so there was nothing to choose: one
/// `GatherCredentialStore` held one session. A *general* client talks to any
/// Gather-protocol backend — Gather's cloud, a self-hosted `bether` server, or
/// several at once — so it needs a list of [BackendProfile]s, an "active" one, and
/// a *separate credential per profile*. Signing in to the office does not sign you
/// in to Gather; switching back must not ask you to log in again.
///
/// This lives in the keychain for the same reason `GatherCredentialStore` does: a
/// profile's credential is a full account session, and iOS leaves keychain items
/// alone across a reinstall (unlike a preferences plist), so a reinstalled app
/// keeps its backends instead of silently forgetting them. See that class's header.
///
/// The built-in [gatherProfile] is *not* stored: decision §3 (2026-11-03) is that a
/// fresh install forces no backend, and Gather is one pickable option among others,
/// not a baked-in default. It is offered by the picker and resolved by [active]
/// when selected, but it never occupies a row until — and this never happens — a
/// user "adds" it like any other.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gather_client/gather_client.dart';

/// One backend the user has added, plus the stable id its credential is keyed by.
class BackendProfile {
  const BackendProfile({required this.id, required this.config});

  /// Stable across launches and edits — the key for this profile's credential and
  /// its row in the list. Derived once from the backend's host by [fromConfig], or
  /// fixed (`'gather'`) for the built-in profile, so re-adding the same backend
  /// updates its row rather than spawning a duplicate with a new session.
  final String id;

  final BackendConfig config;

  String get name => config.name;

  /// Derives a profile (and its stable id) from a resolved [config]. The id is the
  /// backend's authority (host[:port]) so two servers on one host but different
  /// ports stay distinct, with the config name as a last resort when there is no
  /// usable URL to key on.
  factory BackendProfile.fromConfig(BackendConfig config) {
    final source = config.tokenEndpoint.isNotEmpty ? config.tokenEndpoint : config.apiBase;
    final authority = Uri.tryParse(source)?.authority ?? '';
    final id = authority.isNotEmpty ? authority.toLowerCase() : config.name.toLowerCase();
    return BackendProfile(id: id, config: config);
  }

  Map<String, Object?> toJson() => {'id': id, 'config': config.toJson()};

  factory BackendProfile.fromJson(Map<String, Object?> json) => BackendProfile(
        id: json['id'] as String? ?? '',
        config: BackendConfig.fromJson(
          (json['config'] as Map?)?.cast<String, Object?>() ?? const {},
        ),
      );
}

/// The id the built-in Gather profile resolves under when a user picks it.
const gatherProfileId = 'gather';

/// Gather's cloud as a pickable profile — the original hosts, unchanged. Offered by
/// the picker, never auto-selected and never stored (see the library header).
const gatherProfile = BackendProfile(id: gatherProfileId, config: BackendConfig.gather);

class BackendProfileStore {
  BackendProfileStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                // Mirrors GatherCredentialStore: the collector reconnects in the
                // background after a resume, possibly while locked, so `first_unlock`
                // rather than `unlocked`; `ThisDeviceOnly` keeps it out of backups.
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
              aOptions: AndroidOptions(),
            );

  final FlutterSecureStorage _storage;

  static const _profilesKey = 'backend.profiles';
  static const _activeKey = 'backend.activeId';
  static String _credKey(String id) => 'backend.creds.$id';

  /// The backends the user has added, in insertion order. The built-in Gather
  /// profile is deliberately not among them.
  Future<List<BackendProfile>> profiles() async {
    final raw = await _read(_profilesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final row in list)
          if (row is Map) BackendProfile.fromJson(row.cast<String, Object?>()),
      ];
    } on Object {
      // An unreadable list reads as no backends, which sends the user to the picker
      // — the one screen that can rebuild it — rather than crashing on launch.
      return const [];
    }
  }

  /// Adds a backend, or updates the one that shares its id (re-adding the same host
  /// refreshes its config without stranding the old row or its session).
  Future<void> addProfile(BackendProfile profile) async {
    final list = (await profiles()).where((p) => p.id != profile.id).toList()..add(profile);
    await _writeProfiles(list);
  }

  /// Forgets a backend and its credential. Clears the active selection too when the
  /// removed profile was the active one, so the app never points at a backend that
  /// is no longer in the list.
  Future<void> removeProfile(String id) async {
    final list = (await profiles()).where((p) => p.id != id).toList();
    await _writeProfiles(list);
    await clearCredentials(id);
    if (await activeId() == id) await setActive(null);
  }

  Future<String?> activeId() => _read(_activeKey);

  Future<void> setActive(String? id) async {
    if (id == null || id.isEmpty) {
      await _delete(_activeKey);
    } else {
      await _write(_activeKey, id);
    }
  }

  /// The active profile resolved to a [BackendProfile], or null when none is
  /// selected (a fresh install, decision §3) or the selection has gone missing. The
  /// built-in Gather profile resolves here without being stored.
  Future<BackendProfile?> active() async {
    final id = await activeId();
    if (id == null || id.isEmpty) return null;
    if (id == gatherProfileId) return gatherProfile;
    for (final p in await profiles()) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// This profile's stored session, or [GatherCredentials.empty] when it has none
  /// yet (never logged in) or the record cannot be read.
  Future<GatherCredentials> loadCredentials(String id) async {
    final raw = await _read(_credKey(id));
    if (raw == null || raw.isEmpty) return GatherCredentials.empty;
    try {
      return GatherCredentials.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    } on Object {
      return GatherCredentials.empty;
    }
  }

  Future<void> saveCredentials(String id, GatherCredentials credentials) =>
      _write(_credKey(id), jsonEncode(credentials.toJson()));

  Future<void> clearCredentials(String id) => _delete(_credKey(id));

  Future<void> _writeProfiles(List<BackendProfile> list) =>
      _write(_profilesKey, jsonEncode([for (final p in list) p.toJson()]));

  // Keychain access can fail — a locked device before first unlock, a misconfigured
  // entitlement, a simulator with no keychain. None of that should crash launch; it
  // reads as "no backends yet", a state the picker already handles.
  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } on Object {
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on Object {
      /* nothing useful to do; the picker rebuilds what did not persist */
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } on Object {
      /* already gone, or unreadable — either way it is not coming back */
    }
  }
}
