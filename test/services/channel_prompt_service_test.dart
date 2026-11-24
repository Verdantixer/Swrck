import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swock/services/channel_prompt_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('channel prompt does not appear before seven days after dismissal',
      () async {
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({
      'swock_official_channel_dismissed_at_v1':
          now.subtract(const Duration(days: 6)).millisecondsSinceEpoch,
    });

    expect(await ChannelPromptService().shouldShow(), isFalse);
  });

  test('channel prompt appears after seven days after dismissal', () async {
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({
      'swock_official_channel_dismissed_at_v1':
          now.subtract(const Duration(days: 7)).millisecondsSinceEpoch,
    });

    expect(await ChannelPromptService().shouldShow(), isTrue);
  });

  test('channel prompt never appears after joined', () async {
    SharedPreferences.setMockInitialValues({
      'swock_official_channel_joined_v1': true,
    });

    expect(await ChannelPromptService().shouldShow(), isFalse);
  });
}
