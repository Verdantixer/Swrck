import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_config.dart';
import '../models/vpn_profile.dart';

const _removedBuiltInProfileIds = {
  'builtin-flow-unlimited',
  'builtin-digicel-unlimited',
};

class ProfileService {
  ProfileService({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _secureStorage;

  Future<List<VpnProfile>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(AppConfig.storageKey);
    if (raw == null || raw.isEmpty) {
      return <VpnProfile>[];
    }

    final Map<String, dynamic> decoded =
        jsonDecode(raw) as Map<String, dynamic>;
    final entries = decoded['profiles'] as List<dynamic>? ?? const <dynamic>[];
    final profiles = entries
        .map((entry) =>
            VpnProfile.fromJson(Map<String, dynamic>.from(entry as Map)))
        .toList();
    final removedProfiles = profiles
        .where((profile) => _removedBuiltInProfileIds.contains(profile.id))
        .toList();
    if (removedProfiles.isEmpty) return profiles;

    final remainingProfiles = profiles
        .where((profile) => !_removedBuiltInProfileIds.contains(profile.id))
        .toList();
    await prefs.setString(
      AppConfig.storageKey,
      jsonEncode({
        ...decoded,
        'profiles':
            remainingProfiles.map((profile) => profile.toJson()).toList(),
      }),
    );
    for (final profile in removedProfiles) {
      await _secureStorage.delete(
        key: '${AppConfig.secureStorageKey}_${profile.id}',
      );
    }
    return remainingProfiles;
  }

  Future<void> saveProfiles(List<VpnProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = {
      'version': 1,
      'profiles': profiles.map((profile) => profile.toJson()).toList(),
    };
    await prefs.setString(AppConfig.storageKey, jsonEncode(payload));

    for (final profile in profiles) {
      if (profile.password.isNotEmpty) {
        await _secureStorage.write(
          key: '${AppConfig.secureStorageKey}_${profile.id}',
          value: profile.password,
        );
      }
    }
  }

  Future<void> addProfile(VpnProfile profile) async {
    final current = await loadProfiles();
    await saveProfiles([...current, profile]);
  }

  Future<void> updateProfile(VpnProfile profile) async {
    final current = await loadProfiles();
    final index = current.indexWhere((entry) => entry.id == profile.id);
    if (index >= 0) {
      current[index] = profile;
      await saveProfiles(current);
    }
  }

  Future<void> deleteProfile(String id) async {
    final current = await loadProfiles();
    final next = current.where((profile) => profile.id != id).toList();
    await saveProfiles(next);
    await _secureStorage.delete(key: '${AppConfig.secureStorageKey}_$id');
  }

  Future<VpnProfile?> getActiveProfile() async {
    final profiles = await loadProfiles();
    return profiles.where((profile) => profile.isSelected).firstOrNull;
  }
}
