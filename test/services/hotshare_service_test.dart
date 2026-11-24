import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swock/services/hotshare_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generates and persists a per-install hotspot password', () async {
    SharedPreferences.setMockInitialValues({});
    final service = HotshareService();

    final first = await service.loadSettings();
    final second = await service.loadSettings();

    expect(first.password.length, 16);
    expect(second.password, first.password);
    expect(first.port, HotshareService.autoPort);
  });

  test('persists user-selected hotspot values', () async {
    SharedPreferences.setMockInitialValues({});
    final service = HotshareService();
    const settings = HotshareSettings(
      name: 'TravelNet',
      password: 'local-password-42',
      port: 3128,
    );

    await service.saveSettings(settings);
    final restored = await service.loadSettings();

    expect(restored.name, settings.name);
    expect(restored.password, settings.password);
    expect(restored.port, settings.port);
  });

  test('rejects invalid hotspot passwords and ports', () async {
    SharedPreferences.setMockInitialValues({});
    final service = HotshareService();

    await expectLater(
      service.saveSettings(
        const HotshareSettings(name: 'TravelNet', password: 'short', port: 0),
      ),
      throwsArgumentError,
    );
    await expectLater(
      service.saveSettings(
        const HotshareSettings(
          name: 'TravelNet',
          password: 'local-password-42',
          port: 80,
        ),
      ),
      throwsArgumentError,
    );
  });
}
