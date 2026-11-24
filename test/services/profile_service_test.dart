import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swock/core/app_config.dart';
import 'package:swock/services/profile_service.dart';

class _MemorySecureStorage extends FlutterSecureStorage {
  final deletedKeys = <String>{};

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deletedKeys.add(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('removes the retired built-in profiles and preserves user profiles',
      () async {
    final now = DateTime.utc(2026);
    Map<String, dynamic> profileJson(String id) => {
          'id': id,
          'name': id,
          'server': 'example.com',
          'port': 443,
          'createdAt': now.toIso8601String(),
          'lastUsedAt': now.toIso8601String(),
        };
    SharedPreferences.setMockInitialValues({
      AppConfig.storageKey: jsonEncode({
        'version': 1,
        'profiles': [
          profileJson('builtin-flow-unlimited'),
          profileJson('builtin-digicel-unlimited'),
          profileJson('user-profile'),
        ],
      }),
    });
    final secureStorage = _MemorySecureStorage();
    final service = ProfileService(secureStorage: secureStorage);

    final profiles = await service.loadProfiles();

    expect(profiles.map((profile) => profile.id), ['user-profile']);
    expect(
      secureStorage.deletedKeys,
      {
        '${AppConfig.secureStorageKey}_builtin-flow-unlimited',
        '${AppConfig.secureStorageKey}_builtin-digicel-unlimited',
      },
    );
    final preferences = await SharedPreferences.getInstance();
    final stored = jsonDecode(
      preferences.getString(AppConfig.storageKey)!,
    ) as Map<String, dynamic>;
    expect((stored['profiles'] as List), hasLength(1));

    await service.saveProfiles(profiles);
    expect((await service.loadProfiles()).map((profile) => profile.id),
        ['user-profile']);
  });
}
