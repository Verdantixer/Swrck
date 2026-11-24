import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swock/services/advanced_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('IPv6 setting defaults to enabled and persists changes', () async {
    SharedPreferences.setMockInitialValues({});
    final service = AdvancedSettingsService();

    expect((await service.load()).ipv6Enabled, isTrue);

    await service.save(const AdvancedSettings(ipv6Enabled: false));

    expect((await service.load()).ipv6Enabled, isFalse);
  });
}
